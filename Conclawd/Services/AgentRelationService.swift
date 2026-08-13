import Foundation

/// Manages parent-child (sub-agent) relationships between agents.
final class AgentRelationService {

    private let configService: AgentConfigService

    /// Default tools to populate when tools array is empty and a relation is added.
    /// Empty tools means "all tools available" in Claude Code, so we must preserve that.
    static let defaultTools = [
        "Read", "Edit", "Write", "Bash", "Grep", "Glob",
        "WebSearch", "WebFetch"
    ]

    init(configService: AgentConfigService = AgentConfigService()) {
        self.configService = configService
    }

    // MARK: - Extract Relations

    /// Extract all agent relations from a set of agents by parsing their tools arrays.
    /// When multiple agents share the same name (across scopes), the resolution prefers
    /// same-scope matches, then project-scope, matching Claude Code's runtime behavior.
    func extractRelations(agents: [Agent]) -> [AgentRelation] {
        var relations: [AgentRelation] = []

        // Group by name to handle collisions across scopes
        var agentsByName: [String: [Agent]] = [:]
        for agent in agents {
            agentsByName[agent.name, default: []].append(agent)
        }

        for agent in agents {
            for childName in agent.subAgentNames {
                guard let candidates = agentsByName[childName], !candidates.isEmpty else { continue }

                let resolved: Agent
                if candidates.count == 1 {
                    resolved = candidates[0]
                } else {
                    // Same scope first, then project, then any
                    if let sameScope = candidates.first(where: { $0.scope == agent.scope && $0.id != agent.id }) {
                        resolved = sameScope
                    } else if let proj = candidates.first(where: { $0.scope == .project }) {
                        resolved = proj
                    } else {
                        resolved = candidates[0]
                    }
                }

                relations.append(AgentRelation(
                    parentAgentId: agent.id,
                    childAgentId: resolved.id
                ))
            }
        }

        return relations
    }

    // MARK: - Modify Relations

    /// Add a sub-agent relationship: parent can now spawn child.
    /// Updates the parent agent's tools array and saves to disk.
    func addRelation(parent: inout Agent, childName: String) throws {
        // If tools is empty (all tools available), populate with defaults first
        // to avoid restricting the agent to only Agent(child)
        if parent.tools.isEmpty {
            parent.tools = Self.defaultTools
        }

        // Check if already has an Agent(...) entry in tools
        let agentToolIndex = parent.tools.firstIndex { $0.hasPrefix("Agent(") && $0.hasSuffix(")") }

        if let index = agentToolIndex {
            // Parse existing Agent(...) entry and add the new child
            let existing = parent.tools[index]
            let inner = String(existing.dropFirst(6).dropLast(1))
            let names = inner.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }

            guard !names.contains(childName) else { return } // Already exists

            let updated = names + [childName]
            parent.tools[index] = "Agent(\(updated.joined(separator: ", ")))"
        } else {
            // Add new Agent(...) entry
            parent.tools.append("Agent(\(childName))")
        }

        try configService.saveAgent(parent)
    }

    /// Remove a sub-agent relationship.
    /// Updates the parent agent's tools array and saves to disk.
    /// Searches ALL `Agent(...)` entries (there may be more than one if hand-edited).
    func removeRelation(parent: inout Agent, childName: String) throws {
        var modified = false

        for i in stride(from: parent.tools.count - 1, through: 0, by: -1) {
            let tool = parent.tools[i]
            guard tool.hasPrefix("Agent(") && tool.hasSuffix(")") else { continue }

            let inner = String(tool.dropFirst(6).dropLast(1))
            var names = inner.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }

            guard names.contains(childName) else { continue }

            names.removeAll { $0 == childName }
            if names.isEmpty {
                parent.tools.remove(at: i)
            } else {
                parent.tools[i] = "Agent(\(names.joined(separator: ", ")))"
            }
            modified = true
        }

        guard modified else { return }
        try configService.saveAgent(parent)
    }

    // MARK: - Warnings

    /// Check if two project-scoped agents are from different projects.
    func isCrossProject(parent: Agent, child: Agent) -> Bool {
        guard parent.scope == .project, child.scope == .project else { return false }
        guard let parentProject = parent.sourceProjectName,
              let childProject = child.sourceProjectName else { return false }
        return parentProject != childProject
    }

    /// Detect broken references: Agent(childName) entries where childName doesn't resolve.
    func findBrokenReferences(agents: [Agent]) -> [(parent: Agent, unresolvedName: String)] {
        let knownNames = Set(agents.map(\.name))
        var broken: [(parent: Agent, unresolvedName: String)] = []
        for agent in agents {
            for childName in agent.subAgentNames {
                if !knownNames.contains(childName) {
                    broken.append((parent: agent, unresolvedName: childName))
                }
            }
        }
        return broken
    }

    /// Find all relation warnings across all agents.
    func findAllWarnings(agents: [Agent]) -> [RelationWarning] {
        var warnings: [RelationWarning] = []
        let relations = extractRelations(agents: agents)
        let agentById = Dictionary(uniqueKeysWithValues: agents.map { ($0.id, $0) })

        for rel in relations {
            guard let parent = agentById[rel.parentAgentId],
                  let child = agentById[rel.childAgentId] else { continue }

            if parent.scope == .user && child.scope == .project {
                warnings.append(RelationWarning(
                    kind: .crossScopeUserToProject,
                    parentAgentId: parent.id,
                    childAgentId: child.id,
                    message: "\"\(parent.name)\" (user) → \"\(child.name)\" (project): only works in the current project."
                ))
            }

            if isCrossProject(parent: parent, child: child) {
                warnings.append(RelationWarning(
                    kind: .crossProjectReference,
                    parentAgentId: parent.id,
                    childAgentId: child.id,
                    message: "\"\(parent.name)\" (\(parent.sourceProjectName ?? "?")) → \"\(child.name)\" (\(child.sourceProjectName ?? "?")): agents are in different projects."
                ))
            }
        }

        for (parent, unresolvedName) in findBrokenReferences(agents: agents) {
            warnings.append(RelationWarning(
                kind: .brokenReference(parentName: parent.name, childName: unresolvedName),
                parentAgentId: parent.id,
                childAgentId: nil,
                message: "\"\(parent.name)\" references sub-agent \"\(unresolvedName)\" which doesn't exist."
            ))
        }

        return warnings
    }

    // MARK: - Validation

    /// Check if adding a relation would create a cycle.
    func wouldCreateCycle(agents: [Agent], parentId: UUID, childId: UUID) -> Bool {
        // Build adjacency list
        let relations = extractRelations(agents: agents)
        var adjacency: [UUID: [UUID]] = [:]
        for relation in relations {
            adjacency[relation.parentAgentId, default: []].append(relation.childAgentId)
        }
        // Add the proposed new edge
        adjacency[parentId, default: []].append(childId)

        // DFS from childId to see if we can reach parentId (would mean cycle)
        var visited: Set<UUID> = []
        var stack: [UUID] = [childId]

        while let current = stack.popLast() {
            if current == parentId { return true }
            if visited.contains(current) { continue }
            visited.insert(current)
            stack.append(contentsOf: adjacency[current] ?? [])
        }

        return false
    }
}
