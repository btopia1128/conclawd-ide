import Foundation
import os

private let logger = Logger(subsystem: "com.agent-terminal", category: "MemoryExtractor")

/// Extracts memories from Claude Code session transcripts using LLM analysis.
/// Runs as an actor to serialize concurrent extraction requests.
actor MemoryExtractor {

    private let memoryService: AgentMemoryService
    private let cliPathResolver: CLIPathResolver
    private let databaseManager: MemoryDatabaseManager?

    init(memoryService: AgentMemoryService, claudePathResolver: CLIPathResolver, databaseManager: MemoryDatabaseManager? = nil) {
        self.memoryService = memoryService
        self.cliPathResolver = claudePathResolver
        self.databaseManager = databaseManager
    }

    /// Resolves the best CLI path for extraction, preferring the given provider.
    private func resolveExtractionCLI(preferring provider: CLIProviderType) -> (path: String, provider: CLIProviderType)? {
        // Try the preferred provider first, fall back to the other
        if let path = cliPathResolver.resolve(for: provider) {
            return (path, provider)
        }
        let fallback: CLIProviderType = provider == .claude ? .codex : .claude
        if let path = cliPathResolver.resolve(for: fallback) {
            return (path, fallback)
        }
        return nil
    }

    // MARK: - Public API

    /// Primary entry point: extract memories from the JSONL transcript file.
    /// Only processes lines added since the last extraction for this transcript.
    func extractFromTranscript(
        jsonlPath: URL,
        agentName: String,
        agent: Agent,
        provider: CLIProviderType = .claude
    ) async {
        logger.info("[\(agentName)] Extracting memories from transcript: \(jsonlPath.lastPathComponent)")

        let lastOffset = loadLastOffset(jsonlPath: jsonlPath, agent: agent)
        let (conversation, totalLines) = parseTranscript(at: jsonlPath, fromLine: lastOffset)

        guard !conversation.isEmpty else {
            logger.info("[\(agentName)] No new conversation content (offset \(lastOffset), total \(totalLines) lines)")
            // Still update offset so we don't re-scan empty lines
            if totalLines > lastOffset {
                saveLastOffset(totalLines, jsonlPath: jsonlPath, agent: agent)
            }
            return
        }

        logger.info("[\(agentName)] Parsed transcript: \(conversation.count) chars (lines \(lastOffset)-\(totalLines))")

        // Layer 2: Save transcript to DB for FTS5 search (recall_memory can search past conversations)
        if agent.memoryDbSyncEnabled {
            saveTranscriptToDatabase(
                sessionId: jsonlPath.deletingPathExtension().lastPathComponent,
                agentName: agentName,
                content: conversation,
                agent: agent
            )
        }

        // Layer 1: LLM-based memory extraction
        var extractionSucceeded = true
        if agent.memoryExtractionEnabled {
            extractionSucceeded = await runExtraction(conversation: conversation, agentName: agentName, agent: agent, provider: provider)
        }

        // Only record offset if extraction succeeded (or was disabled).
        // On failure, leave the offset so the content is retried next time.
        if extractionSucceeded {
            saveLastOffset(totalLines, jsonlPath: jsonlPath, agent: agent)
        } else {
            logger.warning("[\(agentName)] Skipping offset update due to extraction failure — will retry")
        }
    }

    /// Fallback: extract memories from terminal text (when JSONL is unavailable).
    func extractFromTerminalText(
        terminalText: String,
        agentName: String,
        agent: Agent,
        provider: CLIProviderType = .claude
    ) async {
        guard agent.memoryExtractionEnabled else {
            logger.info("[\(agentName)] Extraction disabled, skipping terminal text extraction")
            return
        }

        logger.info("[\(agentName)] Fallback: extracting from terminal text (\(terminalText.count) chars)")

        let cleanText = stripANSI(terminalText)
        guard cleanText.count >= 500 else {
            logger.info("[\(agentName)] Skipped: text too short (\(cleanText.count) < 500)")
            return
        }

        await runExtraction(conversation: cleanText, agentName: agentName, agent: agent, provider: provider)
    }

    // MARK: - JSONL Transcript Parsing

    /// Parse a Claude Code JSONL transcript into a clean conversation string.
    /// Only processes lines starting from `fromLine` (0-based). Returns the conversation and total line count.
    private func parseTranscript(at path: URL, fromLine: Int = 0) -> (conversation: String, totalLines: Int) {
        guard let data = try? Data(contentsOf: path) else {
            logger.error("Failed to read transcript file: \(path.path(percentEncoded: false))")
            return ("", 0)
        }

        let lines = data.split(separator: UInt8(ascii: "\n"))
        let totalLines = lines.count
        var parts: [String] = []

        for (index, line) in lines.enumerated() {
            guard index >= fromLine else { continue }

            guard let dict = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let type = dict["type"] as? String else { continue }

            // Only process user and assistant messages
            guard type == "user" || type == "assistant" else { continue }

            guard let message = dict["message"] as? [String: Any],
                  let content = message["content"] as? [Any] else { continue }

            let role = type == "user" ? "User" : "Assistant"

            for item in content {
                // Handle dict-style content items: {"type": "text", "text": "..."}
                if let itemDict = item as? [String: Any],
                   let itemType = itemDict["type"] as? String {
                    switch itemType {
                    case "text":
                        if let text = itemDict["text"] as? String, !text.isEmpty {
                            parts.append("[\(role)] \(text)")
                        }
                    case "tool_use":
                        if let toolName = itemDict["name"] as? String {
                            parts.append("[Assistant used tool: \(toolName)]")
                        }
                    default:
                        break
                    }
                }
            }

            // Handle raw string array: ["セ","ッ","シ",...] → "セッション..."
            let rawStrings = content.compactMap { $0 as? String }
            if !rawStrings.isEmpty {
                let joined = rawStrings.joined()
                if !joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    parts.append("[\(role)] \(joined)")
                }
            }
        }

        return (parts.joined(separator: "\n\n"), totalLines)
    }

    // MARK: - Shared Extraction Logic

    /// Returns `true` if extraction succeeded (even with 0 results), `false` if the LLM call failed.
    @discardableResult
    private func runExtraction(conversation: String, agentName: String, agent: Agent, provider: CLIProviderType = .claude) async -> Bool {
        let existingIndex = memoryService.loadMemoryIndex(for: agent)

        do {
            let actions = try await callExtractionLLM(
                conversation: conversation,
                existingMemories: existingIndex,
                provider: provider
            )
            logger.info("[\(agentName)] LLM returned \(actions.count) memory action(s)")

            for action in actions {
                do {
                    try memoryService.applyMemoryAction(action, for: agent)
                    logger.info("[\(agentName)] Applied action: \(String(describing: action))")
                } catch {
                    logger.error("[\(agentName)] Failed to apply action: \(error.localizedDescription)")
                }
            }

            try memoryService.rebuildIndex(for: agent)
            logger.info("[\(agentName)] Index rebuilt successfully")
            return true
        } catch {
            logger.error("[\(agentName)] LLM extraction failed: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Extraction Offset Tracking

    /// File name used to store the last-processed line offset per JSONL transcript.
    /// Stored in the agent's memory directory as `.extraction_offsets.json`.
    private func offsetsFilePath(for agent: Agent) -> URL? {
        agent.memoryDirectory?.appending(path: ".extraction_offsets.json")
    }

    private func loadAllOffsets(for agent: Agent) -> [String: Int] {
        guard let path = offsetsFilePath(for: agent),
              let data = try? Data(contentsOf: path),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Int] else {
            return [:]
        }
        return dict
    }

    private func loadLastOffset(jsonlPath: URL, agent: Agent) -> Int {
        let key = jsonlPath.lastPathComponent
        return loadAllOffsets(for: agent)[key] ?? 0
    }

    private func saveLastOffset(_ offset: Int, jsonlPath: URL, agent: Agent) {
        guard let path = offsetsFilePath(for: agent) else { return }
        var offsets = loadAllOffsets(for: agent)
        offsets[jsonlPath.lastPathComponent] = offset
        if let data = try? JSONSerialization.data(withJSONObject: offsets) {
            try? data.write(to: path)
        }
    }

    // MARK: - JSONL Path Resolution

    /// Resolve the JSONL transcript path from a Claude session ID and working directory.
    /// Claude Code stores transcripts at: ~/.claude/projects/{project-hash}/{sessionId}.jsonl
    static func resolveTranscriptPath(claudeSessionId: String, workingDirectory: String?) -> URL? {
        guard let cwd = workingDirectory else { return nil }

        // Claude Code encodes the project path by replacing "/" with "-"
        // Trim trailing slash to avoid extra "-" at the end
        let trimmedCwd = cwd.hasSuffix("/") ? String(cwd.dropLast()) : cwd
        let projectHash = trimmedCwd.replacingOccurrences(of: "/", with: "-")

        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let jsonlPath = homeDir
            .appending(path: ".claude/projects")
            .appending(path: projectHash)
            .appending(path: "\(claudeSessionId).jsonl")

        guard FileManager.default.fileExists(atPath: jsonlPath.path(percentEncoded: false)) else {
            logger.warning("Transcript not found: \(jsonlPath.path(percentEncoded: false))")
            return nil
        }

        return jsonlPath
    }

    // MARK: - ANSI Stripping

    func stripANSI(_ text: String) -> String {
        let pattern = "\\x1B\\[[0-9;]*[A-Za-z]|\\x1B\\][^\\x07]*\\x07|\\x1B\\([A-Z]|\\x1B\\[\\?[0-9;]*[A-Za-z]"
        return text.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
    }

    // MARK: - LLM Extraction

    private func callExtractionLLM(
        conversation: String,
        existingMemories: String,
        provider: CLIProviderType = .claude
    ) async throws -> [MemoryAction] {
        guard let cli = resolveExtractionCLI(preferring: provider) else {
            logger.warning("No CLI path found for extraction, skipping")
            return []
        }

        // Truncate from start, keeping the most recent conversation
        let maxChars = 80_000
        let truncated: String
        if conversation.count > maxChars {
            truncated = String(conversation.suffix(maxChars))
        } else {
            truncated = conversation
        }

        let prompt = buildExtractionPrompt(
            conversation: truncated,
            existingMemories: existingMemories
        )

        logger.info("Calling \(cli.provider.binaryName) extraction (prompt length: \(prompt.count) chars)")
        let result = try await executeCLIExtraction(
            cliPath: cli.path,
            provider: cli.provider,
            prompt: prompt
        )
        logger.info("\(cli.provider.binaryName) returned \(result.count) bytes")

        return parseExtractionResult(result, provider: cli.provider)
    }

    private func buildExtractionPrompt(conversation: String, existingMemories: String) -> String {
        return """
        Below is a conversation log between an AI agent and a user.
        Please extract information from this conversation that would be useful for future sessions.
        Be aggressive about extracting — it is better to extract too much than too little.
        IMPORTANT: Write the "description" and "content" fields in the SAME language the user used in the conversation. If the user spoke Japanese, write in Japanese. The "name" field should always be english_snake_case.

        ## What to extract
        - Corrections/feedback from the user ("don't do that", "do it this way") → type: feedback
        - User's role, expertise, preferences → type: user
        - Important project decisions and context → type: project
        - Locations/references to external resources → type: reference
        - Patterns and insights the agent has learned → type: learned

        ## What NOT to extract
        - Temporary information relevant only to the current task
        - Specific implementation details that can be derived from code or git history
        - Information already recorded in existing memories

        ## Existing memories (for deduplication)
        \(existingMemories.isEmpty ? "(none)" : existingMemories)

        ## Output format
        Return only the following JSON. If there is nothing to extract, return {"memories": []}.
        ```json
        {
          "memories": [
            {
              "action": "create",
              "name": "english_snake_case",
              "description": "one-line description",
              "type": "feedback|user|project|reference|learned",
              "content": "body text"
            }
          ]
        }
        ```

        ## Conversation log
        \(conversation)
        """
    }

    private func executeCLIExtraction(cliPath: String, provider: CLIProviderType, prompt: String) async throws -> Data {
        let process = Process()
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let escapedCli = cliPath.replacingOccurrences(of: " ", with: "\\ ")

        let tempFile = FileManager.default.temporaryDirectory
            .appending(path: "memory_extract_\(UUID().uuidString.prefix(8)).txt")
        try prompt.write(to: tempFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempFile) }

        let command: String
        switch provider {
        case .claude:
            command = "cat '\(tempFile.path(percentEncoded: false))' | \(escapedCli) -p --model \(AgentModel.sonnet.cliModelId(for: .claude)) --output-format json --tools \"\""
        case .codex:
            command = "cat '\(tempFile.path(percentEncoded: false))' | \(escapedCli) exec --ephemeral --sandbox read-only --json -m \(AgentModel.sonnet.cliModelId(for: .codex)) -"
        }

        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-l", "-c", command]

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        // Drain stderr to prevent buffer deadlock (64KB limit)
        stderr.fileHandleForReading.readabilityHandler = { handle in _ = handle.availableData }

        try process.run()

        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { _ in
                stderr.fileHandleForReading.readabilityHandler = nil
                let data = stdout.fileHandleForReading.readDataToEndOfFile()
                if process.terminationStatus == 0 {
                    continuation.resume(returning: data)
                } else {
                    let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
                    let stderrStr = String(data: stderrData, encoding: .utf8) ?? "(no stderr)"
                    logger.error("\(provider.binaryName) extraction failed (exit \(process.terminationStatus)): \(stderrStr)")
                    continuation.resume(throwing: MemoryExtractorError.extractionFailed)
                }
            }
        }
    }

    private func parseExtractionResult(_ data: Data, provider: CLIProviderType = .claude) -> [MemoryAction] {
        guard var jsonString = String(data: data, encoding: .utf8) else {
            logger.error("Failed to decode extraction result as UTF-8")
            return []
        }

        logger.info("Raw extraction result (\(provider.binaryName)): \(jsonString.prefix(500))")

        switch provider {
        case .claude:
            // --output-format json wraps Claude's response in {"type":"result","result":"...",...}
            if let outerData = jsonString.data(using: .utf8),
               let outerDict = try? JSONSerialization.jsonObject(with: outerData) as? [String: Any],
               let resultStr = outerDict["result"] as? String {
                jsonString = resultStr
                logger.info("Unwrapped CLI JSON wrapper, inner result: \(jsonString.prefix(300))")
            }

        case .codex:
            // codex exec --json outputs JSONL events, one per line.
            // Extract the text from the last item.completed event with type "agent_message".
            let lines = jsonString.split(separator: "\n")
            var extractedText: String?
            for line in lines.reversed() {
                guard let lineData = line.data(using: .utf8),
                      let event = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                      let eventType = event["type"] as? String,
                      eventType == "item.completed",
                      let item = event["item"] as? [String: Any],
                      let itemType = item["type"] as? String,
                      itemType == "agent_message",
                      let text = item["text"] as? String else { continue }
                extractedText = text
                break
            }
            if let text = extractedText {
                jsonString = text
                logger.info("Extracted text from Codex JSONL: \(jsonString.prefix(300))")
            }
        }

        // Strip markdown code fences if present
        if let jsonStart = jsonString.range(of: "{"),
           let jsonEnd = jsonString.range(of: "}", options: .backwards) {
            jsonString = String(jsonString[jsonStart.lowerBound...jsonEnd.upperBound])
        }

        guard let jsonData = jsonString.data(using: .utf8),
              let response = try? JSONDecoder().decode(MemoryExtractionResponse.self, from: jsonData) else {
            logger.error("Failed to parse extraction JSON: \(jsonString.prefix(300))")
            return []
        }

        let actions = response.memories.compactMap { $0.toMemoryAction() }
        logger.info("Parsed \(actions.count) memory action(s) from extraction result")
        return actions
    }

    // MARK: - Transcript DB Sync

    /// Save conversation text to the transcripts table for FTS5 search.
    private func saveTranscriptToDatabase(sessionId: String, agentName: String, content: String, agent: Agent) {
        guard let manager = databaseManager else { return }

        let db: MemoryDatabase?
        if agent.scope == .user {
            db = manager.globalDatabase()
        } else {
            db = agent.projectRootDirectory.flatMap { manager.database(for: $0) }
        }

        guard let db else { return }

        do {
            try db.upsertTranscript(
                id: sessionId,
                sessionId: sessionId,
                agentName: agentName,
                content: content
            )
            logger.info("[\(agentName)] Saved transcript to DB (\(content.count) chars)")
        } catch {
            logger.error("[\(agentName)] Failed to save transcript: \(error.localizedDescription)")
        }
    }

}

// MARK: - Errors

enum MemoryExtractorError: Error {
    case extractionFailed
}
