import Foundation

/// Manages per-project MemoryDatabase instances and handles startup sync.
final class MemoryDatabaseManager: @unchecked Sendable {

    /// Shared embedding service for generating vectors (lazy, actor-based).
    let embeddingService = EmbeddingService()

    /// Base directory: ~/Library/Application Support/Conclawd/memory/
    private static let baseDir: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appending(path: "Conclawd/memory")
    }()

    /// Cached database instances keyed by project hash.
    private var databases: [String: MemoryDatabase] = [:]
    private let lock = NSLock()

    // MARK: - Database Access

    /// Get (or create) the database for a project.
    func database(for projectRoot: URL) -> MemoryDatabase? {
        let hash = Self.projectHash(from: projectRoot)
        return database(forHash: hash)
    }

    /// Get (or create) the global database for user-scoped agents.
    func globalDatabase() -> MemoryDatabase? {
        database(forHash: "_global")
    }

    private func database(forHash hash: String) -> MemoryDatabase? {
        lock.lock()
        defer { lock.unlock() }

        if let existing = databases[hash] {
            return existing
        }

        let dbPath = Self.baseDir
            .appending(path: hash)
            .appending(path: "memory.db")
            .path(percentEncoded: false)

        do {
            let db = try MemoryDatabase(path: dbPath)
            databases[hash] = db
            return db
        } catch {
            print("[MemoryDatabaseManager] Failed to open database at \(dbPath): \(error)")
            return nil
        }
    }

    // MARK: - Sync

    /// Sync all memories from .md files to SQLite for a given agent.
    func syncMemories(_ memories: [AgentMemory], agentName: String, ownership: MemoryOwnership = .agent, database db: MemoryDatabase) {
        do {
            let existingStamps = try db.memoryStamps(agentName: agentName)
            let iso = ISO8601DateFormatter()
            var currentIds = Set<String>()

            for memory in memories {
                let idStr = memory.id.uuidString
                currentIds.insert(idStr)

                let updatedStr = iso.string(from: memory.updatedAt)
                if existingStamps[idStr] == updatedStr {
                    continue  // Already up-to-date
                }

                try db.upsertMemory(memory, agentName: agentName, ownership: ownership)
            }

            // Delete memories that no longer exist as .md files
            let staleIds = Set(existingStamps.keys).subtracting(currentIds)
            if !staleIds.isEmpty {
                // Only delete for this agent — don't touch other agents' memories
                for staleId in staleIds {
                    try db.deleteMemory(id: staleId)
                }
            }
        } catch {
            print("[MemoryDatabaseManager] Sync failed for \(agentName): \(error)")
        }
    }

    /// Perform startup sync for all agents in a project.
    func startupSync(agents: [Agent], memoryService: AgentMemoryService, projectRoot: URL?) {
        guard let projectRoot, let db = database(for: projectRoot) else {
            print("[MemoryDatabaseManager] startupSync skipped — projectRoot: \(projectRoot?.path(percentEncoded: false) ?? "nil")")
            return
        }

        print("[MemoryDatabaseManager] startupSync started — \(agents.count) agents, projectRoot: \(projectRoot.path(percentEncoded: false))")
        for agent in agents {
            print("[MemoryDatabaseManager]   agent: \(agent.name) scope=\(agent.scope) memoryEnabled=\(agent.memoryEnabled) filePath=\(agent.filePath?.path(percentEncoded: false) ?? "nil")")
        }

        for agent in agents where agent.memoryEnabled {
            let memories = memoryService.loadMemories(for: agent)
            let baseName = agent.filePath?.deletingPathExtension().lastPathComponent ?? agent.name
            // Prefix user-scope agents to avoid name collision with project-scope agents
            let agentName = agent.scope == .user ? "~user/\(baseName)" : baseName
            let dirs = agent.allMemoryDirectories
            print("[MemoryDatabaseManager] Syncing \(agentName) (scope=\(agent.scope)): \(memories.count) memories, dirs=\(dirs.map { "\($0.storage): \($0.url.path(percentEncoded: false))" })")
            syncMemories(memories, agentName: agentName, ownership: agent.memoryOwnership, database: db)
        }

        // Cleanup old recall logs
        try? db.cleanupOldRecallLogs()
    }

    /// Trigger embedding generation for a project (call separately from startupSync).
    func generateEmbeddingsInBackground(for projectRoot: URL) {
        guard EmbeddingService.isModelAvailable else { return }
        guard let db = database(for: projectRoot) else { return }
        Task.detached(priority: .background) { [embeddingService] in
            await Self.generateMissingEmbeddings(db: db, embeddingService: embeddingService)
        }
    }

    /// Trigger embedding generation for the global (user-scope) database.
    func generateGlobalEmbeddingsInBackground() {
        guard EmbeddingService.isModelAvailable else { return }
        guard let db = globalDatabase() else { return }
        Task.detached(priority: .background) { [embeddingService] in
            await Self.generateMissingEmbeddings(db: db, embeddingService: embeddingService)
        }
    }

    /// Generate embeddings for memories that don't have one yet.
    /// Runs in background — processes in batches of 50.
    static func generateMissingEmbeddings(db: MemoryDatabase, embeddingService: EmbeddingService) async {
        guard EmbeddingService.isModelAvailable else { return }

        do {
            let ids = try db.memoriesWithoutEmbedding(limit: 50)
            guard !ids.isEmpty else { return }
            print("[MemoryDatabaseManager] Generating embeddings for \(ids.count) memories")

            var successCount = 0
            for id in ids {
                guard let text = try db.memoryContent(id: id) else { continue }
                do {
                    let embedding = try await embeddingService.generateEmbedding(for: text)
                    try db.updateEmbedding(id: id, embedding: embedding)
                    successCount += 1
                } catch {
                    print("[MemoryDatabaseManager] Embedding generation failed for \(id): \(error)")
                }
            }

            // Stop if no progress was made (all failed) to avoid infinite loop
            guard successCount > 0 else {
                print("[MemoryDatabaseManager] No embeddings generated — stopping to avoid retry loop")
                return
            }

            // If there were more, schedule another batch
            let remaining = try db.memoriesWithoutEmbedding(limit: 1)
            if !remaining.isEmpty {
                await generateMissingEmbeddings(db: db, embeddingService: embeddingService)
            }
        } catch {
            print("[MemoryDatabaseManager] Batch embedding error: \(error)")
        }
    }

    /// Generate embedding for a single memory (called after save/update).
    func generateEmbeddingAsync(memoryId: String, db: MemoryDatabase) {
        guard EmbeddingService.isModelAvailable else { return }
        Task.detached(priority: .utility) { [embeddingService] in
            do {
                guard let text = try db.memoryContent(id: memoryId) else { return }
                let embedding = try await embeddingService.generateEmbedding(for: text)
                try db.updateEmbedding(id: memoryId, embedding: embedding)
            } catch {
                print("[MemoryDatabaseManager] Single embedding failed for \(memoryId): \(error)")
            }
        }
    }

    // MARK: - Helpers

    /// Project hash: same algorithm as Agent.memoryDirectory (path with / → -)
    static func projectHash(from projectRoot: URL) -> String {
        projectRoot.path(percentEncoded: false)
            .replacingOccurrences(of: "/", with: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    /// The DB file path for a given project root (for passing to MCP server via env var).
    func databasePath(for projectRoot: URL) -> String? {
        database(for: projectRoot)?.path
    }

    /// The DB file path for the global (user-scope) database.
    func globalDatabasePath() -> String? {
        globalDatabase()?.path
    }

    /// Resolve DB path from an agent's scope: project-scoped → project DB, user-scoped → global DB.
    func databasePath(for agent: Agent) -> String? {
        if agent.scope == .user {
            return globalDatabasePath()
        }
        guard let projectRoot = agent.projectRootDirectory else { return nil }
        return databasePath(for: projectRoot)
    }

    /// Resolve DB path from an optional agent, with a fallback project path (e.g. from SessionRecord).
    func databasePath(for agent: Agent?, fallbackProjectPath: String? = nil) -> String? {
        if let agent {
            return databasePath(for: agent)
        }
        // Fallback: try to resolve from the session's project path
        if let path = fallbackProjectPath {
            return databasePath(for: URL(filePath: path))
        }
        return nil
    }
}
