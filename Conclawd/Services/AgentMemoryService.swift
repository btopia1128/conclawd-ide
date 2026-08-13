import Foundation
import os
import Yams

/// Manages agent memory files: CRUD, inbox processing, and context building.
final class AgentMemoryService: @unchecked Sendable {

    /// Optional database manager for FTS5 sync. Set by AppState on init.
    var databaseManager: MemoryDatabaseManager?

    // MARK: - Read

    /// Load all memories from both shared and private directories.
    func loadMemories(for agent: Agent) -> [AgentMemory] {
        let fm = FileManager.default
        var allMemories: [AgentMemory] = []

        for (storage, dir) in agent.allMemoryDirectories {
            let dirPath = dir.path(percentEncoded: false)
            guard fm.fileExists(atPath: dirPath) else { continue }
            do {
                let files = try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
                let memories = files
                    .filter { $0.pathExtension == "md" && $0.lastPathComponent != "MEMORY.md" && !$0.lastPathComponent.hasPrefix("inbox") }
                    .compactMap { url -> AgentMemory? in
                        guard var memory = parseMemoryFile(at: url) else { return nil }
                        memory.storage = storage
                        return memory
                    }
                allMemories.append(contentsOf: memories)
            } catch {
                continue
            }
        }

        return allMemories.sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Load the MEMORY.md index text (for duplicate checking during extraction).
    /// Combines indexes from both shared and private directories.
    func loadMemoryIndex(for agent: Agent) -> String {
        var parts: [String] = []
        for (_, dir) in agent.allMemoryDirectories {
            let indexPath = dir.appending(path: "MEMORY.md")
            if let content = try? String(contentsOf: indexPath, encoding: .utf8) {
                parts.append(content)
            }
        }
        return parts.joined(separator: "\n")
    }

    /// Build the memory context for --append-system-prompt injection.
    /// Injects past memories so the agent has context from previous sessions.
    /// Memory saving is handled automatically by analyzing the session transcript on termination.
    ///
    /// Strategy:
    /// 1. Always inject pinned memories (self + global)
    /// 2. Always inject type=feedback memories (self + global)
    /// 3. If total memories <= limit, inject all (legacy behavior)
    /// 4. Otherwise, use FTS5 to select top-K relevant memories using the agent description as query
    func buildMemoryContext(for agent: Agent, userMessage: String? = nil) -> String {
        let memories = loadMemories(for: agent)
        // Also load global memories
        let globalMemories = loadGlobalMemories(for: agent)
        let allMemories = memories + globalMemories
        guard !allMemories.isEmpty else { return "" }

        let limit = agent.effectiveMemoryLimit

        // Step 1 & 2: Always-inject categories
        let pinned = allMemories.filter { $0.pinned }
        let feedback = allMemories.filter { !$0.pinned && $0.type == .feedback }
        let alwaysInject = pinned + feedback
        let alwaysInjectIds = Set(alwaysInject.map { $0.id })

        // Step 3: If small enough, use all
        let remaining = allMemories.filter { !alwaysInjectIds.contains($0.id) }
        let remainingSlots = max(0, limit - alwaysInject.count)

        var topK: [AgentMemory] = []

        if remaining.count <= remainingSlots {
            // Small memory set: inject everything
            topK = remaining
        } else if let db = resolveDatabase(for: agent) {
            // Step 4: Hybrid search (FTS5 + embedding when available)
            let queryText = buildSearchQuery(agent: agent, userMessage: userMessage)
            if !queryText.isEmpty {
                let agentName = agent.filePath?.deletingPathExtension().lastPathComponent ?? agent.name

                // Try hybrid search with embedding
                let queryEmbedding = generateQueryEmbedding(queryText)
                if let results = try? db.hybridSearch(
                    query: queryText,
                    queryEmbedding: queryEmbedding,
                    agentName: agentName,
                    scope: "self",
                    limit: remainingSlots
                ) {
                    let resultIds = Set(results.map { $0.id })
                    topK = remaining.filter { resultIds.contains($0.id.uuidString) }
                }
            }

            // If search returned too few, fill with recency
            if topK.count < remainingSlots {
                let topKIds = Set(topK.map { $0.id })
                let fallback = remaining.filter { !topKIds.contains($0.id) }
                    .prefix(remainingSlots - topK.count)
                topK.append(contentsOf: fallback)
            }
        } else {
            // No database available: fallback to recency
            topK = Array(remaining.prefix(remainingSlots))
        }

        let toInject = alwaysInject + topK

        var parts: [String] = []
        parts.append("<agent-memory>")
        parts.append("")
        parts.append("## Past Memories")
        parts.append("Below are memories accumulated from this agent's previous sessions.")
        parts.append("Use these as reference while working on the current task.")
        parts.append("If existing memories are outdated or incorrect, prioritize the current situation rather than blindly following them.")
        parts.append("")

        for memory in toInject {
            parts.append("### \(memory.type.rawValue): \(memory.description)")
            parts.append(memory.content)
            parts.append("")
        }

        parts.append("</agent-memory>")

        return parts.joined(separator: "\n")
    }

    /// Generate a query embedding synchronously (blocking).
    /// Returns nil if embedding is unavailable (model not bundled, or error).
    private func generateQueryEmbedding(_ text: String) -> [Float]? {
        guard let manager = databaseManager, EmbeddingService.isModelAvailable else { return nil }
        let service = manager.embeddingService
        let semaphore = DispatchSemaphore(value: 0)
        let resultHolder = OSAllocatedUnfairLock<[Float]?>(initialState: nil)
        Task.detached(priority: .userInitiated) {
            let embedding = try? await service.generateQueryEmbedding(for: text)
            resultHolder.withLock { $0 = embedding }
            semaphore.signal()
        }
        // Timeout after 5 seconds — fallback to FTS5-only if embedding is slow
        _ = semaphore.wait(timeout: .now() + 5)
        return resultHolder.withLock { $0 }
    }

    /// Build a search query from agent description and optional user message.
    private func buildSearchQuery(agent: Agent, userMessage: String?) -> String {
        var parts: [String] = []
        if !agent.description.isEmpty {
            parts.append(agent.description)
        }
        if let msg = userMessage, !msg.isEmpty {
            parts.append(msg)
        }
        // Fallback: use agent name
        if parts.isEmpty {
            parts.append(agent.name)
        }
        return parts.joined(separator: " ")
    }

    /// Load global memories (from .claude/memory/ directories).
    func loadGlobalMemories(for agent: Agent) -> [AgentMemory] {
        let fm = FileManager.default
        var allMemories: [AgentMemory] = []

        // Shared global: {projectRoot}/.claude/memory/
        if let projectRoot = agent.projectRootDirectory {
            let sharedGlobal = projectRoot.appending(path: ".claude/memory")
            if let memories = loadMemoriesFromDirectory(sharedGlobal, storage: .shared, ownership: .global, fm: fm) {
                allMemories.append(contentsOf: memories)
            }
        }

        // Private global: ~/.claude/memory/
        let home = FileManager.default.homeDirectoryForCurrentUser
        let privateGlobal = home.appending(path: ".claude/memory")
        if let memories = loadMemoriesFromDirectory(privateGlobal, storage: .private, ownership: .global, fm: fm) {
            allMemories.append(contentsOf: memories)
        }

        return allMemories.sorted { $0.updatedAt > $1.updatedAt }
    }

    private func loadMemoriesFromDirectory(_ dir: URL, storage: MemoryStorage, ownership: MemoryOwnership, fm: FileManager) -> [AgentMemory]? {
        let dirPath = dir.path(percentEncoded: false)
        guard fm.fileExists(atPath: dirPath) else { return nil }
        do {
            let files = try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            return files
                .filter { $0.pathExtension == "md" && $0.lastPathComponent != "MEMORY.md" && !$0.lastPathComponent.hasPrefix("inbox") }
                .compactMap { url -> AgentMemory? in
                    guard var memory = parseMemoryFile(at: url) else { return nil }
                    memory.storage = storage
                    memory.ownership = ownership
                    return memory
                }
        } catch {
            return nil
        }
    }

    // MARK: - Write

    /// Save a new memory file and update the index.
    /// Uses the memory's `storage` property to determine save location.
    func saveMemory(_ memory: AgentMemory, for agent: Agent) throws {
        guard let memoryDir = agent.memoryDirectory(for: memory.storage) else { return }
        try ensureDirectoryExists(memoryDir)

        let sanitizedName = sanitizeFileName(memory.name)
        let fileName = "\(sanitizedName).md"
        let filePath = memoryDir.appending(path: fileName)

        let content = serializeMemory(memory)
        try content.write(to: filePath, atomically: true, encoding: .utf8)

        try appendToIndex(memoryDir: memoryDir, fileName: fileName, description: memory.description)

        // Sync to SQLite
        syncToDatabase(memory, agent: agent)
    }

    /// Update an existing memory file.
    func updateMemory(_ memory: AgentMemory, for agent: Agent) throws {
        guard let filePath = memory.filePath else { return }
        var updated = memory
        updated.updatedAt = Date()
        let content = serializeMemory(updated)
        try content.write(to: filePath, atomically: true, encoding: .utf8)

        // Sync to SQLite
        syncToDatabase(updated, agent: agent)
    }

    /// Delete a memory file and remove from index.
    func deleteMemory(_ memory: AgentMemory, for agent: Agent) throws {
        guard let filePath = memory.filePath else { return }
        let memoryDir = filePath.deletingLastPathComponent()
        let fileName = filePath.lastPathComponent
        try? FileManager.default.removeItem(at: filePath)

        try removeFromIndex(memoryDir: memoryDir, fileName: fileName)

        // Sync to SQLite
        if let db = resolveDatabase(for: agent) {
            try? db.deleteMemory(id: memory.id.uuidString)
        }
    }

    // MARK: - Inbox Processing

    /// Process all inbox files in the memory directory.
    func processInbox(for agent: Agent) throws {
        guard let memoryDir = agent.memoryDirectory else {
            print("[Memory] processInbox: no memory directory for \(agent.name)")
            return
        }
        let fm = FileManager.default
        let dirPath = memoryDir.path(percentEncoded: false)
        guard fm.fileExists(atPath: dirPath) else {
            print("[Memory] processInbox: directory does not exist: \(dirPath)")
            return
        }

        let files = try fm.contentsOfDirectory(at: memoryDir, includingPropertiesForKeys: nil)
        let inboxFiles = files.filter { $0.lastPathComponent.hasPrefix("inbox_") && $0.pathExtension == "md" }

        print("[Memory] processInbox: found \(inboxFiles.count) inbox file(s) in \(dirPath)")

        for inboxFile in inboxFiles {
            try processInboxFile(inboxFile, for: agent)
        }
    }

    /// Process a single inbox file: parse entries, save as individual memories, clear the file.
    private func processInboxFile(_ inboxPath: URL, for agent: Agent) throws {
        guard let content = try? String(contentsOf: inboxPath, encoding: .utf8),
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            print("[Memory] processInboxFile: empty or unreadable: \(inboxPath.lastPathComponent)")
            return
        }

        print("[Memory] processInboxFile: \(inboxPath.lastPathComponent) has \(content.count) chars")

        let memories = parseInbox(content)
        print("[Memory] processInboxFile: parsed \(memories.count) memory entries")

        for memory in memories {
            try saveMemory(memory, for: agent)
            print("[Memory] processInboxFile: saved memory '\(memory.name)' (\(memory.type.rawValue))")
        }

        // Clear the inbox file
        try "".write(to: inboxPath, atomically: true, encoding: .utf8)
    }

    // MARK: - Index Rebuild

    /// Rebuild MEMORY.md for each memory directory.
    func rebuildIndex(for agent: Agent) throws {
        let allMemories = loadMemories(for: agent)

        for (storage, dir) in agent.allMemoryDirectories {
            let memoriesInDir = allMemories.filter { $0.storage == storage }
            guard !memoriesInDir.isEmpty else { continue }

            var lines = ["# Memory Index", ""]
            for memory in memoriesInDir {
                let fileName = memory.filePath?.lastPathComponent ?? "\(memory.name).md"
                lines.append("- [\(fileName)](\(fileName)) - \(memory.description)")
            }
            lines.append("")

            let indexPath = dir.appending(path: "MEMORY.md")
            try lines.joined(separator: "\n").write(to: indexPath, atomically: true, encoding: .utf8)
        }
    }

    // MARK: - Apply Memory Action (from LLM extraction)

    func applyMemoryAction(_ action: MemoryAction, for agent: Agent) throws {
        switch action {
        case .create(let name, let description, let type, let content):
            let memory = AgentMemory(
                name: name,
                description: description,
                type: type,
                content: content,
                storage: agent.memoryStorage
            )
            try saveMemory(memory, for: agent)

        case .update(let existingFile, let content):
            guard let (memory, _) = findMemoryFile(named: existingFile, for: agent) else { return }
            var updated = memory
            updated.content = content
            try updateMemory(updated, for: agent)

        case .delete(let existingFile, _):
            guard let (memory, _) = findMemoryFile(named: existingFile, for: agent) else { return }
            try deleteMemory(memory, for: agent)
        }
    }

    // MARK: - Parsing

    /// Parse a memory .md file with YAML frontmatter.
    func parseMemoryFile(at url: URL) -> AgentMemory? {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let (frontmatter, body) = splitFrontmatter(content)
        guard let yaml = frontmatter,
              let dict = try? Yams.load(yaml: yaml) as? [String: Any] else { return nil }

        let name = dict["name"] as? String ?? url.deletingPathExtension().lastPathComponent
        let description = dict["description"] as? String ?? ""
        let typeStr = dict["type"] as? String ?? "learned"
        let type = AgentMemoryType(rawValue: typeStr) ?? .learned

        let dateFormatter = ISO8601DateFormatter()
        let createdAt = (dict["createdAt"] as? String).flatMap { dateFormatter.date(from: $0) } ?? Date()
        let updatedAt = (dict["updatedAt"] as? String).flatMap { dateFormatter.date(from: $0) } ?? Date()
        let pinned = dict["pinned"] as? Bool ?? false

        return AgentMemory(
            name: name,
            description: description,
            type: type,
            content: body.trimmingCharacters(in: .whitespacesAndNewlines),
            createdAt: createdAt,
            updatedAt: updatedAt,
            filePath: url,
            pinned: pinned
        )
    }

    /// Parse inbox content into individual memories.
    /// Supports both JSON Lines format (preferred) and legacy YAML frontmatter format.
    func parseInbox(_ content: String) -> [AgentMemory] {
        let lines = content.components(separatedBy: "\n")

        // Try JSON Lines first (new format)
        var jsonMemories: [AgentMemory] = []
        var hasJson = false
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard trimmed.hasPrefix("{") else { continue }
            guard let data = trimmed.data(using: .utf8),
                  let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            hasJson = true
            let name = dict["name"] as? String ?? "auto_\(Int(Date().timeIntervalSince1970))"
            let description = dict["description"] as? String ?? ""
            let typeStr = dict["type"] as? String ?? "learned"
            let type = AgentMemoryType(rawValue: typeStr) ?? .learned
            let body = dict["content"] as? String ?? ""
            let memory = AgentMemory(
                name: name,
                description: description.isEmpty ? String(body.prefix(80)) : description,
                type: type,
                content: body.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            jsonMemories.append(memory)
        }
        if hasJson { return jsonMemories }

        // Fallback: legacy YAML frontmatter format (--- delimited blocks)
        var memories: [AgentMemory] = []
        var blocks: [String] = []
        var currentBlock: [String] = []
        var inBlock = false

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "---" {
                if inBlock {
                    let blockContent = currentBlock.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                    if !blockContent.isEmpty {
                        blocks.append(blockContent)
                    }
                    currentBlock = []
                    inBlock = false
                } else {
                    inBlock = true
                }
            } else {
                currentBlock.append(line)
                if !inBlock {
                    inBlock = true
                }
            }
        }

        let lastBlock = currentBlock.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if !lastBlock.isEmpty {
            blocks.append(lastBlock)
        }

        var i = 0
        while i < blocks.count {
            let block = blocks[i]

            if let dict = try? Yams.load(yaml: block) as? [String: Any],
               dict["name"] != nil || dict["type"] != nil {
                let body = (i + 1 < blocks.count) ? blocks[i + 1] : ""
                let name = dict["name"] as? String ?? "auto_\(Int(Date().timeIntervalSince1970))"
                let description = dict["description"] as? String ?? String(body.prefix(80))
                let typeStr = dict["type"] as? String ?? "learned"
                let type = AgentMemoryType(rawValue: typeStr) ?? .learned

                let memory = AgentMemory(
                    name: name,
                    description: description,
                    type: type,
                    content: body.trimmingCharacters(in: .whitespacesAndNewlines)
                )
                memories.append(memory)
                i += 2
            } else {
                let memory = AgentMemory(
                    name: "auto_\(Int(Date().timeIntervalSince1970))_\(i)",
                    description: String(block.prefix(80)),
                    type: .learned,
                    content: block
                )
                memories.append(memory)
                i += 1
            }
        }

        return memories
    }

    // MARK: - Serialization

    private func serializeMemory(_ memory: AgentMemory) -> String {
        let formatter = ISO8601DateFormatter()
        var lines: [String] = []
        lines.append("---")
        lines.append("name: \(memory.name)")
        lines.append("description: \(memory.description)")
        lines.append("type: \(memory.type.rawValue)")
        lines.append("createdAt: \(formatter.string(from: memory.createdAt))")
        lines.append("updatedAt: \(formatter.string(from: memory.updatedAt))")
        if memory.pinned {
            lines.append("pinned: true")
        }
        lines.append("---")
        lines.append("")
        lines.append(memory.content)
        lines.append("")
        return lines.joined(separator: "\n")
    }

    // MARK: - Database Sync

    /// Resolve the MemoryDatabase for the given agent.
    private func resolveDatabase(for agent: Agent) -> MemoryDatabase? {
        guard let manager = databaseManager else { return nil }
        if agent.scope == .user {
            return manager.globalDatabase()
        }
        guard let projectRoot = agent.projectRootDirectory else { return nil }
        return manager.database(for: projectRoot)
    }

    /// Sync a single memory to the database after a file write.
    /// Also triggers async embedding generation for the upserted memory.
    private func syncToDatabase(_ memory: AgentMemory, agent: Agent) {
        guard agent.memoryDbSyncEnabled else { return }
        guard let manager = databaseManager, let db = resolveDatabase(for: agent) else { return }
        let agentName = agent.memoryOwnership == .global
            ? "_global"
            : (agent.filePath?.deletingPathExtension().lastPathComponent ?? agent.name)
        try? db.upsertMemory(memory, agentName: agentName, ownership: agent.memoryOwnership)

        // Layer 3: Generate embedding asynchronously
        if agent.memoryEmbeddingEnabled {
            manager.generateEmbeddingAsync(memoryId: memory.id.uuidString, db: db)
        }
    }

    // MARK: - Helpers

    /// Find a memory file by name across all memory directories.
    private func findMemoryFile(named fileName: String, for agent: Agent) -> (AgentMemory, URL)? {
        for (storage, dir) in agent.allMemoryDirectories {
            let filePath = dir.appending(path: fileName)
            if var memory = parseMemoryFile(at: filePath) {
                memory.storage = storage
                return (memory, filePath)
            }
        }
        return nil
    }

    private func splitFrontmatter(_ content: String) -> (frontmatter: String?, body: String) {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("---") else { return (nil, content) }
        let afterFirst = trimmed.dropFirst(3)
        guard let endRange = afterFirst.range(of: "\n---") else { return (nil, content) }
        let yaml = String(afterFirst[afterFirst.startIndex..<endRange.lowerBound])
        let body = String(afterFirst[endRange.upperBound...])
        return (yaml.trimmingCharacters(in: .whitespacesAndNewlines),
                body.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func sanitizeFileName(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
        return String(name.unicodeScalars.filter { allowed.contains($0) })
    }

    private func ensureDirectoryExists(_ url: URL) throws {
        let fm = FileManager.default
        let path = url.path(percentEncoded: false)
        if !fm.fileExists(atPath: path) {
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }
}

    // MARK: - Index Helpers

    private func appendToIndex(memoryDir: URL, fileName: String, description: String) throws {
        let indexPath = memoryDir.appending(path: "MEMORY.md")
        let fm = FileManager.default

        if !fm.fileExists(atPath: indexPath.path(percentEncoded: false)) {
            try "# Memory Index\n\n".write(to: indexPath, atomically: true, encoding: .utf8)
        }

        let line = "- [\(fileName)](\(fileName)) - \(description)\n"
        let handle = try FileHandle(forWritingTo: indexPath)
        handle.seekToEndOfFile()
        handle.write(line.data(using: .utf8)!)
        try handle.close()
    }

    private func removeFromIndex(memoryDir: URL, fileName: String) throws {
        let indexPath = memoryDir.appending(path: "MEMORY.md")
        guard let content = try? String(contentsOf: indexPath, encoding: .utf8) else { return }
        let filtered = content.components(separatedBy: "\n")
            .filter { !$0.contains("[\(fileName)]") }
            .joined(separator: "\n")
        try filtered.write(to: indexPath, atomically: true, encoding: .utf8)
    }
