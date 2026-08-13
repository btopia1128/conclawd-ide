import Foundation

struct AgentRelation: Identifiable, Hashable {
    var id: UUID = UUID()
    var parentAgentId: UUID
    var childAgentId: UUID
}

// MARK: - Relation Warnings

enum RelationWarningKind: Hashable {
    /// Parent (user-scope) references child (project-scope) — works only in that project.
    case crossScopeUserToProject
    /// Parent and child are both project-scoped but from different projects.
    case crossProjectReference
    /// Parent references a child name that doesn't resolve to any loaded agent.
    case brokenReference(parentName: String, childName: String)
}

struct RelationWarning: Identifiable, Hashable {
    let id = UUID()
    let kind: RelationWarningKind
    let parentAgentId: UUID?
    let childAgentId: UUID?
    var message: String
}
