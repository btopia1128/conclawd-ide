import Foundation
import Yams

/// Reads and writes Claude Code agent definition files (.claude/agents/*.md).
final class AgentConfigService {

    // MARK: - Load Agents

    /// Load all agents from a project's .claude/agents/ directory.
    func loadProjectAgents(projectDir: URL) -> [Agent] {
        let agentsDir = projectDir.appending(path: ".claude/agents")
        return loadAgents(from: agentsDir, scope: .project)
    }

    /// Load all user-scope agents from ~/.claude/agents/.
    func loadUserAgents() -> [Agent] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let agentsDir = home.appending(path: ".claude/agents")
        return loadAgents(from: agentsDir, scope: .user)
    }

    /// Load project agents with parse error tracking.
    func loadProjectAgentsWithErrors(projectDir: URL) -> (agents: [Agent], errors: [AgentParseError]) {
        let agentsDir = projectDir.appending(path: ".claude/agents")
        return loadAgentsWithErrors(from: agentsDir, scope: .project)
    }

    /// Load user agents with parse error tracking.
    func loadUserAgentsWithErrors() -> (agents: [Agent], errors: [AgentParseError]) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let agentsDir = home.appending(path: ".claude/agents")
        return loadAgentsWithErrors(from: agentsDir, scope: .user)
    }

    /// Load agents from a directory, returning both parsed agents and errors for unparseable files.
    private func loadAgentsWithErrors(from directory: URL, scope: AgentScope) -> (agents: [Agent], errors: [AgentParseError]) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory.path(percentEncoded: false)) else { return ([], []) }

        do {
            let files = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "md" }

            var agents: [Agent] = []
            var errors: [AgentParseError] = []

            for url in files {
                if let agent = parseAgentFile(at: url, scope: scope) {
                    agents.append(agent)
                } else {
                    errors.append(AgentParseError(
                        fileName: url.lastPathComponent,
                        filePath: url,
                        error: "Failed to parse YAML frontmatter"
                    ))
                }
            }

            return (agents, errors)
        } catch {
            print("Failed to list agents directory: \(error)")
            return ([], [])
        }
    }

    /// Load agents from a directory.
    private func loadAgents(from directory: URL, scope: AgentScope) -> [Agent] {
        loadAgentsWithErrors(from: directory, scope: scope).agents
    }

    // MARK: - Parse Agent File

    /// Parse a single agent .md file with YAML frontmatter.
    func parseAgentFile(at url: URL, scope: AgentScope) -> Agent? {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return parseAgentContent(content, fileURL: url, scope: scope)
    }

    /// Parse agent content string into an Agent model.
    func parseAgentContent(_ content: String, fileURL: URL? = nil, scope: AgentScope = .project) -> Agent? {
        let (frontmatter, body) = splitFrontmatter(content)
        guard let yaml = frontmatter else { return nil }

        do {
            guard let dict = try Yams.load(yaml: yaml) as? [String: Any] else { return nil }

            var agent = Agent()
            agent.name = dict["name"] as? String ?? fileURL?.deletingPathExtension().lastPathComponent ?? "unnamed"
            agent.description = dict["description"] as? String ?? ""
            agent.systemPrompt = body.trimmingCharacters(in: .whitespacesAndNewlines)
            agent.scope = scope
            agent.filePath = fileURL

            // Model
            if let modelStr = dict["model"] as? String {
                agent.model = AgentModel.from(modelStr)
            }

            // Color
            if let colorStr = dict["color"] as? String,
               let color = AgentColor(rawValue: colorStr) {
                agent.color = color
            }

            // Tools
            if let toolsStr = dict["tools"] as? String {
                agent.tools = parseToolsList(toolsStr)
            } else if let toolsArr = dict["tools"] as? [String] {
                agent.tools = toolsArr
            }

            // Disallowed tools
            if let dtStr = dict["disallowedTools"] as? String {
                agent.disallowedTools = parseToolsList(dtStr)
            } else if let dtArr = dict["disallowedTools"] as? [String] {
                agent.disallowedTools = dtArr
            }

            // Permission mode
            if let pmStr = dict["permissionMode"] as? String,
               let pm = PermissionMode(rawValue: pmStr) {
                agent.permissionMode = pm
            }

            // Max turns
            agent.maxTurns = dict["maxTurns"] as? Int

            // MCP Servers
            if let mcpArr = dict["mcpServers"] as? [String] {
                agent.mcpServers = mcpArr
            }

            // Hooks (store as raw dictionary)
            if let hooksDict = dict["hooks"] as? [String: Any] {
                agent.hooks = hooksDict
            }

            // Current directory — resolve relative paths against the project root
            if let dirStr = dict["currentDirectory"] as? String {
                if dirStr.hasPrefix("./") || dirStr.hasPrefix("../") {
                    // Relative path: resolve against the agent file's project root
                    if let agentFileURL = fileURL {
                        let projectRoot = agentFileURL
                            .deletingLastPathComponent()  // agents/
                            .deletingLastPathComponent()  // .claude/
                            .deletingLastPathComponent()  // project root
                        agent.currentDirectory = projectRoot.appending(path: dirStr).standardizedFileURL
                    }
                } else {
                    agent.currentDirectory = URL(filePath: (dirStr as NSString).expandingTildeInPath)
                }
            }

            // Memory — supports both simple ("shared") and extended ({ownership: global, storage: shared}) syntax
            if let memoryDict = dict["memory"] as? [String: Any] {
                // Extended syntax: memory: { ownership: global, storage: shared }
                agent.memoryEnabled = true
                if let ownershipStr = memoryDict["ownership"] as? String,
                   let ownership = MemoryOwnership(rawValue: ownershipStr) {
                    agent.memoryOwnership = ownership
                }
                if let storageStr = memoryDict["storage"] as? String {
                    switch storageStr {
                    case "shared": agent.memoryStorage = .shared
                    case "private": agent.memoryStorage = .private
                    default: agent.memoryStorage = scope == .user ? .private : .shared
                    }
                } else {
                    agent.memoryStorage = scope == .user ? .private : .shared
                }
                // Layer toggles (default true when memory is enabled)
                if let extraction = memoryDict["extraction"] as? Bool {
                    agent.memoryExtractionEnabled = extraction
                }
                if let dbSync = memoryDict["dbSync"] as? Bool {
                    agent.memoryDbSyncEnabled = dbSync
                }
                if let embedding = memoryDict["embedding"] as? Bool {
                    agent.memoryEmbeddingEnabled = embedding
                }
            } else if let memoryStr = dict["memory"] as? String {
                switch memoryStr {
                case "shared":
                    agent.memoryEnabled = true
                    agent.memoryStorage = .shared
                case "private":
                    agent.memoryEnabled = true
                    agent.memoryStorage = .private
                case "global":
                    agent.memoryEnabled = true
                    agent.memoryOwnership = .global
                    agent.memoryStorage = .shared
                case "global-private":
                    agent.memoryEnabled = true
                    agent.memoryOwnership = .global
                    agent.memoryStorage = .private
                case "false":
                    agent.memoryEnabled = false
                // Legacy values: migrate to new model
                case "local", "project", "user":
                    agent.memoryEnabled = true
                    agent.memoryStorage = scope == .user ? .private : .shared
                default:
                    agent.memoryEnabled = true
                    agent.memoryStorage = .shared
                }
            } else if let memoryBool = dict["memory"] as? Bool {
                agent.memoryEnabled = memoryBool
                agent.memoryStorage = scope == .user ? .private : .shared
            } else {
                // No memory field: default enabled
                agent.memoryEnabled = true
                agent.memoryStorage = scope == .user ? .private : .shared
            }

            // Memory limit
            if let limit = dict["memoryLimit"] as? Int, limit > 0 {
                agent.memoryLimit = limit
            }

            // Sort order
            if let order = dict["sortOrder"] as? Int {
                agent.sortOrder = order
            }

            // Custom CLI flags
            if let flags = dict["customFlags"] as? String, !flags.isEmpty {
                agent.customFlags = flags
            }

            // Default CLI provider
            if let providerStr = dict["defaultProvider"] as? String,
               let provider = CLIProviderType(rawValue: providerStr) {
                agent.defaultProvider = provider
            }

            // Raw command (manual mode)
            if let raw = dict["rawCommand"] as? String, !raw.isEmpty {
                agent.rawCommand = raw
            }

            return agent
        } catch {
            print("Failed to parse YAML frontmatter: \(error)")
            return nil
        }
    }

    // MARK: - Save Agent

    /// Save an agent to its .md file.
    func saveAgent(_ agent: Agent, to directory: URL? = nil) throws {
        let targetURL: URL
        if let filePath = agent.filePath {
            targetURL = filePath
        } else if let dir = directory {
            targetURL = dir.appending(path: "\(agent.name).md")
        } else {
            throw AgentConfigError.noFilePath
        }

        let content = serializeAgent(agent)

        // Ensure parent directory exists
        let parentDir = targetURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)

        try content.write(to: targetURL, atomically: true, encoding: .utf8)
    }

    /// Serialize an Agent to frontmatter + markdown content.
    func serializeAgent(_ agent: Agent) -> String {
        var lines: [String] = []
        lines.append("---")
        lines.append("name: \(agent.name)")

        if !agent.description.isEmpty {
            lines.append("description: \(yamlEscapeString(agent.description))")
        }

        if agent.model != .inherit {
            lines.append("model: \(agent.model.shortName)")
        }

        lines.append("color: \(agent.color.rawValue)")

        if !agent.tools.isEmpty {
            lines.append("tools: \(agent.tools.joined(separator: ", "))")
        }

        if !agent.disallowedTools.isEmpty {
            lines.append("disallowedTools: \(agent.disallowedTools.joined(separator: ", "))")
        }

        if agent.permissionMode != .default {
            lines.append("permissionMode: \(agent.permissionMode.rawValue)")
        }

        if let maxTurns = agent.maxTurns {
            lines.append("maxTurns: \(maxTurns)")
        }

        if !agent.mcpServers.isEmpty {
            lines.append("mcpServers:")
            for server in agent.mcpServers {
                lines.append("  - \(server)")
            }
        }

        if let currentDir = agent.currentDirectory {
            // Try to relativize against project root; fall back to absolute path
            if let projectRoot = agent.projectRootDirectory {
                let dirPath = currentDir.standardizedFileURL.path(percentEncoded: false)
                let rootPath = projectRoot.standardizedFileURL.path(percentEncoded: false)
                    .hasSuffix("/") ? projectRoot.standardizedFileURL.path(percentEncoded: false)
                    : projectRoot.standardizedFileURL.path(percentEncoded: false) + "/"
                if dirPath.hasPrefix(rootPath) {
                    let relative = "./" + String(dirPath.dropFirst(rootPath.count))
                    lines.append("currentDirectory: \(relative)")
                } else {
                    lines.append("currentDirectory: \(currentDir.path(percentEncoded: false))")
                }
            } else {
                lines.append("currentDirectory: \(currentDir.path(percentEncoded: false))")
            }
        }

        if agent.memoryEnabled {
            let hasLayerOverrides = !agent.memoryExtractionEnabled || !agent.memoryDbSyncEnabled || !agent.memoryEmbeddingEnabled
            if agent.memoryOwnership == .global || hasLayerOverrides {
                // Extended syntax for global ownership or layer overrides
                lines.append("memory:")
                if agent.memoryOwnership == .global {
                    lines.append("  ownership: global")
                }
                lines.append("  storage: \(agent.memoryStorage.yamlValue)")
                if !agent.memoryExtractionEnabled {
                    lines.append("  extraction: false")
                }
                if !agent.memoryDbSyncEnabled {
                    lines.append("  dbSync: false")
                }
                if !agent.memoryEmbeddingEnabled {
                    lines.append("  embedding: false")
                }
            } else {
                lines.append("memory: \(agent.memoryStorage.yamlValue)")
            }
        } else {
            lines.append("memory: false")
        }

        if let limit = agent.memoryLimit {
            lines.append("memoryLimit: \(limit)")
        }

        if agent.sortOrder != 0 {
            lines.append("sortOrder: \(agent.sortOrder)")
        }

        if !agent.customFlags.isEmpty {
            lines.append("customFlags: \(yamlEscapeString(agent.customFlags))")
        }

        if agent.defaultProvider != .claude {
            lines.append("defaultProvider: \(agent.defaultProvider.rawValue)")
        }

        if let rawCommand = agent.rawCommand, !rawCommand.isEmpty {
            lines.append("rawCommand: \(yamlEscapeString(rawCommand))")
        }

        lines.append("---")
        lines.append("")

        if !agent.systemPrompt.isEmpty {
            lines.append(agent.systemPrompt)
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

    /// Parse a comma-separated tools string, respecting parentheses (e.g., "Agent(a, b)").
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

// MARK: - Parse Error

struct AgentParseError: Identifiable {
    let id = UUID()
    let fileName: String
    let filePath: URL
    let error: String
}

// MARK: - Errors

enum AgentConfigError: Error, LocalizedError {
    case noFilePath

    var errorDescription: String? {
        switch self {
        case .noFilePath:
            return "No file path specified for saving agent."
        }
    }
}
