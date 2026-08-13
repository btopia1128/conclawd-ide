import SwiftUI

/// A single node in the org chart representing an agent.
struct AgentNodeView: View {
    let node: OrgChartNode
    let isSelected: Bool
    let processStatus: AgentProcessStatus
    var canvasScale: CGFloat = 1.0

    var onSelect: () -> Void = {}
    var onDoubleClick: () -> Void = {}
    var onDelete: () -> Void = {}
    var onDragMove: (CGPoint) -> Void = { _ in }
    var onDragStateChanged: (Bool) -> Void = { _ in }
    var onPortDragChanged: (CGPoint) -> Void = { _ in }
    var onPortDragEnded: (CGPoint) -> Void = { _ in }

    @State private var isDraggingNode = false
    @State private var isDraggingPort = false
    @State private var dragStartPosition: CGPoint = .zero

    var body: some View {
        VStack(spacing: 0) {
            // Input port (top) — visual indicator for drop target
            Circle()
                .fill(Color.appBorder)
                .frame(width: 10, height: 10)
                .padding(.bottom, 4)

            // Main card
            mainCard

            // Output port (bottom) — drag to create connection
            outputPort
        }
        .frame(width: node.size.width, height: node.size.height + 10)
    }

    // MARK: - Main Card

    private var mainCard: some View {
        HStack(spacing: 6) {
            // Color bar
            RoundedRectangle(cornerRadius: 2)
                .fill(node.agent.color.swiftUIColor)
                .frame(width: 4)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 6, height: 6)

                    Text(node.agent.name)
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                }

                if let projectName = node.agent.sourceProjectName {
                    Text(projectName)
                        .font(.system(size: 9))
                        .foregroundStyle(Color.appSecondary)
                        .lineLimit(1)
                } else if node.agent.scope == .user {
                    Text("Global")
                        .font(.system(size: 9))
                        .foregroundStyle(Color.appSecondary)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(width: node.size.width, height: node.size.height - 24)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(.background)
                .shadow(color: .appShadow, radius: 3, y: 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? Color.accentColor : Color.appBorder, lineWidth: isSelected ? 2 : 0.5)
        )
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { onDoubleClick() }
        .onTapGesture(count: 1) { onSelect() }
        .contextMenu {
            Button("Start") { onDoubleClick() }
            Divider()
            Button("Delete Agent", role: .destructive) { onDelete() }
        }
        .gesture(
            DragGesture(coordinateSpace: .named("orgChartCanvas"))
                .onChanged { value in
                    if !isDraggingNode {
                        isDraggingNode = true
                        dragStartPosition = node.position
                        onDragStateChanged(true)
                    }
                    onDragMove(CGPoint(
                        x: dragStartPosition.x + value.translation.width / canvasScale,
                        y: dragStartPosition.y + value.translation.height / canvasScale
                    ))
                }
                .onEnded { _ in
                    isDraggingNode = false
                    onDragStateChanged(false)
                }
        )
    }

    // MARK: - Output Port

    private var outputPort: some View {
        Circle()
            .fill(isDraggingPort ? Color.accentColor : Color.accentColor.opacity(0.6))
            .frame(width: 20, height: 20)
            .overlay(
                Image(systemName: "plus")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
            )
            .padding(.top, 4)
            .contentShape(Circle().inset(by: -10))
            .gesture(
                DragGesture(coordinateSpace: .named("orgChartCanvas"))
                    .onChanged { value in
                        isDraggingPort = true
                        onPortDragChanged(value.location)
                    }
                    .onEnded { value in
                        isDraggingPort = false
                        onPortDragEnded(value.location)
                    }
            )
    }

    private var statusColor: Color {
        switch processStatus {
        case .running: return .statusRunning
        case .waitingForInput: return .statusReady
        case .stopped: return .statusStopped
        }
    }
}
