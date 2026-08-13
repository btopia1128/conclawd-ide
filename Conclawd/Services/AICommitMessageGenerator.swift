import Foundation

/// Generates commit messages from git diffs using `claude -p` or `codex exec`.
enum AICommitMessageGenerator {

    enum GeneratorError: LocalizedError {
        case claudeNotFound
        case cliNotFound(CLIProviderType)
        case generationFailed(String)

        var errorDescription: String? {
            switch self {
            case .claudeNotFound: return "Claude CLI not found"
            case .cliNotFound(let p): return "\(p.displayName) CLI not found"
            case .generationFailed(let msg): return "Commit message generation failed: \(msg)"
            }
        }
    }

    /// Generate a commit message from a git diff summary.
    static func generate(
        cliPath: String,
        provider: CLIProviderType,
        diffSummary: String
    ) async throws -> String {
        let prompt = buildPrompt(diffSummary: diffSummary)
        switch provider {
        case .claude:
            let data = try await executeClaudePrint(claudePath: cliPath, prompt: prompt)
            return parseClaudeResult(data)
        case .codex:
            return try await executeCodexExec(codexPath: cliPath, prompt: prompt)
        }
    }

    private static func buildPrompt(diffSummary: String) -> String {
        """
        You are a commit message generator. Given the following git diff, write a concise, \
        conventional commit message (subject line only, max 72 chars). \
        Do NOT include any explanation, markdown formatting, or quotes. \
        Output ONLY the commit message text.

        Example outputs:
        - fix: resolve null pointer in user auth flow
        - feat: add dark mode toggle to settings
        - refactor: extract validation logic into shared util

        Git diff:
        \(diffSummary)
        """
    }

    // MARK: - Claude

    private static func executeClaudePrint(claudePath: String, prompt: String) async throws -> Data {
        let process = Process()
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let escapedClaude = claudePath.replacingOccurrences(of: " ", with: "\\ ")

        let tempFile = FileManager.default.temporaryDirectory
            .appending(path: "commit_msg_\(UUID().uuidString.prefix(8)).txt")
        try prompt.write(to: tempFile, atomically: true, encoding: .utf8)

        let command = "cat '\(tempFile.path(percentEncoded: false))' | \(escapedClaude) -p --model \(AgentModel.haikuModelId) --output-format json --setting-sources \"\""

        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-l", "-c", command]

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        // Drain stderr in background to prevent pipe buffer deadlock.
        DispatchQueue.global(qos: .utility).async {
            while true {
                let chunk = stderr.fileHandleForReading.availableData
                if chunk.isEmpty { break }
            }
        }

        try process.run()

        let tempFileForCleanup = tempFile
        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { proc in
                defer { try? FileManager.default.removeItem(at: tempFileForCleanup) }
                let data = stdout.fileHandleForReading.readDataToEndOfFile()
                if proc.terminationStatus == 0 {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: GeneratorError.generationFailed(
                        "claude -p exited with code \(proc.terminationStatus)"
                    ))
                }
            }
        }
    }

    /// Parse the JSON result from `claude -p --output-format json`.
    private static func parseClaudeResult(_ data: Data) -> String {
        guard let jsonString = String(data: data, encoding: .utf8) else { return "" }

        // claude -p --output-format json returns: {"type":"result","result":"...","...}
        if let jsonData = jsonString.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
           let result = json["result"] as? String {
            return result.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return jsonString.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Codex

    private static func executeCodexExec(codexPath: String, prompt: String) async throws -> String {
        let process = Process()
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let escapedCodex = codexPath.replacingOccurrences(of: " ", with: "\\ ")

        let promptFile = FileManager.default.temporaryDirectory
            .appending(path: "commit_msg_in_\(UUID().uuidString.prefix(8)).txt")
        let outputFile = FileManager.default.temporaryDirectory
            .appending(path: "commit_msg_out_\(UUID().uuidString.prefix(8)).txt")
        try prompt.write(to: promptFile, atomically: true, encoding: .utf8)

        // `codex exec` reads prompt from stdin and writes the final agent message to -o file.
        // --ephemeral: don't persist a session file; --sandbox read-only: prevent any writes;
        // --skip-git-repo-check: allow running anywhere.
        let command = "cat '\(promptFile.path(percentEncoded: false))' | \(escapedCodex) exec --ephemeral --sandbox read-only --skip-git-repo-check --color never -m \(AgentModel.haiku.cliModelId(for: .codex)) -o '\(outputFile.path(percentEncoded: false))' >/dev/null 2>&1"

        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-l", "-c", command]

        try process.run()

        let promptFileForCleanup = promptFile
        let outputFileForCleanup = outputFile
        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { proc in
                defer {
                    try? FileManager.default.removeItem(at: promptFileForCleanup)
                    try? FileManager.default.removeItem(at: outputFileForCleanup)
                }
                if proc.terminationStatus == 0 {
                    let text = (try? String(contentsOf: outputFileForCleanup, encoding: .utf8)) ?? ""
                    continuation.resume(returning: text.trimmingCharacters(in: .whitespacesAndNewlines))
                } else {
                    continuation.resume(throwing: GeneratorError.generationFailed(
                        "codex exec exited with code \(proc.terminationStatus)"
                    ))
                }
            }
        }
    }
}
