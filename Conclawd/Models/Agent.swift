import Foundation

struct Agent: Identifiable, Hashable, @unchecked Sendable {
    var id: UUID = UUID()
    var name: String = ""
    var description: String = ""
    var model: AgentModel = .inherit
    var color: AgentColor = .blue
    var tools: [String] = []
    var disallowedTools: [String] = []
    var permissionMode: PermissionMode = .default
    var maxTurns: Int?
    var mcpServers: [String] = []
    var hooks: [String: Any]?
    var systemPrompt: String = ""
    var memoryEnabled: Bool = true
    /// Layer 1: LLM-based memory extraction from session transcripts → .md files
    var memoryExtractionEnabled: Bool = true
    /// Layer 2: Sync memories & transcripts to SQLite FTS5 for full-text search
    var memoryDbSyncEnabled: Bool = true
    /// Layer 3: Generate vector embeddings for semantic search
    var memoryEmbeddingEnabled: Bool = true
    var memoryStorage: MemoryStorage = .shared
    var memoryOwnership: MemoryOwnership = .agent
    /// Maximum number of memories injected into the system prompt (nil = default 20).
    var memoryLimit: Int?
    /// Sort order for sidebar display (lower values first).
    var sortOrder: Int = 0
    /// Raw CLI flags appended to the claude command (escape hatch for new CLI features).
    var customFlags: String = ""
    /// Default CLI provider for this agent (claude or codex).
    var defaultProvider: CLIProviderType = .claude
    /// When set, this raw command string is executed as-is instead of building from agent settings.
    var rawCommand: String?

    /// The effective memory injection limit.
    var effectiveMemoryLimit: Int { memoryLimit ?? 20 }

    /// A reload-stable identity (filePath or name) — unlike `id` (UUID) which changes on every reloadAgents().
    var stableIdentity: String {
        filePath?.path(percentEncoded: false) ?? name
    }

    // App-level metadata (not written to .md file)
    var scope: AgentScope = .project
    var filePath: URL?
    /// Working directory from the .md frontmatter (may be relative or absolute).
    /// Use `effectiveDirectory` for the resolved value.
    var currentDirectory: URL?
    /// App-local working directory override (stored in UserDefaults, not in .md).
    var localDirectory: URL?
    var sourceProjectName: String?

    /// The resolved working directory: localDirectory > currentDirectory > projectRoot.
    var effectiveDirectory: URL? {
        localDirectory ?? currentDirectory ?? projectRootDirectory
    }

    // Hashable conformance (exclude hooks since [String: Any] isn't Hashable)
    static func == (lhs: Agent, rhs: Agent) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    /// Infer the project root from the agent file path (.claude/agents/name.md → project root).
    var projectRootDirectory: URL? {
        // filePath is like /path/to/project/.claude/agents/name.md
        guard let filePath else { return nil }
        let parent = filePath
            .deletingLastPathComponent()  // .claude/agents/
            .deletingLastPathComponent()  // .claude/
            .deletingLastPathComponent()  // project root
        return parent
    }

    /// Memory directory for the given storage type.
    func memoryDirectory(for storage: MemoryStorage) -> URL? {
        guard let filePath else { return nil }
        let nameWithoutExt = filePath.deletingPathExtension().lastPathComponent

        if storage == .private && scope == .project {
            let home = FileManager.default.homeDirectoryForCurrentUser
            let projectSlug = projectRootDirectory?
                .path(percentEncoded: false)
                .replacingOccurrences(of: "/", with: "-")
                .trimmingCharacters(in: CharacterSet(charactersIn: "-")) ?? "unknown"
            return home
                .appending(path: ".claude/agent-memory")
                .appending(path: projectSlug)
                .appending(path: "\(nameWithoutExt).memory")
        }

        // Shared, or user-scope agents (already local)
        return filePath.deletingLastPathComponent()
            .appending(path: "\(nameWithoutExt).memory")
    }

    /// The default memory directory based on the agent's current storage setting.
    var memoryDirectory: URL? {
        memoryDirectory(for: memoryStorage)
    }

    /// All memory directories to load from (both shared and private if they differ).
    var allMemoryDirectories: [(storage: MemoryStorage, url: URL)] {
        var dirs: [(MemoryStorage, URL)] = []
        if let shared = memoryDirectory(for: .shared) {
            dirs.append((.shared, shared))
        }
        if let priv = memoryDirectory(for: .private),
           priv != memoryDirectory(for: .shared) {
            dirs.append((.private, priv))
        }
        return dirs
    }

    // MARK: - Global Memory Directories

    /// Global memory directory for the given storage type.
    /// Global memories are shared across all agents.
    static func globalMemoryDirectory(for storage: MemoryStorage, projectRoot: URL?) -> URL? {
        switch storage {
        case .shared:
            return projectRoot?.appending(path: ".claude/memory")
        case .private:
            let home = FileManager.default.homeDirectoryForCurrentUser
            return home.appending(path: ".claude/memory")
        }
    }

    /// All memory directories including agent-specific and global.
    var allMemoryDirectoriesIncludingGlobal: [(storage: MemoryStorage, ownership: MemoryOwnership, url: URL)] {
        var dirs: [(MemoryStorage, MemoryOwnership, URL)] = []

        // Agent-specific directories
        for (storage, url) in allMemoryDirectories {
            dirs.append((storage, .agent, url))
        }

        // Global directories
        if let shared = Agent.globalMemoryDirectory(for: .shared, projectRoot: projectRootDirectory) {
            dirs.append((.shared, .global, shared))
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let privateGlobal = home.appending(path: ".claude/memory")
        if let sharedGlobal = Agent.globalMemoryDirectory(for: .shared, projectRoot: projectRootDirectory),
           privateGlobal.path(percentEncoded: false) != sharedGlobal.path(percentEncoded: false) {
            dirs.append((.private, .global, privateGlobal))
        }

        return dirs
    }

    /// Content-based comparison (ignores id/hooks/metadata) used for dirty-checking.
    func contentEquals(_ other: Agent) -> Bool {
        name == other.name &&
        description == other.description &&
        model == other.model &&
        color == other.color &&
        tools == other.tools &&
        disallowedTools == other.disallowedTools &&
        permissionMode == other.permissionMode &&
        maxTurns == other.maxTurns &&
        mcpServers == other.mcpServers &&
        systemPrompt == other.systemPrompt &&
        memoryEnabled == other.memoryEnabled &&
        memoryExtractionEnabled == other.memoryExtractionEnabled &&
        memoryDbSyncEnabled == other.memoryDbSyncEnabled &&
        memoryEmbeddingEnabled == other.memoryEmbeddingEnabled &&
        memoryStorage == other.memoryStorage &&
        memoryOwnership == other.memoryOwnership &&
        memoryLimit == other.memoryLimit &&
        sortOrder == other.sortOrder &&
        customFlags == other.customFlags &&
        defaultProvider == other.defaultProvider &&
        localDirectory == other.localDirectory
    }

    /// Extract sub-agent names from the tools array.
    /// Parses entries like "Agent(reviewer, tester)" into ["reviewer", "tester"].
    var subAgentNames: [String] {
        var result: [String] = []
        for tool in tools {
            guard tool.hasPrefix("Agent(") && tool.hasSuffix(")") else { continue }
            let inner = String(tool.dropFirst(6).dropLast(1))
            let names = inner.split(separator: ",").map { String($0).trimmingCharacters(in: CharacterSet.whitespaces) }
            result.append(contentsOf: names)
        }
        return result
    }
}
