import Foundation
import SwiftUI

// MARK: - Data Types

struct OrgChartNode: Identifiable {
    let id: UUID
    /// The current agent UUID (may change on reloadAgents, unlike `id` which is stable).
    var agentId: UUID
    var agent: Agent
    var position: CGPoint = .zero
    let size: CGSize = CGSize(width: 140, height: 60)
    var level: Int = 0
}

struct OrgChartEdge: Identifiable {
    var id: String { "\(sourceAgentId)-\(targetAgentId)" }
    let sourceAgentId: UUID
    let targetAgentId: UUID
    /// Stable identity of the parent agent (filePath or name). Unique across scopes.
    let parentStableId: String
    /// Child agent name as referenced in the parent's `Agent(...)` tool entry.
    let childAgentName: String
    /// true when a user-scope agent references a project-scope agent (works only in that project).
    var isCrossScope: Bool = false
    /// true when both agents are project-scoped but belong to different projects.
    var isCrossProject: Bool = false
}

struct DragConnectionState {
    /// The stable node ID (not the agent UUID).
    let sourceNodeId: UUID
    var currentPoint: CGPoint
}

/// Controls which agents are shown in the org chart.
enum OrgChartFilter: Equatable {
    /// Show all agents across all scopes.
    case all
    /// Show project agents + user agents connected to them.
    case project
}

// MARK: - View Model

@Observable
@MainActor
final class OrgChartViewModel {

    var nodes: [OrgChartNode] = []
    var edges: [OrgChartEdge] = []
    var selectedNodeId: UUID?
    var dragConnection: DragConnectionState?
    var canvasSize: CGSize = CGSize(width: 800, height: 600)

    /// Persistent position cache keyed by agent name.
    /// Survives node rebuilds, filter changes, view re-creation, and app restarts.
    private var positionCache: [String: CGPoint] = [:]

    private var saveWorkItem: DispatchWorkItem?

    private let nodeWidth: CGFloat = 140
    private let nodeHeight: CGFloat = 60
    private let horizontalGap: CGFloat = 40
    private let verticalGap: CGFloat = 100
    private let padding: CGFloat = 60

    // MARK: - Init

    init() {
        loadPositions()
    }

    // MARK: - Update

    func update(agents: [Agent], relations: [AgentRelation], filter: OrgChartFilter = .all, showGlobalAgents: Bool = true) {
        // Determine visible agents based on filter
        let visibleAgents: [Agent]
        let visibleAgentIds: Set<UUID>

        switch filter {
        case .all:
            visibleAgents = agents
            visibleAgentIds = Set(agents.map(\.id))

        case .project:
            let projectAgentIds = Set(agents.filter { $0.scope == .project }.map(\.id))

            if showGlobalAgents {
                // Show all project agents + all global (user-scope) agents
                let userAgentIds = Set(agents.filter { $0.scope == .user }.map(\.id))
                let allowed = projectAgentIds.union(userAgentIds)
                visibleAgents = agents.filter { allowed.contains($0.id) }
                visibleAgentIds = allowed
            } else {
                visibleAgents = agents.filter { projectAgentIds.contains($0.id) }
                visibleAgentIds = projectAgentIds
            }
        }

        let agentById = Dictionary(uniqueKeysWithValues: agents.map { ($0.id, $0) })

        // Flush current node positions into the cache before rebuilding
        for node in nodes where node.position != .zero {
            positionCache[node.agent.name] = node.position
        }

        // Check if the visible agent set actually changed (by stableIdentity, since UUIDs change on every reload)
        let newIdentities = Set(visibleAgents.map(\.stableIdentity))
        let currentIdentities = Set(nodes.map(\.agent.stableIdentity))

        if newIdentities == currentIdentities && !nodes.isEmpty {
            // Same agent set — update agentId and agent data, but preserve node IDs and positions
            let agentByIdentity = Dictionary(uniqueKeysWithValues: visibleAgents.map { ($0.stableIdentity, $0) })
            for i in nodes.indices {
                if let agent = agentByIdentity[nodes[i].agent.stableIdentity] {
                    let pos = nodes[i].position
                    let level = nodes[i].level
                    let stableId = nodes[i].id
                    nodes[i] = OrgChartNode(id: stableId, agentId: agent.id, agent: agent)
                    nodes[i].position = pos
                    nodes[i].level = level
                }
            }
        } else {
            // Agent set changed — full rebuild
            nodes = visibleAgents.map { agent in
                var node = OrgChartNode(id: agent.id, agentId: agent.id, agent: agent)
                if let pos = positionCache[agent.name] {
                    node.position = pos
                }
                return node
            }
        }

        // Build edges (always rebuild with current agent UUIDs)
        edges = relations.compactMap { rel in
            guard visibleAgentIds.contains(rel.parentAgentId),
                  visibleAgentIds.contains(rel.childAgentId) else { return nil }
            let parent = agentById[rel.parentAgentId]
            let child = agentById[rel.childAgentId]
            let isCross = parent?.scope == .user && child?.scope == .project
            let isCrossProj = parent?.scope == .project && child?.scope == .project
                && parent?.sourceProjectName != nil && child?.sourceProjectName != nil
                && parent?.sourceProjectName != child?.sourceProjectName
            return OrgChartEdge(
                sourceAgentId: rel.parentAgentId,
                targetAgentId: rel.childAgentId,
                parentStableId: parent?.stableIdentity ?? "",
                childAgentName: child?.name ?? "",
                isCrossScope: isCross,
                isCrossProject: isCrossProj
            )
        }

        // Auto layout if no nodes have positions yet; otherwise place new nodes smartly
        if nodes.allSatisfy({ $0.position == .zero }) {
            autoLayout()
        } else {
            placeNewNodes()
        }
    }

    // MARK: - Tree Layout

    func autoLayout() {
        guard !nodes.isEmpty else { return }

        // Clear cached positions so fresh layout takes effect
        positionCache.removeAll()

        // Build adjacency: parent -> [children] (using agentId for edge matching)
        var children: [UUID: [UUID]] = [:]
        var hasParent: Set<UUID> = []
        for edge in edges {
            children[edge.sourceAgentId, default: []].append(edge.targetAgentId)
            hasParent.insert(edge.targetAgentId)
        }

        // Find roots (nodes with no parent)
        let rootIds = nodes.filter { !hasParent.contains($0.agentId) }.map(\.id)

        // Assign levels via BFS
        var levels: [UUID: Int] = [:]
        var queue: [(UUID, Int)] = rootIds.map { ($0, 0) }
        while !queue.isEmpty {
            let (nodeId, level) = queue.removeFirst()
            if let existing = levels[nodeId], existing >= level { continue }
            levels[nodeId] = level
            // Find children via agentId mapping
            if let node = nodes.first(where: { $0.id == nodeId }),
               let childAgentIds = children[node.agentId] {
                for childAgentId in childAgentIds {
                    if let childNode = nodes.first(where: { $0.agentId == childAgentId }) {
                        queue.append((childNode.id, level + 1))
                    }
                }
            }
        }

        // Assign level 0 to orphans (no edges at all)
        for i in nodes.indices {
            if levels[nodes[i].id] == nil {
                levels[nodes[i].id] = 0
            }
            nodes[i].level = levels[nodes[i].id] ?? 0
        }

        // Group nodes by level
        let maxLevel = nodes.map(\.level).max() ?? 0
        var levelGroups: [[Int]] = Array(repeating: [], count: maxLevel + 1)
        for (index, node) in nodes.enumerated() {
            levelGroups[node.level].append(index)
        }

        // Position nodes
        let maxNodesInLevel = levelGroups.map(\.count).max() ?? 1
        let totalWidth = CGFloat(maxNodesInLevel) * (nodeWidth + horizontalGap) - horizontalGap + padding * 2

        for level in 0...maxLevel {
            let indicesInLevel = levelGroups[level]
            let count = CGFloat(indicesInLevel.count)
            let levelWidth = count * (nodeWidth + horizontalGap) - horizontalGap
            let startX = (totalWidth - levelWidth) / 2 + nodeWidth / 2

            for (i, nodeIndex) in indicesInLevel.enumerated() {
                let x = startX + CGFloat(i) * (nodeWidth + horizontalGap)
                let y = padding + CGFloat(level) * (nodeHeight + verticalGap) + nodeHeight / 2
                nodes[nodeIndex].position = CGPoint(x: x, y: y)
            }
        }

        // Compute canvas size
        let maxX = nodes.map { $0.position.x + nodeWidth / 2 }.max() ?? 400
        let maxY = nodes.map { $0.position.y + nodeHeight / 2 }.max() ?? 300
        canvasSize = CGSize(width: max(maxX + padding, 800), height: max(maxY + padding, 600))

        // Sync layout results into the cache
        for node in nodes {
            positionCache[node.agent.name] = node.position
        }
        scheduleSave()
    }

    /// Place nodes that have no position (newly added) below existing nodes.
    private func placeNewNodes() {
        let newIndices = nodes.indices.filter { nodes[$0].position == .zero }
        guard !newIndices.isEmpty else { return }

        // Find the bottom-most Y of existing nodes
        let existingMaxY = nodes.filter { $0.position != .zero }
            .map { $0.position.y }.max() ?? padding
        // Find the horizontal center of existing nodes
        let positioned = nodes.filter { $0.position != .zero }
        let centerX: CGFloat
        if positioned.isEmpty {
            centerX = padding + nodeWidth / 2
        } else {
            let minX = positioned.map { $0.position.x }.min()!
            let maxX = positioned.map { $0.position.x }.max()!
            centerX = (minX + maxX) / 2
        }

        let startY = existingMaxY + verticalGap + nodeHeight / 2
        let totalWidth = CGFloat(newIndices.count) * (nodeWidth + horizontalGap) - horizontalGap
        let startX = centerX - totalWidth / 2 + nodeWidth / 2

        for (i, nodeIndex) in newIndices.enumerated() {
            let x = startX + CGFloat(i) * (nodeWidth + horizontalGap)
            let pos = CGPoint(x: x, y: startY)
            nodes[nodeIndex].position = pos
            positionCache[nodes[nodeIndex].agent.name] = pos
        }
        scheduleSave()
    }

    // MARK: - Node Interaction

    func moveNode(id: UUID, to position: CGPoint) {
        if let index = nodes.firstIndex(where: { $0.id == id }) {
            nodes[index].position = position
            positionCache[nodes[index].agent.name] = position
            scheduleSave()
        }
    }

    func nodeAt(point: CGPoint) -> OrgChartNode? {
        nodes.first { node in
            let rect = CGRect(
                x: node.position.x - node.size.width / 2,
                y: node.position.y - node.size.height / 2,
                width: node.size.width,
                height: node.size.height
            )
            return rect.contains(point)
        }
    }

    // MARK: - Connection Drag

    func beginConnection(from nodeId: UUID) {
        if let node = nodes.first(where: { $0.id == nodeId }) {
            let startPoint = CGPoint(x: node.position.x, y: node.position.y + node.size.height / 2)
            dragConnection = DragConnectionState(sourceNodeId: nodeId, currentPoint: startPoint)
        }
    }

    func updateConnection(to point: CGPoint) {
        dragConnection?.currentPoint = point
    }

    func endConnection() -> (parentId: UUID, childId: UUID)? {
        guard let drag = dragConnection else { return nil }
        defer { dragConnection = nil }

        if let target = nodeAt(point: drag.currentPoint),
           target.id != drag.sourceNodeId {
            // Return agentIds (current UUIDs) for relation management
            guard let source = nodes.first(where: { $0.id == drag.sourceNodeId }) else { return nil }
            return (parentId: source.agentId, childId: target.agentId)
        }
        return nil
    }

    func cancelConnection() {
        dragConnection = nil
    }

    // MARK: - Edge Helpers

    func sourcePoint(for edge: OrgChartEdge) -> CGPoint {
        guard let node = nodes.first(where: { $0.agentId == edge.sourceAgentId }) else { return .zero }
        return CGPoint(x: node.position.x, y: node.position.y + node.size.height / 2)
    }

    func targetPoint(for edge: OrgChartEdge) -> CGPoint {
        guard let node = nodes.first(where: { $0.agentId == edge.targetAgentId }) else { return .zero }
        return CGPoint(x: node.position.x, y: node.position.y - node.size.height / 2)
    }

    // MARK: - Persistence

    private static var positionsFileURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = appSupport.appending(path: "Conclawd")
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        return appDir.appending(path: "orgchart_positions.json")
    }

    private func loadPositions() {
        guard let data = try? Data(contentsOf: Self.positionsFileURL),
              let dict = try? JSONDecoder().decode([String: [CGFloat]].self, from: data) else {
            return
        }
        for (name, xy) in dict where xy.count == 2 {
            positionCache[name] = CGPoint(x: xy[0], y: xy[1])
        }
    }

    /// Save positions to disk (debounced to avoid excessive writes during drag).
    private func scheduleSave() {
        saveWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.savePositions()
        }
        saveWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func savePositions() {
        let dict = positionCache.mapValues { [$0.x, $0.y] }
        guard let data = try? JSONEncoder().encode(dict) else { return }
        try? data.write(to: Self.positionsFileURL, options: .atomic)
    }
}
