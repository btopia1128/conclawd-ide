import Foundation

/// The type of resource being created in an AI-assisted session.
enum CreationType {
    case agent
    case skill
}

/// Represents an active AI-assisted creation session.
struct CreationSession: Identifiable {
    let id: UUID = UUID()
    let startedAt: Date = Date()
    let targetScope: AgentScope
    let targetDirectory: URL
    let creationType: CreationType

    init(targetScope: AgentScope, targetDirectory: URL, creationType: CreationType = .agent) {
        self.targetScope = targetScope
        self.targetDirectory = targetDirectory
        self.creationType = creationType
    }

    var isSkillCreation: Bool { creationType == .skill }
}
