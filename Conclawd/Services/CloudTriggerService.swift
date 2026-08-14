import Foundation

/// Service for managing cloud-based scheduled triggers via `claude -p` with the RemoteTrigger tool.
/// Uses the Claude CLI for authentication instead of direct Keychain access.
@Observable
@MainActor
final class CloudTriggerService {

    // MARK: - Properties

    private(set) var triggers: [CloudTrigger] = []
    private(set) var isLoading = false
    private(set) var error: String?
    /// Whether triggers have been fetched at least once.
    private(set) var hasFetched = false

    private let claudePathResolver: ClaudePathResolver

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    init(claudePathResolver: ClaudePathResolver) {
        self.claudePathResolver = claudePathResolver
    }

    // MARK: - Public API

    /// Fetch all triggers from the API.
    func fetchTriggers() async {
        isLoading = true
        error = nil
        defer {
            isLoading = false
            hasFetched = true
        }

        do {
            let result = try await executeRemoteTriggerAction(
                "Call RemoteTrigger with action \"list\". Output ONLY the raw JSON result from the tool, no markdown, no extra text."
            )
            if let jsonString = Self.extractJSON(from: result),
               let data = jsonString.data(using: .utf8),
               let listResponse = try? decoder.decode(CloudTriggerListResponse.self, from: data) {
                triggers = listResponse.data ?? []
            } else {
                triggers = []
                self.error = "Failed to parse trigger list"
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Create a new trigger.
    func createTrigger(_ request: CloudTriggerCreateRequest) async throws -> CloudTrigger {
        let prompt = Self.buildCreatePrompt(request)
        let result = try await executeRemoteTriggerAction(prompt)
        guard let jsonString = Self.extractJSON(from: result),
              let data = jsonString.data(using: .utf8),
              let trigger = try? decoder.decode(CloudTrigger.self, from: data) else {
            throw CloudTriggerError.networkError("Failed to parse created trigger response")
        }
        triggers.append(trigger)
        return trigger
    }

    /// Update an existing trigger.
    func updateTrigger(_ trigger: CloudTrigger) async throws {
        let prompt = Self.buildUpdatePrompt(trigger)
        let result = try await executeRemoteTriggerAction(prompt)
        if let jsonString = Self.extractJSON(from: result),
           let data = jsonString.data(using: .utf8),
           let updated = try? decoder.decode(CloudTrigger.self, from: data),
           let index = triggers.firstIndex(where: { $0.id == trigger.id }) {
            triggers[index] = updated
        }
    }

    /// Run a trigger immediately.
    func runTrigger(id: String) async throws {
        _ = try await executeRemoteTriggerAction(
            "Call RemoteTrigger with action \"run\" and trigger_id \"\(id)\"."
        )
    }

    /// Toggle enabled state of a trigger.
    func toggleEnabled(_ trigger: CloudTrigger) async throws {
        let newState = !trigger.enabled
        _ = try await executeRemoteTriggerAction(
            "Call RemoteTrigger with action \"update\", trigger_id \"\(trigger.id)\", set enabled to \(newState)."
        )
        if let index = triggers.firstIndex(where: { $0.id == trigger.id }) {
            triggers[index].enabled = newState
        }
    }

    // MARK: - CLI Execution

    /// Execute a RemoteTrigger action via `claude -p` and return the LLM result text.
    private func executeRemoteTriggerAction(_ prompt: String) async throws -> String {
        guard let claudePath = claudePathResolver.resolve() else {
            throw CloudTriggerError.authenticationFailed("Claude CLI not found. Install Claude Code first.")
        }

        let data = try await Self.executeClaudePrint(claudePath: claudePath, prompt: prompt)

        guard let output = String(data: data, encoding: .utf8),
              let outputData = output.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: outputData) as? [String: Any],
              let result = json["result"] as? String else {
            throw CloudTriggerError.networkError("Failed to parse claude -p output")
        }

        return result
    }

    /// Run `claude -p` with RemoteTrigger tool and return raw stdout data.
    nonisolated private static func executeClaudePrint(claudePath: String, prompt: String) async throws -> Data {
        let process = Process()
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let escapedClaude = claudePath.replacingOccurrences(of: " ", with: "\\ ")

        let tempFile = FileManager.default.temporaryDirectory
            .appending(path: "cloud_trigger_\(UUID().uuidString.prefix(8)).txt")
        try prompt.write(to: tempFile, atomically: true, encoding: .utf8)

        let command = "cat '\(tempFile.path(percentEncoded: false))' | \(escapedClaude) -p --tools \"RemoteTrigger\" --output-format json --setting-sources \"\" --model \(AgentModel.haiku.cliModelId(for: .claude))"

        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-l", "-c", command]
        process.environment = CLIPathResolver.augmentedEnvironment(cliPath: claudePath)

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        // Drain stderr to prevent pipe buffer deadlock
        DispatchQueue.global(qos: .utility).async {
            while true {
                let chunk = stderr.fileHandleForReading.availableData
                if chunk.isEmpty { break }
            }
        }

        try process.run()

        let tempFileForCleanup = tempFile
        return try await withCheckedThrowingContinuation { continuation in
            // Timeout after 60 seconds
            let timer = DispatchSource.makeTimerSource(queue: .global())
            timer.schedule(deadline: .now() + 60)
            timer.setEventHandler {
                process.terminate()
            }
            timer.resume()

            process.terminationHandler = { proc in
                timer.cancel()
                defer { try? FileManager.default.removeItem(at: tempFileForCleanup) }
                let data = stdout.fileHandleForReading.readDataToEndOfFile()
                if proc.terminationStatus == 0 {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: CloudTriggerError.networkError(
                        "claude -p exited with code \(proc.terminationStatus)"
                    ))
                }
            }
        }
    }

    // MARK: - Helpers

    /// Extract JSON object string from LLM output that may contain extra text.
    nonisolated private static func extractJSON(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Try the entire text first
        if let data = trimmed.data(using: .utf8),
           (try? JSONSerialization.jsonObject(with: data)) != nil {
            return trimmed
        }
        // Try to find outermost JSON object
        guard let start = trimmed.firstIndex(of: "{"),
              let end = trimmed.range(of: "}", options: .backwards)?.lowerBound else {
            return nil
        }
        let candidate = String(trimmed[start...end])
        if let data = candidate.data(using: .utf8),
           (try? JSONSerialization.jsonObject(with: data)) != nil {
            return candidate
        }
        return nil
    }

    nonisolated private static func buildCreatePrompt(_ request: CloudTriggerCreateRequest) -> String {
        let prompt = request.jobConfig.ccr.events?.first?.data?.message?.content ?? ""
        let model = request.jobConfig.ccr.sessionContext?.model ?? "sonnet"
        let envId = request.jobConfig.ccr.environmentId ?? "default"
        let escapedPrompt = prompt.replacingOccurrences(of: "\"", with: "\\\"")
        return """
        Call RemoteTrigger with action "create" and these parameters:
        - name: "\(request.name)"
        - cron_expression: "\(request.cronExpression)"
        - enabled: \(request.enabled)
        - environment_id: "\(envId)"
        - model: "\(model)"
        - prompt: "\(escapedPrompt)"
        Output ONLY the raw JSON result from the tool.
        """
    }

    nonisolated private static func buildUpdatePrompt(_ trigger: CloudTrigger) -> String {
        let prompt = trigger.prompt ?? ""
        let model = trigger.model ?? "sonnet"
        let escapedPrompt = prompt.replacingOccurrences(of: "\"", with: "\\\"")
        return """
        Call RemoteTrigger with action "update" and trigger_id "\(trigger.id)". Update:
        - name: "\(trigger.name)"
        - cron_expression: "\(trigger.cronExpression)"
        - enabled: \(trigger.enabled)
        - model: "\(model)"
        - prompt: "\(escapedPrompt)"
        Output ONLY the raw JSON result from the tool.
        """
    }
}

// MARK: - Errors

enum CloudTriggerError: LocalizedError {
    case authenticationFailed(String)
    case networkError(String)
    case apiError(statusCode: Int, body: String)

    var errorDescription: String? {
        switch self {
        case .authenticationFailed(let msg): return msg
        case .networkError(let msg): return msg
        case .apiError(let code, let body):
            return "API error (\(code)): \(body.prefix(200))"
        }
    }
}
