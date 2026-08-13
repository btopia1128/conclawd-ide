import Foundation

struct Skill: Identifiable, Hashable {
    var id: UUID = UUID()
    var name: String = ""
    var description: String = ""
    var content: String = ""
    /// Sort order for sidebar display (lower values first).
    var sortOrder: Int = 0

    // ── Frontmatter fields (written to SKILL.md) ──

    /// Prevent Claude from auto-invoking this skill (YAML: disable-model-invocation).
    var disableModelInvocation: Bool = false

    /// Show in the / slash command menu (YAML: user-invocable).
    var userInvocable: Bool = true

    /// Tools allowed without per-request approval (YAML: allowed-tools).
    var allowedTools: [String] = []

    /// Override model for this skill (YAML: model). nil = inherit from session.
    var model: AgentModel? = nil

    /// Reasoning effort level (YAML: effort). nil = inherit from session.
    var effort: SkillEffort? = nil

    /// Execution context (YAML: context). inline = normal, fork = isolated subagent.
    var context: SkillContext = .inline

    /// Subagent type when context=fork (YAML: agent). e.g. "Explore", "Plan".
    var agentType: String? = nil

    /// Argument hint shown in autocomplete (YAML: argument-hint).
    var argumentHint: String? = nil

    /// Unknown frontmatter keys preserved for round-trip fidelity.
    var extraFrontmatter: [(key: String, rawValue: String)] = []

    // App-level metadata (not written to SKILL.md)
    var scope: AgentScope = .project
    var filePath: URL?
    var sourceProjectName: String?

    // Hashable conformance
    static func == (lhs: Skill, rhs: Skill) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    /// Content-based comparison (ignores id/metadata) used for dirty-checking.
    func contentEquals(_ other: Skill) -> Bool {
        name == other.name &&
        description == other.description &&
        content == other.content &&
        sortOrder == other.sortOrder &&
        disableModelInvocation == other.disableModelInvocation &&
        userInvocable == other.userInvocable &&
        allowedTools == other.allowedTools &&
        model == other.model &&
        effort == other.effort &&
        context == other.context &&
        agentType == other.agentType &&
        argumentHint == other.argumentHint
    }

    /// The skill's directory (parent of SKILL.md).
    var skillDirectory: URL? {
        filePath?.deletingLastPathComponent()
    }

    /// All bundled files in the skill directory (excluding SKILL.md itself).
    /// Includes files from references/, scripts/, assets/, and any other subdirectories.
    var bundledFiles: [URL] {
        guard let skillDir = skillDirectory else { return [] }
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: skillDir, includingPropertiesForKeys: [.isRegularFileKey],
                                              options: [.skipsHiddenFiles]) else { return [] }
        var files: [URL] = []
        for case let url as URL in enumerator {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            if url.lastPathComponent == "SKILL.md" { continue }
            files.append(url)
        }
        return files.sorted { $0.path(percentEncoded: false) < $1.path(percentEncoded: false) }
    }
}
