import Foundation
import GRDB

/// SQLite/FTS5-based search index for agent memories.
/// This is NOT the source of truth — .md files are. The DB can be rebuilt from .md at any time.
final class MemoryDatabase: Sendable {

    private let dbQueue: DatabaseQueue

    /// Opens (or creates) the database at the given path with WAL mode.
    init(path: String) throws {
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        var config = Configuration()
        config.prepareDatabase { db in
            // WAL mode: allows concurrent reads from MCP server / DB Browser
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            try db.execute(sql: "PRAGMA busy_timeout = 5000")
        }

        dbQueue = try DatabaseQueue(path: path, configuration: config)
        try migrate()
    }

    // MARK: - Schema

    private func migrate() throws {
        try dbQueue.write { db in
            // memories table
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS memories (
                    id TEXT PRIMARY KEY,
                    agent_name TEXT NOT NULL,
                    name TEXT NOT NULL,
                    description TEXT,
                    type TEXT NOT NULL,
                    content TEXT NOT NULL,
                    file_path TEXT NOT NULL,
                    ownership TEXT NOT NULL DEFAULT 'agent',
                    storage TEXT NOT NULL,
                    pinned INTEGER DEFAULT 0,
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL
                )
                """)
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_memories_agent ON memories(agent_name)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_memories_ownership ON memories(ownership)")

            // FTS5 index for memories
            if try !tableExists(db, name: "memories_fts") {
                try db.execute(sql: """
                    CREATE VIRTUAL TABLE memories_fts USING fts5(
                        agent_name, name, description, content,
                        content=memories,
                        tokenize='unicode61'
                    )
                    """)

                // Sync triggers
                try db.execute(sql: """
                    CREATE TRIGGER memories_ai AFTER INSERT ON memories BEGIN
                        INSERT INTO memories_fts(rowid, agent_name, name, description, content)
                        VALUES (new.rowid, new.agent_name, new.name, new.description, new.content);
                    END
                    """)
                try db.execute(sql: """
                    CREATE TRIGGER memories_ad AFTER DELETE ON memories BEGIN
                        INSERT INTO memories_fts(memories_fts, rowid, agent_name, name, description, content)
                        VALUES ('delete', old.rowid, old.agent_name, old.name, old.description, old.content);
                    END
                    """)
                try db.execute(sql: """
                    CREATE TRIGGER memories_au AFTER UPDATE ON memories BEGIN
                        INSERT INTO memories_fts(memories_fts, rowid, agent_name, name, description, content)
                        VALUES ('delete', old.rowid, old.agent_name, old.name, old.description, old.content);
                        INSERT INTO memories_fts(rowid, agent_name, name, description, content)
                        VALUES (new.rowid, new.agent_name, new.name, new.description, new.content);
                    END
                    """)
            }

            // transcripts table
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS transcripts (
                    id TEXT PRIMARY KEY,
                    session_id TEXT NOT NULL,
                    agent_name TEXT,
                    content TEXT NOT NULL,
                    created_at TEXT NOT NULL
                )
                """)

            if try !tableExists(db, name: "transcripts_fts") {
                try db.execute(sql: """
                    CREATE VIRTUAL TABLE transcripts_fts USING fts5(
                        content,
                        content=transcripts,
                        tokenize='unicode61'
                    )
                    """)

                try db.execute(sql: """
                    CREATE TRIGGER transcripts_ai AFTER INSERT ON transcripts BEGIN
                        INSERT INTO transcripts_fts(rowid, content) VALUES (new.rowid, new.content);
                    END
                    """)
                try db.execute(sql: """
                    CREATE TRIGGER transcripts_ad AFTER DELETE ON transcripts BEGIN
                        INSERT INTO transcripts_fts(transcripts_fts, rowid, content) VALUES ('delete', old.rowid, old.content);
                    END
                    """)
            }

            // Add embedding column (Phase 2 migration)
            if try !columnExists(db, table: "memories", column: "embedding") {
                try db.execute(sql: "ALTER TABLE memories ADD COLUMN embedding BLOB")
            }

            // recall_logs table
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS recall_logs (
                    id TEXT PRIMARY KEY,
                    session_id TEXT NOT NULL,
                    agent_name TEXT NOT NULL,
                    query TEXT NOT NULL,
                    scope TEXT NOT NULL DEFAULT 'self',
                    result_count INTEGER NOT NULL,
                    results_json TEXT NOT NULL,
                    created_at TEXT NOT NULL
                )
                """)
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_recall_logs_session ON recall_logs(session_id)")
        }
    }

    private func tableExists(_ db: Database, name: String) throws -> Bool {
        let count = try Int.fetchOne(db, sql: "SELECT count(*) FROM sqlite_master WHERE type='table' AND name=?", arguments: [name])
        return (count ?? 0) > 0
    }

    private func columnExists(_ db: Database, table: String, column: String) throws -> Bool {
        let rows = try Row.fetchAll(db, sql: "PRAGMA table_info(\(table))")
        return rows.contains { ($0["name"] as String) == column }
    }

    // MARK: - Memory CRUD

    func upsertMemory(_ memory: AgentMemory, agentName: String, ownership: MemoryOwnership = .agent) throws {
        let iso = ISO8601DateFormatter()
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO memories (id, agent_name, name, description, type, content, file_path, ownership, storage, pinned, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        name = excluded.name,
                        description = excluded.description,
                        type = excluded.type,
                        content = excluded.content,
                        file_path = excluded.file_path,
                        ownership = excluded.ownership,
                        storage = excluded.storage,
                        pinned = excluded.pinned,
                        updated_at = excluded.updated_at
                    """,
                arguments: [
                    memory.id.uuidString,
                    agentName,
                    memory.name,
                    memory.description,
                    memory.type.rawValue,
                    memory.content,
                    memory.filePath?.path(percentEncoded: false) ?? "",
                    ownership.rawValue,
                    memory.storage.rawValue,
                    memory.pinned ? 1 : 0,
                    iso.string(from: memory.createdAt),
                    iso.string(from: memory.updatedAt),
                ]
            )
        }
    }

    func deleteMemory(id: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM memories WHERE id = ?", arguments: [id])
        }
    }

    /// Count all memories in the DB.
    func memoryCount(agentName: String? = nil) throws -> Int {
        try dbQueue.read { db in
            if let agentName {
                return try Int.fetchOne(db, sql: "SELECT count(*) FROM memories WHERE agent_name = ?", arguments: [agentName]) ?? 0
            }
            return try Int.fetchOne(db, sql: "SELECT count(*) FROM memories") ?? 0
        }
    }

    // MARK: - FTS5 Search

    struct SearchResult: Sendable {
        let id: String
        let agentName: String
        let name: String
        let description: String?
        let type: String
        let content: String
        let ownership: String
        let score: Double
        let matchLayer: String
    }

    /// Search memories using FTS5 BM25 scoring.
    func searchMemories(query: String, agentName: String, scope: String = "self", limit: Int = 10) throws -> [SearchResult] {
        guard !query.isEmpty else { return [] }

        // Escape FTS5 special characters and wrap tokens in quotes for safety
        let sanitized = sanitizeFTS5Query(query)
        guard !sanitized.isEmpty else { return [] }

        return try dbQueue.read { db in
            let scopeFilter: String
            switch scope {
            case "global":
                scopeFilter = "AND m.ownership = 'global'"
            case "all":
                scopeFilter = ""
            default: // "self"
                scopeFilter = "AND (m.agent_name = ? OR m.ownership = 'global')"
            }

            let sql = """
                SELECT m.id, m.agent_name, m.name, m.description, m.type, m.content, m.ownership,
                       bm25(memories_fts) AS score
                FROM memories_fts f
                JOIN memories m ON m.rowid = f.rowid
                WHERE memories_fts MATCH ?
                \(scopeFilter)
                ORDER BY score
                LIMIT ?
                """

            var args: [DatabaseValueConvertible] = [sanitized]
            if scope == "self" {
                args.append(agentName)
            }
            args.append(limit)

            return try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args)).map { row in
                SearchResult(
                    id: row["id"],
                    agentName: row["agent_name"],
                    name: row["name"],
                    description: row["description"],
                    type: row["type"],
                    content: row["content"],
                    ownership: row["ownership"],
                    score: abs(row["score"] as Double),  // BM25 returns negative values; lower is better
                    matchLayer: "fts5"
                )
            }
        }
    }

    /// Sanitize a query string for FTS5 MATCH.
    private func sanitizeFTS5Query(_ query: String) -> String {
        // Split into tokens, remove empty, wrap each in quotes
        query
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .map { token in
                let cleaned = token.replacingOccurrences(of: "\"", with: "")
                return "\"\(cleaned)\""
            }
            .joined(separator: " OR ")
    }

    // MARK: - Embedding

    /// Update the embedding for a memory.
    func updateEmbedding(id: String, embedding: [Float]) throws {
        let data = EmbeddingService.serialize(embedding)
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE memories SET embedding = ? WHERE id = ?", arguments: [data, id])
        }
    }

    /// Fetch all memory IDs that have no embedding (for batch generation).
    func memoriesWithoutEmbedding(limit: Int = 100) throws -> [String] {
        try dbQueue.read { db in
            try String.fetchAll(db, sql: "SELECT id FROM memories WHERE embedding IS NULL LIMIT ?", arguments: [limit])
        }
    }

    /// Fetch memory content for embedding generation.
    func memoryContent(id: String) throws -> String? {
        try dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT name || ' ' || COALESCE(description, '') || ' ' || content FROM memories WHERE id = ?", arguments: [id])
        }
    }

    /// Search memories using embedding cosine similarity.
    /// Loads all embeddings matching scope, computes cosine similarity in-memory.
    /// Efficient for < 10k memories (typical usage).
    func searchMemoriesByEmbedding(queryEmbedding: [Float], agentName: String, scope: String = "self", limit: Int = 10) throws -> [SearchResult] {
        try dbQueue.read { db in
            let scopeFilter: String
            switch scope {
            case "global":
                scopeFilter = "AND m.ownership = 'global'"
            case "all":
                scopeFilter = ""
            default:
                scopeFilter = "AND (m.agent_name = ? OR m.ownership = 'global')"
            }

            let sql = """
                SELECT m.id, m.agent_name, m.name, m.description, m.type, m.content, m.ownership, m.embedding
                FROM memories m
                WHERE m.embedding IS NOT NULL
                \(scopeFilter)
                """

            var args: [DatabaseValueConvertible] = []
            if scope == "self" { args.append(agentName) }

            let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))

            var results: [(SearchResult, Float)] = []
            for row in rows {
                guard let embeddingData = row["embedding"] as? Data,
                      let embedding = EmbeddingService.deserialize(embeddingData) else { continue }

                let similarity = EmbeddingService.cosineSimilarity(queryEmbedding, embedding)

                let result = SearchResult(
                    id: row["id"],
                    agentName: row["agent_name"],
                    name: row["name"],
                    description: row["description"],
                    type: row["type"],
                    content: row["content"],
                    ownership: row["ownership"],
                    score: Double(similarity),
                    matchLayer: "embedding"
                )
                results.append((result, similarity))
            }

            // Sort by similarity (descending) and take top-K
            results.sort { $0.1 > $1.1 }
            return Array(results.prefix(limit).map(\.0))
        }
    }

    /// Hybrid search: combine FTS5 BM25 and embedding cosine similarity.
    /// α controls the blend: α=1.0 means pure FTS5, α=0.0 means pure embedding.
    func hybridSearch(
        query: String,
        queryEmbedding: [Float]?,
        agentName: String,
        scope: String = "self",
        limit: Int = 10,
        alpha: Double = 0.5
    ) throws -> [SearchResult] {
        // FTS5 search
        let ftsResults = try searchMemories(query: query, agentName: agentName, scope: scope, limit: limit * 2)

        // Embedding search (if available)
        let embResults: [SearchResult]
        if let queryEmbedding {
            embResults = try searchMemoriesByEmbedding(queryEmbedding: queryEmbedding, agentName: agentName, scope: scope, limit: limit * 2)
        } else {
            embResults = []
        }

        // If only one source, return it directly
        if embResults.isEmpty { return Array(ftsResults.prefix(limit)) }
        if ftsResults.isEmpty { return Array(embResults.prefix(limit)) }

        // Normalize scores to [0, 1] range
        let maxFts = ftsResults.map(\.score).max() ?? 1
        let maxEmb = embResults.map(\.score).max() ?? 1

        // Merge by ID
        var merged: [String: (fts: Double, emb: Double, result: SearchResult)] = [:]

        for r in ftsResults {
            let normalizedFts = maxFts > 0 ? r.score / maxFts : 0
            merged[r.id] = (fts: normalizedFts, emb: 0, result: r)
        }

        for r in embResults {
            let normalizedEmb = maxEmb > 0 ? r.score / maxEmb : 0
            if var existing = merged[r.id] {
                existing.emb = normalizedEmb
                merged[r.id] = existing
            } else {
                merged[r.id] = (fts: 0, emb: normalizedEmb, result: r)
            }
        }

        // Compute hybrid score
        var hybridResults: [(SearchResult, Double)] = merged.values.map { entry in
            let hybridScore = alpha * entry.fts + (1 - alpha) * entry.emb
            let result = SearchResult(
                id: entry.result.id,
                agentName: entry.result.agentName,
                name: entry.result.name,
                description: entry.result.description,
                type: entry.result.type,
                content: entry.result.content,
                ownership: entry.result.ownership,
                score: hybridScore,
                matchLayer: entry.fts > 0 && entry.emb > 0 ? "hybrid" : (entry.fts > 0 ? "fts5" : "embedding")
            )
            return (result, hybridScore)
        }

        hybridResults.sort { $0.1 > $1.1 }
        return Array(hybridResults.prefix(limit).map(\.0))
    }

    // MARK: - Transcript

    func upsertTranscript(id: String, sessionId: String, agentName: String?, content: String) throws {
        let iso = ISO8601DateFormatter()
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO transcripts (id, session_id, agent_name, content, created_at)
                    VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET content = excluded.content
                    """,
                arguments: [id, sessionId, agentName, content, iso.string(from: Date())]
            )
        }
    }

    /// Search transcripts using FTS5.
    func searchTranscripts(query: String, agentName: String? = nil, limit: Int = 5) throws -> [SearchResult] {
        guard !query.isEmpty else { return [] }
        let sanitized = sanitizeFTS5Query(query)
        guard !sanitized.isEmpty else { return [] }

        return try dbQueue.read { db in
            let filterSQL = agentName != nil ? "AND t.agent_name = ?" : ""
            let sql = """
                SELECT t.id, t.agent_name, t.session_id, t.content,
                       bm25(transcripts_fts) AS score
                FROM transcripts_fts f
                JOIN transcripts t ON t.rowid = f.rowid
                WHERE transcripts_fts MATCH ?
                \(filterSQL)
                ORDER BY score
                LIMIT ?
                """

            var args: [DatabaseValueConvertible] = [sanitized]
            if let agentName { args.append(agentName) }
            args.append(limit)

            return try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args)).map { row in
                SearchResult(
                    id: row["id"],
                    agentName: (row["agent_name"] as String?) ?? "_transcript",
                    name: row["session_id"],
                    description: nil,
                    type: "transcript",
                    content: row["content"],
                    ownership: "agent",
                    score: abs(row["score"] as Double),
                    matchLayer: "fts5"
                )
            }
        }
    }

    // MARK: - Recall Logs

    func logRecall(id: String, sessionId: String, agentName: String, query: String, scope: String, resultCount: Int, resultsJSON: String) throws {
        let iso = ISO8601DateFormatter()
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO recall_logs (id, session_id, agent_name, query, scope, result_count, results_json, created_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [id, sessionId, agentName, query, scope, resultCount, resultsJSON, iso.string(from: Date())]
            )
        }
    }

    /// Delete recall logs older than the given number of days.
    func cleanupOldRecallLogs(olderThanDays: Int = 30) throws {
        let iso = ISO8601DateFormatter()
        let cutoff = Calendar.current.date(byAdding: .day, value: -olderThanDays, to: Date()) ?? Date()
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM recall_logs WHERE created_at < ?", arguments: [iso.string(from: cutoff)])
        }
    }

    // MARK: - Sync

    /// Get memory IDs and their updated_at values for a specific agent (for diff sync).
    func memoryStamps(agentName: String) throws -> [String: String] {
        try dbQueue.read { db in
            var result: [String: String] = [:]
            let rows = try Row.fetchAll(db, sql: "SELECT id, updated_at FROM memories WHERE agent_name = ?", arguments: [agentName])
            for row in rows {
                result[row["id"] as String] = row["updated_at"] as String
            }
            return result
        }
    }

    /// Delete memories not in the given set of IDs (for cleanup during sync).
    func deleteMemoriesNotIn(ids: Set<String>) throws {
        guard !ids.isEmpty else {
            try dbQueue.write { db in
                try db.execute(sql: "DELETE FROM memories")
            }
            return
        }
        try dbQueue.write { db in
            let placeholders = ids.map { _ in "?" }.joined(separator: ",")
            try db.execute(
                sql: "DELETE FROM memories WHERE id NOT IN (\(placeholders))",
                arguments: StatementArguments(Array(ids))
            )
        }
    }

    /// The file path of this database.
    var path: String {
        dbQueue.path
    }
}
