import Foundation

/// Thread-safe accumulator for stderr data drained on a background queue.
private final class StderrAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    var text: String {
        lock.lock()
        let result = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        lock.unlock()
        return result
    }
}

/// Reads lines from a file handle on a background queue and yields them as an AsyncStream.
private func lineStream(from fileHandle: FileHandle) -> AsyncStream<String> {
    AsyncStream { continuation in
        let queue = DispatchQueue(label: "chat-stream-reader", qos: .userInitiated)
        queue.async {
            let newline = UInt8(ascii: "\n")
            var buffer = Data()
            while true {
                let chunk = fileHandle.availableData
                if chunk.isEmpty {
                    continuation.finish()
                    return
                }
                buffer.append(chunk)
                while let idx = buffer.firstIndex(of: newline) {
                    let lineData = buffer[buffer.startIndex..<idx]
                    buffer = Data(buffer[buffer.index(after: idx)...])
                    if let line = String(data: lineData, encoding: .utf8), !line.isEmpty {
                        continuation.yield(line)
                    }
                }
            }
        }
    }
}

/// Manages a single chat-mode session with Claude Code CLI.
///
/// Each user message spawns a new `claude -p` process with `--output-format stream-json`.
/// Multi-turn conversations use `--resume {session_id}`.
@Observable
@MainActor
final class ChatSessionManager {

    // MARK: - Published State

    var messages: [ChatMessage] = []
    var isProcessing = false
    var error: String?

    /// Claude CLI session ID used for `--resume` on subsequent turns.
    private(set) var claudeSessionId: String?

    // MARK: - Configuration (set once at init)

    private let claudePath: String
    private let agentName: String?
    private let model: AgentModel
    private let permissionMode: PermissionMode
    private let workingDirectory: String?
    private let memoryContext: String?

    private var currentProcess: Process?

    // MARK: - Init

    init(
        claudePath: String,
        agentName: String?,
        model: AgentModel,
        permissionMode: PermissionMode,
        workingDirectory: String?,
        memoryContext: String?
    ) {
        self.claudePath = claudePath
        self.agentName = agentName
        self.model = model
        self.permissionMode = permissionMode
        self.workingDirectory = workingDirectory
        self.memoryContext = memoryContext
    }

    // MARK: - Public API

    func sendMessage(_ text: String, attachments: [ChatAttachment] = []) {
        guard !isProcessing else { return }

        messages.append(ChatMessage(role: .user, content: text, attachments: attachments))
        isProcessing = true
        error = nil

        // Build prompt with attachment context
        let prompt = Self.buildPrompt(text: text, attachments: attachments)

        // Streaming placeholder
        messages.append(ChatMessage(role: .assistant, isStreaming: true))
        let assistantIndex = messages.count - 1

        let config = ProcessConfig(
            claudePath: claudePath,
            agentName: agentName,
            model: model,
            permissionMode: permissionMode,
            workingDirectory: workingDirectory,
            memoryContext: memoryContext,
            resumeId: claudeSessionId,
            prompt: prompt
        )

        Task {
            await runProcess(config: config, assistantIndex: assistantIndex)
        }
    }

    /// Build a prompt that includes attachment file paths so Claude can read them.
    private static func buildPrompt(text: String, attachments: [ChatAttachment]) -> String {
        guard !attachments.isEmpty else { return text }

        var parts: [String] = []
        parts.append("<attachments>")
        for attachment in attachments {
            let label = attachment.isImage ? "image" : "file"
            parts.append("- [\(label)] \(attachment.url.path)")
        }
        parts.append("</attachments>")

        if !text.isEmpty {
            parts.append("")
            parts.append(text)
        }

        return parts.joined(separator: "\n")
    }

    func cancel() {
        currentProcess?.terminate()
        currentProcess = nil
        isProcessing = false
        // Mark last streaming message as done
        if let last = messages.indices.last, messages[last].isStreaming {
            messages[last].isStreaming = false
        }
    }

    // MARK: - Process Execution

    private struct ProcessConfig: Sendable {
        let claudePath: String
        let agentName: String?
        let model: AgentModel
        let permissionMode: PermissionMode
        let workingDirectory: String?
        let memoryContext: String?
        let resumeId: String?
        let prompt: String
    }

    private func runProcess(config: ProcessConfig, assistantIndex: Int) async {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"

        // Build claude arguments
        var cliArgs: [String] = []
        cliArgs.append("-p")
        cliArgs.append("\"$_AGENT_TERMINAL_CHAT_PROMPT\"")
        cliArgs.append("--verbose")
        cliArgs.append("--output-format")
        cliArgs.append("stream-json")

        if let resumeId = config.resumeId {
            cliArgs.append("--resume")
            cliArgs.append(resumeId)
        } else {
            if let name = config.agentName {
                cliArgs.append("--agent")
                cliArgs.append("\"\(name)\"")
            }
            if config.model != .inherit {
                cliArgs.append("--model")
                cliArgs.append(config.model.rawValue)
            } else {
                let defaultModel = UserDefaults.standard.string(forKey: "defaultModel") ?? ""
                if !defaultModel.isEmpty, defaultModel != AgentModel.inherit.rawValue {
                    cliArgs.append("--model")
                    cliArgs.append(defaultModel)
                }
            }
            switch config.permissionMode {
            case .bypassPermissions:
                cliArgs.append("--dangerously-skip-permissions")
            case .default:
                break
            default:
                cliArgs.append("--permission-mode")
                cliArgs.append(config.permissionMode.rawValue)
            }
            if config.memoryContext != nil {
                cliArgs.append("--append-system-prompt")
                cliArgs.append("\"$_AGENT_TERMINAL_APPEND_PROMPT\"")
            }
        }

        let escapedClaude = config.claudePath.replacingOccurrences(of: " ", with: "\\ ")
        let command = "\(escapedClaude) \(cliArgs.joined(separator: " "))"

        // Environment
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["FORCE_COLOR"] = "0"
        env["NO_COLOR"] = "1"
        env["_AGENT_TERMINAL_CHAT_PROMPT"] = config.prompt
        if let memCtx = config.memoryContext {
            env["_AGENT_TERMINAL_APPEND_PROMPT"] = memCtx
        }

        // Setup process
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-l", "-c", command]
        process.environment = env

        if let workDir = config.workingDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: workDir)
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // Drain stderr on a background queue to prevent pipe buffer deadlock.
        // Without this, --verbose output can fill the 16-64KB pipe buffer,
        // blocking the process and deadlocking stdout reads.
        let stderrAccumulator = StderrAccumulator()
        let stderrHandle = stderrPipe.fileHandleForReading
        DispatchQueue(label: "chat-stderr-drain", qos: .utility).async {
            while true {
                let chunk = stderrHandle.availableData
                if chunk.isEmpty { break }
                stderrAccumulator.append(chunk)
            }
        }

        do {
            try process.run()
        } catch {
            self.error = "Failed to launch claude: \(error.localizedDescription)"
            self.isProcessing = false
            if assistantIndex < messages.count {
                messages[assistantIndex].isStreaming = false
            }
            return
        }

        currentProcess = process

        // Parse streaming output
        var state = ParseState()
        let stream = lineStream(from: stdoutPipe.fileHandleForReading)

        for await line in stream {
            guard let parsed = parseJsonLine(line, state: &state) else { continue }

            // Apply updates to the message
            if assistantIndex < messages.count {
                messages[assistantIndex].content = parsed.text
                messages[assistantIndex].toolUses = parsed.toolUses
            }
        }

        // Wait for process exit off the main thread to avoid blocking UI
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .utility).async {
                process.waitUntilExit()
                cont.resume()
            }
        }

        let stderrText = stderrAccumulator.text
        let exitCode = process.terminationStatus

        // Finalize
        if assistantIndex < messages.count {
            messages[assistantIndex].content = state.currentText
            messages[assistantIndex].toolUses = state.completedToolUses
            messages[assistantIndex].isStreaming = false

            // If process failed with no output, show error
            if state.currentText.isEmpty && state.completedToolUses.isEmpty {
                if exitCode != 0 && !stderrText.isEmpty {
                    messages[assistantIndex].content = "Error (exit code \(exitCode)): \(stderrText)"
                    messages[assistantIndex].role = .system
                } else if exitCode != 0 {
                    messages[assistantIndex].content = "Process exited with code \(exitCode)"
                    messages[assistantIndex].role = .system
                } else {
                    messages.remove(at: assistantIndex)
                }
            }
        }

        if !stderrText.isEmpty && exitCode != 0 {
            self.error = stderrText
        }

        claudeSessionId = state.capturedSessionId
        currentProcess = nil
        isProcessing = false
    }

    // MARK: - JSON Parsing

    private struct ParseState {
        var currentText = ""
        var completedToolUses: [ChatToolUse] = []
        var activeToolId: String?
        var activeToolName = ""
        var activeToolInput = ""
        var capturedSessionId: String?
    }

    private struct ParseResult {
        let text: String
        let toolUses: [ChatToolUse]
    }

    private func parseJsonLine(_ line: String, state: inout ParseState) -> ParseResult? {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        // Capture session_id from any event
        if state.capturedSessionId == nil, let sid = json["session_id"] as? String {
            state.capturedSessionId = sid
        }

        let type = json["type"] as? String

        // Handle final result event
        if type == "result" {
            if let sid = json["session_id"] as? String {
                state.capturedSessionId = sid
            }
            // Capture result text as fallback when streaming deltas were missed
            if let resultText = json["result"] as? String, !resultText.isEmpty,
               state.currentText.isEmpty {
                state.currentText = resultText
            }
            return ParseResult(text: state.currentText, toolUses: state.completedToolUses)
        }

        guard type == "stream_event",
              let event = json["event"] as? [String: Any],
              let eventType = event["type"] as? String else {
            return nil
        }

        switch eventType {
        case "content_block_start":
            if let block = event["content_block"] as? [String: Any],
               let blockType = block["type"] as? String,
               blockType == "tool_use" {
                state.activeToolId = block["id"] as? String
                state.activeToolName = block["name"] as? String ?? "Unknown"
                state.activeToolInput = ""
            }

        case "content_block_delta":
            if let delta = event["delta"] as? [String: Any],
               let deltaType = delta["type"] as? String {
                if deltaType == "text_delta", let text = delta["text"] as? String {
                    state.currentText += text
                } else if deltaType == "input_json_delta", let partial = delta["partial_json"] as? String {
                    state.activeToolInput += partial
                }
            }

        case "content_block_stop":
            if let toolId = state.activeToolId {
                state.completedToolUses.append(ChatToolUse(
                    id: toolId,
                    name: state.activeToolName,
                    input: state.activeToolInput,
                    isComplete: true
                ))
                state.activeToolId = nil
                state.activeToolName = ""
                state.activeToolInput = ""
            }

        default:
            break
        }

        return ParseResult(text: state.currentText, toolUses: state.completedToolUses)
    }
}
