import Foundation

/// Shell types available for standalone terminal sessions.
enum ShellType: String, Codable, CaseIterable {
    case zsh = "/bin/zsh"
    case bash = "/bin/bash"

    var displayName: String {
        switch self {
        case .zsh: return "zsh"
        case .bash: return "bash"
        }
    }
}

/// Represents a running terminal session for an agent.
/// One agent can have multiple concurrent sessions.
struct AgentSession: Identifiable {
    let id: UUID
    let agentId: UUID
    let agentName: String
    /// User-defined custom name for this session tab.
    var customName: String?
    /// Stable identifier for the agent file (used to survive agent ID changes across reloads).
    let agentFilePath: String?
    let startedAt: Date
    let isCreationSession: Bool
    let isScheduledSession: Bool
    let scheduleId: UUID?
    /// Working directory for standalone sessions (not tied to an agent).
    let workingDirectory: URL?
    /// Display mode: terminal (PTY) or chat (stream-json).
    let displayMode: SessionDisplayMode
    /// Shell type for standalone shell sessions (nil for agent/Claude sessions).
    let shellType: ShellType?
    /// The CLI provider used for this session.
    let cliProviderType: CLIProviderType
    /// Which main pane currently owns this session tab. Defaults to primary so
    /// existing call sites that don't specify a pane stay backward compatible.
    var paneId: PaneID = .primary

    /// Whether this is a standalone shell session (not running Claude CLI).
    var isShellSession: Bool { shellType != nil }

    init(id: UUID = UUID(), agentId: UUID, agentName: String, customName: String? = nil, agentFilePath: String? = nil, isCreationSession: Bool = false, isScheduledSession: Bool = false, scheduleId: UUID? = nil, workingDirectory: URL? = nil, displayMode: SessionDisplayMode = .terminal, startedAt: Date = Date(), shellType: ShellType? = nil, cliProviderType: CLIProviderType = .claude, paneId: PaneID = .primary) {
        self.id = id
        self.agentId = agentId
        self.agentName = agentName
        self.customName = customName
        self.agentFilePath = agentFilePath
        self.startedAt = startedAt
        self.isCreationSession = isCreationSession
        self.isScheduledSession = isScheduledSession
        self.scheduleId = scheduleId
        self.workingDirectory = workingDirectory
        self.displayMode = displayMode
        self.shellType = shellType
        self.cliProviderType = cliProviderType
        self.paneId = paneId
    }
}
