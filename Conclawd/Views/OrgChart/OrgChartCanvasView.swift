import SwiftUI

/// Infinite canvas with pan & zoom for the org chart (Figma/Miro-like).
struct OrgChartCanvasView: View {
    @Bindable var viewModel: OrgChartViewModel
    @Environment(AppState.self) private var appState
    @State private var agentToDelete: Agent?

    // Cross-scope relationship confirmation
    @State private var showCrossScopeAlert = false
    @State private var crossScopeParent: Agent?
    @State private var crossScopeChild: Agent?

    // Cross-project relationship confirmation
    @State private var showCrossProjectAlert = false
    @State private var crossProjectParent: Agent?
    @State private var crossProjectChild: Agent?

    // Canvas transform state
    @State private var canvasOffset: CGSize = .zero
    @State private var canvasScale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0
    @State private var hasCenteredOnce = false

    // Pan gesture state
    @State private var isPanning = false
    @State private var panStart: CGSize = .zero
    @State private var isNodeDragging = false

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // Grid background — also receives pan gesture.
                // Behind canvasContent in ZStack, so node/port drags win hit testing.
                gridBackground(size: geo.size)
                    .contentShape(Rectangle())
                    .gesture(panGesture)

                // Transformable canvas content
                canvasContent
                    .scaleEffect(canvasScale, anchor: .topLeading)
                    .offset(canvasOffset)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
            // Zoom: scroll wheel / pinch — zoom toward view center
            .onMagnificationGesture { value in
                let newScale = min(max(lastScale * value, 0.2), 3.0)
                // Adjust offset so the view center stays fixed
                let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
                let ratio = newScale / canvasScale
                canvasOffset = CGSize(
                    width: center.x - (center.x - canvasOffset.width) * ratio,
                    height: center.y - (center.y - canvasOffset.height) * ratio
                )
                canvasScale = newScale
            } onEnded: {
                lastScale = canvasScale
            }
            .coordinateSpace(name: "orgChartCanvas")
            .task { centerContent(in: geo.size) }
            .onChange(of: viewModel.nodes.count) {
                Task { @MainActor in centerContent(in: geo.size) }
            }
        }
        .themedBackground(Color.appSurface)
        .alert("Delete Agent", isPresented: .init(
            get: { agentToDelete != nil },
            set: { if !$0 { agentToDelete = nil } }
        )) {
            Button("Cancel", role: .cancel) { agentToDelete = nil }
            Button("Delete", role: .destructive) {
                if let agent = agentToDelete {
                    appState.deleteAgent(agent)
                    agentToDelete = nil
                }
            }
        } message: {
            if let agent = agentToDelete {
                Text("Delete \"\(agent.name)\"? The agent file will be removed from disk.")
            }
        }
        .alert("Cross-Scope Relationship", isPresented: $showCrossScopeAlert) {
            Button("Cancel", role: .cancel) {
                crossScopeParent = nil
                crossScopeChild = nil
            }
            Button("Create") {
                if var parent = crossScopeParent, let child = crossScopeChild {
                    performAddRelation(parent: &parent, childName: child.name)
                }
                crossScopeParent = nil
                crossScopeChild = nil
            }
        } message: {
            if let parent = crossScopeParent, let child = crossScopeChild {
                Text("\"\(parent.name)\" (user) → \"\(child.name)\" (project)\n\nThis relationship only works in the current project. The user agent won't find this child in other projects.")
            }
        }
        .alert("Cross-Project Relationship", isPresented: $showCrossProjectAlert) {
            Button("Cancel", role: .cancel) {
                crossProjectParent = nil
                crossProjectChild = nil
            }
            Button("Create") {
                if var parent = crossProjectParent, let child = crossProjectChild {
                    performAddRelation(parent: &parent, childName: child.name)
                }
                crossProjectParent = nil
                crossProjectChild = nil
            }
        } message: {
            if let parent = crossProjectParent, let child = crossProjectChild {
                Text("\"\(parent.name)\" (\(parent.sourceProjectName ?? "?")) → \"\(child.name)\" (\(child.sourceProjectName ?? "?"))\n\nThese agents are in different projects. Claude Code won't find the child agent when running from either project.")
            }
        }
    }

    // MARK: - Grid Background

    private func gridBackground(size: CGSize) -> some View {
        Canvas { context, canvasSize in
            let dotSpacing: CGFloat = 20 * canvasScale
            guard dotSpacing > 4 else { return } // Too zoomed out, skip dots

            let offsetX = canvasOffset.width.truncatingRemainder(dividingBy: dotSpacing)
            let offsetY = canvasOffset.height.truncatingRemainder(dividingBy: dotSpacing)

            let dotSize: CGFloat = max(1.0, 1.5 * canvasScale)
            let color = Color.secondary.opacity(0.35)

            var x = offsetX
            while x < canvasSize.width {
                var y = offsetY
                while y < canvasSize.height {
                    context.fill(
                        Path(ellipseIn: CGRect(x: x - dotSize / 2, y: y - dotSize / 2, width: dotSize, height: dotSize)),
                        with: .color(color)
                    )
                    y += dotSpacing
                }
                x += dotSpacing
            }
        }
    }

    // MARK: - Center Content

    /// Centers the node bounding box within the visible area on initial display.
    private func centerContent(in viewSize: CGSize) {
        guard !viewModel.nodes.isEmpty else { return }
        // Only auto-center once per view lifetime, or when nodes first appear
        if hasCenteredOnce && canvasOffset != .zero { return }
        hasCenteredOnce = true

        // Compute bounding box of all nodes
        let positions = viewModel.nodes.map(\.position)
        let minX = positions.map(\.x).min()! - 70  // half node width
        let maxX = positions.map(\.x).max()! + 70
        let minY = positions.map(\.y).min()! - 30  // half node height
        let maxY = positions.map(\.y).max()! + 30

        let contentWidth = maxX - minX
        let contentHeight = maxY - minY
        let contentCenterX = (minX + maxX) / 2
        let contentCenterY = (minY + maxY) / 2

        // Fit scale so content fills ~80% of view
        let scaleX = viewSize.width * 0.8 / contentWidth
        let scaleY = viewSize.height * 0.8 / contentHeight
        let fitScale = min(min(scaleX, scaleY), 1.0) // Don't zoom in beyond 1.0
        canvasScale = max(fitScale, 0.3)
        lastScale = canvasScale

        // Offset to center
        canvasOffset = CGSize(
            width: viewSize.width / 2 - contentCenterX * canvasScale,
            height: viewSize.height / 2 - contentCenterY * canvasScale
        )
        panStart = canvasOffset
    }

    // MARK: - Pan Gesture

    private var panGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                guard !isNodeDragging else { return }
                if !isPanning {
                    isPanning = true
                    panStart = canvasOffset
                }
                canvasOffset = CGSize(
                    width: panStart.width + value.translation.width,
                    height: panStart.height + value.translation.height
                )
            }
            .onEnded { _ in
                isPanning = false
            }
    }

    // MARK: - Canvas Content

    private var canvasContent: some View {
        ZStack {
            // Edges layer
            ForEach(viewModel.edges) { edge in
                edgeView(edge: edge)
            }

            // Drag connection preview
            if let drag = viewModel.dragConnection,
               let sourceNode = viewModel.nodes.first(where: { $0.id == drag.sourceNodeId }) {
                let from = CGPoint(
                    x: sourceNode.position.x,
                    y: sourceNode.position.y + sourceNode.size.height / 2
                )
                DragLineShape(from: from, to: drag.currentPoint)
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))

                if let targetNode = viewModel.nodeAt(point: drag.currentPoint),
                   targetNode.id != drag.sourceNodeId {
                    // Offset to align with the main card center within AgentNodeView's VStack
                    // Input port zone (10 + 4 padding) = 14, Output port zone (20 + 4 padding) = 24
                    let cardCenterOffsetY = CGFloat(14 - 24) / 2  // -5
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.accentColor, lineWidth: 3)
                        .frame(width: targetNode.size.width + 4, height: targetNode.size.height - 24 + 4)
                        .position(x: targetNode.position.x, y: targetNode.position.y + cardCenterOffsetY)
                }
            }

            // Nodes layer
            ForEach(viewModel.nodes) { node in
                AgentNodeView(
                    node: node,
                    isSelected: viewModel.selectedNodeId == node.id,
                    processStatus: appState.bestStatus(agentId: node.agentId),
                    canvasScale: canvasScale,
                    onSelect: {
                        viewModel.selectedNodeId = node.id
                        // Look up by stableIdentity (filePath) instead of UUID,
                        // because reloadAgents() regenerates UUIDs and rapid clicks
                        // can race with file-watcher-triggered reloads.
                        let stableId = node.agent.stableIdentity
                        if let agent = appState.agents.first(where: { $0.stableIdentity == stableId }) {
                            appState.selectAgent(agent)
                        }
                    },
                    onDoubleClick: {
                        let stableId = node.agent.stableIdentity
                        if let agent = appState.agents.first(where: { $0.stableIdentity == stableId }) {
                            appState.startAgent(agent)
                        }
                    },
                    onDelete: {
                        let stableId = node.agent.stableIdentity
                        if let agent = appState.agents.first(where: { $0.stableIdentity == stableId }) {
                            agentToDelete = agent
                        }
                    },
                    onDragMove: { newPos in
                        viewModel.moveNode(id: node.id, to: newPos)
                    },
                    onDragStateChanged: { dragging in
                        isNodeDragging = dragging
                    },
                    onPortDragChanged: { point in
                        if viewModel.dragConnection == nil {
                            viewModel.beginConnection(from: node.id)
                        }
                        // Convert screen point to canvas coordinates
                        let canvasPoint = screenToCanvas(point)
                        viewModel.updateConnection(to: canvasPoint)
                    },
                    onPortDragEnded: { point in
                        let canvasPoint = screenToCanvas(point)
                        viewModel.updateConnection(to: canvasPoint)
                        if let result = viewModel.endConnection() {
                            addRelation(parentId: result.parentId, childId: result.childId)
                        } else {
                            viewModel.cancelConnection()
                        }
                    }
                )
                .position(node.position)
            }
        }
    }

    // MARK: - Edge View

    @ViewBuilder
    private func edgeView(edge: OrgChartEdge) -> some View {
        let from = viewModel.sourcePoint(for: edge)
        let to = viewModel.targetPoint(for: edge)

        if edge.isCrossProject {
            EdgeShape(from: from, to: to)
                .stroke(Color.red.opacity(0.7), style: StrokeStyle(lineWidth: 2, dash: [8, 4]))
                .contentShape(EdgeHitArea(from: from, to: to))
                .contextMenu { edgeContextMenu(edge: edge) }
        } else if edge.isCrossScope {
            EdgeShape(from: from, to: to)
                .stroke(Color.orange.opacity(0.7), style: StrokeStyle(lineWidth: 2, dash: [8, 4]))
                .contentShape(EdgeHitArea(from: from, to: to))
                .contextMenu { edgeContextMenu(edge: edge) }
        } else {
            EdgeShape(from: from, to: to)
                .stroke(Color.secondary.opacity(0.6), lineWidth: 2)
                .contentShape(EdgeHitArea(from: from, to: to))
                .contextMenu { edgeContextMenu(edge: edge) }
        }
    }

    private func edgeContextMenu(edge: OrgChartEdge) -> some View {
        Button("Remove Relationship", role: .destructive) {
            removeRelation(edge: edge)
        }
    }

    // MARK: - Coordinate Conversion

    private func screenToCanvas(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: (point.x - canvasOffset.width) / canvasScale,
            y: (point.y - canvasOffset.height) / canvasScale
        )
    }

    // MARK: - Relation Management

    private func addRelation(parentId: UUID, childId: UUID) {
        if appState.relationService.wouldCreateCycle(
            agents: appState.agents, parentId: parentId, childId: childId
        ) {
            appState.errorMessage = "Cannot create relationship: would create a cycle."
            return
        }

        guard var parent = appState.agents.first(where: { $0.id == parentId }),
              let child = appState.agents.first(where: { $0.id == childId }) else { return }

        // Warn (but allow) cross-project project→project relationship
        if appState.relationService.isCrossProject(parent: parent, child: child) {
            crossProjectParent = parent
            crossProjectChild = child
            showCrossProjectAlert = true
            return
        }

        // Warn (but allow) user → project cross-scope relationship
        if parent.scope == .user && child.scope == .project {
            crossScopeParent = parent
            crossScopeChild = child
            showCrossScopeAlert = true
            return
        }

        performAddRelation(parent: &parent, childName: child.name)
    }

    private func performAddRelation(parent: inout Agent, childName: String) {
        do {
            try appState.relationService.addRelation(parent: &parent, childName: childName)
            appState.reloadAgents()
        } catch {
            appState.errorMessage = "Failed to add relationship: \(error.localizedDescription)"
        }
    }

    private func removeRelation(edge: OrgChartEdge) {
        // Look up by name (stable) instead of UUID (regenerated on every reloadAgents).
        // This prevents silent failures when the file watcher triggers a reload
        // between context menu creation and button press.
        guard var parent = appState.agents.first(where: { $0.stableIdentity == edge.parentStableId }) else { return }

        do {
            try appState.relationService.removeRelation(parent: &parent, childName: edge.childAgentName)
            appState.reloadAgents()
        } catch {
            appState.errorMessage = "Failed to remove relationship: \(error.localizedDescription)"
        }
    }
}

// MARK: - Magnification Gesture Helper

extension View {
    func onMagnificationGesture(
        perform: @escaping (CGFloat) -> Void,
        onEnded: @escaping () -> Void
    ) -> some View {
        self.gesture(
            MagnificationGesture()
                .onChanged { value in perform(value) }
                .onEnded { _ in onEnded() }
        )
    }
}
