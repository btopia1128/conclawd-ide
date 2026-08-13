import Foundation

struct Project: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    var directoryPath: URL
    var lastOpenedAt: Date = Date()

    /// Path to the project's agent definitions directory.
    var agentsDirectory: URL {
        directoryPath.appending(path: ".claude/agents")
    }

    /// Path to the project's skill definitions directory (Claude Code).
    var skillsDirectory: URL {
        directoryPath.appending(path: ".claude/skills")
    }

    /// Path to the project's Codex skill definitions directory.
    var codexSkillsDirectory: URL {
        directoryPath.appending(path: ".agents/skills")
    }
}
