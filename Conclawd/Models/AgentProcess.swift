import Foundation

@Observable
final class AgentProcess: Identifiable {
    let id: UUID = UUID()
    let agentId: UUID
    var pid: pid_t = 0
    var status: AgentProcessStatus = .running
    var startedAt: Date = Date()
    var stoppedAt: Date?
    /// The CLI session ID extracted from terminal output (used for resume/fork).
    var claudeResumeId: String?
    /// The CLI provider used for this session.
    var cliProviderType: CLIProviderType = .claude
    /// Whether this session has output the user hasn't seen yet.
    var hasUnreadOutput: Bool = false

    init(agentId: UUID) {
        self.agentId = agentId
    }
}
