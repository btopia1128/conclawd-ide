import Foundation
import Yams

/// Reads and writes Claude Code skill definition files (.claude/skills/{name}/SKILL.md).
final class SkillConfigService {

    /// Known frontmatter keys that are parsed into Skill model fields.
    private static let knownKeys: Set<String> = [
        "name", "description", "sortOrder",
        "disable-model-invocation", "user-invocable",
        "allowed-tools", "model", "effort",
        "context", "agent", "argument-hint", "hooks"
    ]

    /// Skill directory paths for Claude Code and Codex CLI.
    static let claudeSkillsPaths = [".claude/skills"]
    static let codexSkillsPaths = [".agents/skills"]
    static let allSkillsPaths = claudeSkillsPaths + codexSkillsPaths

    // MARK: - Load Skills

    /// Load all skills from a project's skill directories (.claude/skills/ and .agents/skills/).
    func loadProjectSkills(projectDir: URL) -> [Skill] {
        var skills: [Skill] = []
        var seenNames = Set<String>()
        for subpath in Self.allSkillsPaths {
            let skillsDir = projectDir.appending(path: subpath)
            for skill in loadSkills(from: skillsDir, scope: .project) {
                // Deduplicate by name (same SKILL.md symlinked to both paths)
                if seenNames.insert(skill.name).inserted {
                    skills.append(skill)
                }
            }
        }
        return skills
    }

    /// Load all user-scope skills from ~/.claude/skills/ and ~/.codex/skills/ / ~/.agents/skills/.
    func loadUserSkills() -> [Skill] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var skills: [Skill] = []
        var seenNames = Set<String>()
        let userPaths = [
            home.appending(path: ".claude/skills"),
            home.appending(path: ".codex/skills"),
            home.appending(path: ".agents/skills"),
        ]
        for skillsDir in userPaths {
            for skill in loadSkills(from: skillsDir, scope: .user) {
                if seenNames.insert(skill.name).inserted {
                    skills.append(skill)
                }
            }
        }
        return skills
    }

    /// Load skills from a directory. Each subdirectory containing SKILL.md is one skill.
    private func loadSkills(from skillsBaseDir: URL, scope: AgentScope) -> [Skill] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: skillsBaseDir.path(percentEncoded: false)) else { return [] }

        do {
            let entries = try fm.contentsOfDirectory(at: skillsBaseDir, includingPropertiesForKeys: [.isDirectoryKey])
            return entries
                .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
                .compactMap { dir in
                    let skillFile = dir.appending(path: "SKILL.md")
                    guard fm.fileExists(atPath: skillFile.path(percentEncoded: false)) else { return nil }
                    return parseSkillFile(at: skillFile, scope: scope)
                }
        } catch {
            print("Failed to list skills directory: \(error)")
            return []
        }
    }

    // MARK: - Parse Skill File

    /// Parse a single SKILL.md file with YAML frontmatter.
    func parseSkillFile(at url: URL, scope: AgentScope) -> Skill? {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return parseSkillContent(content, fileURL: url, scope: scope)
    }

    /// Parse skill content string into a Skill model.
    func parseSkillContent(_ content: String, fileURL: URL? = nil, scope: AgentScope = .project) -> Skill? {
        let (frontmatter, body) = splitFrontmatter(content)
        guard let yaml = frontmatter else { return nil }

        do {
            guard let dict = try Yams.load(yaml: yaml) as? [String: Any] else { return nil }

            var skill = Skill()
            // Default name from directory name
            let dirName = fileURL?.deletingLastPathComponent().lastPathComponent
            skill.name = dict["name"] as? String ?? dirName ?? "unnamed"
            skill.description = dict["description"] as? String ?? ""
            skill.content = body.trimmingCharacters(in: .whitespacesAndNewlines)
            skill.scope = scope
            skill.filePath = fileURL

            // Sort order
            if let order = dict["sortOrder"] as? Int {
                skill.sortOrder = order
            }

            // disable-model-invocation (kebab-case)
            if let val = dict["disable-model-invocation"] as? Bool {
                skill.disableModelInvocation = val
            }

            // user-invocable (kebab-case)
            if let val = dict["user-invocable"] as? Bool {
                skill.userInvocable = val
            }

            // allowed-tools — comma-separated string or array
            if let str = dict["allowed-tools"] as? String {
                skill.allowedTools = parseToolsList(str)
            } else if let arr = dict["allowed-tools"] as? [String] {
                skill.allowedTools = arr
            }

            // model
            if let str = dict["model"] as? String {
                let parsed = AgentModel.from(str)
                skill.model = (parsed == .inherit) ? nil : parsed
            }

            // effort
            if let str = dict["effort"] as? String {
                skill.effort = SkillEffort(rawValue: str)
            }

            // context
            if let str = dict["context"] as? String {
                skill.context = SkillContext(rawValue: str) ?? .inline
            }

            // agent
            if let str = dict["agent"] as? String {
                skill.agentType = str
            }

            // argument-hint (kebab-case)
            if let str = dict["argument-hint"] as? String {
                skill.argumentHint = str
            }

            // Preserve unknown frontmatter keys for round-trip fidelity
            skill.extraFrontmatter = collectExtraFields(yaml: yaml, knownKeys: Self.knownKeys)

            return skill
        } catch {
            print("Failed to parse skill YAML frontmatter: \(error)")
            return nil
        }
    }

    // MARK: - Save Skill

    /// Save a skill to its SKILL.md file. Creates the skill directory if needed.
    /// Also creates symlinks in the alternate CLI path (.agents/skills/ ↔ .claude/skills/)
    /// so that both Claude Code and Codex CLI can discover the skill.
    /// When `syncToCodex` is true, also creates a symlink in ~/.codex/skills/.
    func saveSkill(_ skill: Skill, to baseDirectory: URL? = nil, syncToCodex: Bool = false) throws {
        let targetURL: URL
        if let filePath = skill.filePath {
            targetURL = filePath
        } else if let baseDir = baseDirectory {
            targetURL = baseDir.appending(path: "\(skill.name)/SKILL.md")
        } else {
            throw SkillConfigError.noFilePath
        }

        let content = serializeSkill(skill)

        // Ensure skill directory exists
        let parentDir = targetURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)

        try content.write(to: targetURL, atomically: true, encoding: .utf8)

        // Create symlink in the alternate CLI skills directory
        createAlternateSkillSymlink(skillDir: parentDir, skillName: skill.name)

        // Optionally sync to ~/.codex/skills/
        if syncToCodex {
            syncSkillToCodex(skillDir: parentDir, skillName: skill.name)
        }
    }

    // MARK: - Codex Sync

    /// Syncs a single skill directory to ~/.codex/skills/ via symlink.
    func syncSkillToCodex(skillDir: URL, skillName: String) {
        let fm = FileManager.default
        let codexSkillsDir = fm.homeDirectoryForCurrentUser.appending(path: ".codex/skills")
        let codexSkillDir = codexSkillsDir.appending(path: skillName)
        let codexPath = codexSkillDir.path(percentEncoded: false)
        let sourcePath = skillDir.path(percentEncoded: false)

        // Skip if already exists (symlink or real dir)
        guard !fm.fileExists(atPath: codexPath) else { return }

        // Don't link ~/.codex/skills/X → ~/.codex/skills/X
        guard !sourcePath.hasPrefix(codexSkillsDir.path(percentEncoded: false)) else { return }

        try? fm.createDirectory(at: codexSkillsDir, withIntermediateDirectories: true)
        try? fm.createSymbolicLink(atPath: codexPath, withDestinationPath: sourcePath)
    }

    /// Syncs all user-scope skills from ~/.claude/skills/ to ~/.codex/skills/.
    func syncAllSkillsToCodex() {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let claudeSkillsDir = home.appending(path: ".claude/skills")
        guard fm.fileExists(atPath: claudeSkillsDir.path(percentEncoded: false)) else { return }

        guard let entries = try? fm.contentsOfDirectory(
            at: claudeSkillsDir,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return }

        for dir in entries {
            guard (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            let skillFile = dir.appending(path: "SKILL.md")
            guard fm.fileExists(atPath: skillFile.path(percentEncoded: false)) else { continue }
            syncSkillToCodex(skillDir: dir, skillName: dir.lastPathComponent)
        }
    }

    /// Removes all Codex skill symlinks that point back to ~/.claude/skills/.
    func unsyncAllSkillsFromCodex() {
        let fm = FileManager.default
        let codexSkillsDir = fm.homeDirectoryForCurrentUser.appending(path: ".codex/skills")
        guard fm.fileExists(atPath: codexSkillsDir.path(percentEncoded: false)) else { return }

        guard let entries = try? fm.contentsOfDirectory(
            at: codexSkillsDir,
            includingPropertiesForKeys: []
        ) else { return }

        let claudeSkillsPath = fm.homeDirectoryForCurrentUser
            .appending(path: ".claude/skills").path(percentEncoded: false)

        for entry in entries {
            let path = entry.path(percentEncoded: false)
            guard let dest = try? fm.destinationOfSymbolicLink(atPath: path) else { continue }
            if dest.hasPrefix(claudeSkillsPath) {
                try? fm.removeItem(atPath: path)
            }
        }
    }

    /// Creates a symlink in the alternate CLI skills path so both Claude and Codex can find the skill.
    /// e.g., .claude/skills/commit/ → creates symlink at .agents/skills/commit/
    private func createAlternateSkillSymlink(skillDir: URL, skillName: String) {
        let fm = FileManager.default
        let skillDirPath = skillDir.path(percentEncoded: false)

        // Determine the project root and which path this skill is in
        // Skill paths: {root}/.claude/skills/{name}/ or {root}/.agents/skills/{name}/
        let claudeMarker = "/.claude/skills/"
        let codexMarker = "/.agents/skills/"

        let alternateDir: URL
        if skillDirPath.contains(claudeMarker) {
            // Source is .claude/skills/ → create symlink in .agents/skills/
            let root = skillDirPath.components(separatedBy: claudeMarker)[0]
            alternateDir = URL(filePath: root).appending(path: ".agents/skills/\(skillName)")
        } else if skillDirPath.contains(codexMarker) {
            // Source is .agents/skills/ → create symlink in .claude/skills/
            let root = skillDirPath.components(separatedBy: codexMarker)[0]
            alternateDir = URL(filePath: root).appending(path: ".claude/skills/\(skillName)")
        } else {
            return // Not in a recognized skill path
        }

        let alternatePath = alternateDir.path(percentEncoded: false)

        // Skip if the alternate already exists (could be a symlink or real dir)
        guard !fm.fileExists(atPath: alternatePath) else { return }

        // Create parent directory if needed
        let parentDir = alternateDir.deletingLastPathComponent()
        try? fm.createDirectory(at: parentDir, withIntermediateDirectories: true)

        // Create symlink pointing to the source skill directory
        try? fm.createSymbolicLink(atPath: alternatePath, withDestinationPath: skillDirPath)
    }

    /// Serialize a Skill to frontmatter + markdown content.
    func serializeSkill(_ skill: Skill) -> String {
        var lines: [String] = []
        lines.append("---")
        lines.append("name: \(skill.name)")

        if !skill.description.isEmpty {
            lines.append("description: \(yamlEscapeString(skill.description))")
        }

        // disable-model-invocation (only write when true, default is false)
        if skill.disableModelInvocation {
            lines.append("disable-model-invocation: true")
        }

        // user-invocable (only write when false, default is true)
        if !skill.userInvocable {
            lines.append("user-invocable: false")
        }

        // allowed-tools
        if !skill.allowedTools.isEmpty {
            lines.append("allowed-tools: \(skill.allowedTools.joined(separator: ", "))")
        }

        // model
        if let model = skill.model {
            lines.append("model: \(model.shortName)")
        }

        // effort
        if let effort = skill.effort {
            lines.append("effort: \(effort.rawValue)")
        }

        // context (only write when fork, default is inline)
        if skill.context != .inline {
            lines.append("context: \(skill.context.rawValue)")
        }

        // agent (only meaningful with context=fork)
        if let agentType = skill.agentType, !agentType.isEmpty {
            lines.append("agent: \(agentType)")
        }

        // argument-hint
        if let hint = skill.argumentHint, !hint.isEmpty {
            lines.append("argument-hint: \(yamlEscapeString(hint))")
        }

        if skill.sortOrder != 0 {
            lines.append("sortOrder: \(skill.sortOrder)")
        }

        // Preserve unknown frontmatter keys
        for (key, rawValue) in skill.extraFrontmatter {
            lines.append("\(key): \(rawValue)")
        }

        lines.append("---")
        lines.append("")

        if !skill.content.isEmpty {
            lines.append(skill.content)
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Helpers

    /// Split content into YAML frontmatter and markdown body.
    func splitFrontmatter(_ content: String) -> (frontmatter: String?, body: String) {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("---") else {
            return (nil, content)
        }

        let afterFirstDelimiter = trimmed.dropFirst(3)
        guard let endRange = afterFirstDelimiter.range(of: "\n---") else {
            return (nil, content)
        }

        let yaml = String(afterFirstDelimiter[afterFirstDelimiter.startIndex..<endRange.lowerBound])
        let body = String(afterFirstDelimiter[endRange.upperBound...])

        return (yaml.trimmingCharacters(in: .whitespacesAndNewlines),
                body.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Parse a comma-separated tools string, respecting parentheses (e.g., "Bash(npm *)").
    private func parseToolsList(_ input: String) -> [String] {
        var tools: [String] = []
        var current = ""
        var depth = 0

        for char in input {
            if char == "(" {
                depth += 1
                current.append(char)
            } else if char == ")" {
                depth -= 1
                current.append(char)
            } else if char == "," && depth == 0 {
                let trimmed = current.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty {
                    tools.append(trimmed)
                }
                current = ""
            } else {
                current.append(char)
            }
        }

        let trimmed = current.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            tools.append(trimmed)
        }

        return tools
    }

    /// Collect unknown frontmatter keys from the raw YAML text.
    /// Only top-level `key: value` lines are considered. Multi-line values are grouped.
    private func collectExtraFields(yaml: String, knownKeys: Set<String>) -> [(key: String, rawValue: String)] {
        var extras: [(String, String)] = []
        let lines = yaml.components(separatedBy: "\n")
        var i = 0
        while i < lines.count {
            let line = lines[i]
            // Detect top-level key: value lines (no leading whitespace)
            if let colonRange = line.range(of: ":"),
               !line.hasPrefix(" "), !line.hasPrefix("\t") {
                let key = String(line[line.startIndex..<colonRange.lowerBound]).trimmingCharacters(in: .whitespaces)
                if !key.isEmpty && !knownKeys.contains(key) {
                    let value = String(line[colonRange.upperBound...]).trimmingCharacters(in: .whitespaces)
                    // Collect multi-line values (indented continuation lines)
                    var fullValue = value
                    while i + 1 < lines.count && (lines[i + 1].hasPrefix(" ") || lines[i + 1].hasPrefix("\t")) {
                        i += 1
                        fullValue += "\n" + lines[i]
                    }
                    extras.append((key, fullValue))
                }
            }
            i += 1
        }
        return extras
    }

    /// Escape a string for YAML output if it contains special characters.
    private func yamlEscapeString(_ value: String) -> String {
        if value.contains(":") || value.contains("#") || value.contains("\"") ||
           value.hasPrefix(" ") || value.hasSuffix(" ") {
            let escaped = value.replacingOccurrences(of: "\"", with: "\\\"")
            return "\"\(escaped)\""
        }
        return value
    }
}

// MARK: - Errors

enum SkillConfigError: Error, LocalizedError {
    case noFilePath

    var errorDescription: String? {
        switch self {
        case .noFilePath:
            return "No file path specified for saving skill."
        }
    }
}
