import SwiftUI
import UniformTypeIdentifiers

/// Main content view with a full-width top bar and custom three-column layout.
struct ContentView: View {
    @Environment(AppState.self) private var appState
    @State private var showSidebar = true
    @State private var showInspector = false // TEMP-DEBUG
    @State private var sidebarWidth: CGFloat = 240
    @State private var inspectorWidth: CGFloat = 400

    var body: some View {
        #if DEBUG
        let _ = Self._printChanges()
        #endif
        VStack(spacing: 0) {
            // Full-width top bar (traffic-light height)
            TopBarView(showSidebar: $showSidebar, showInspector: $showInspector)

            Divider()

            // Three-column content
            HStack(spacing: 0) {
                // Left sidebar
                if showSidebar {
                    SidebarView(showSidebar: $showSidebar)
                        .frame(width: sidebarWidth)
                        .transition(.move(edge: .leading))

                    Divider()
                        .transition(.move(edge: .leading))
                }

                // Center pane(s)
                CenterPaneArea(showSidebar: $showSidebar, showInspector: $showInspector)
                    .frame(maxWidth: .infinity)

                // Right inspector
                if showInspector {
                    Divider()
                        .transition(.move(edge: .trailing))

                    InspectorRouter(showInspector: $showInspector)
                        .frame(width: inspectorWidth)
                        .transition(.move(edge: .trailing))
                }
            }
        }
        .ignoresSafeArea(.all, edges: .top)
        .themedBackground(Color.appWindowBackground)
        .background {
            WindowAccessor(title: appState.windowTitle)
            FileCreationShortcutMonitor(
                onNewFile: { appState.promptCreateFile() },
                onNewFolder: { appState.promptCreateDirectory() }
            )
        }
        .overlay(alignment: .bottom) {
            if let message = appState.toastMessage {
                ToastView(message: message)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                            withAnimation { appState.toastMessage = nil }
                        }
                    }
                    .padding(.bottom, 24)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: appState.toastMessage)
        .alert(
            "File Changed on Disk",
            isPresented: .init(
                get: { appState.fileConflictFileId != nil },
                set: { if !$0 { appState.fileConflictFileId = nil } }
            )
        ) {
            Button("Reload") {
                if let id = appState.fileConflictFileId {
                    appState.reloadFileFromDisk(fileId: id)
                }
                appState.fileConflictFileId = nil
            }
            Button("Keep My Changes", role: .cancel) {
                appState.fileConflictFileId = nil
            }
        } message: {
            Text("This file has been modified externally. Do you want to reload it and discard your changes?")
        }
    }
}

// MARK: - Center Pane Area
// Hosts a single TerminalTabView for primary, or two side-by-side when the
// secondary main pane is open. Clicking inside a pane sets the active pane.

private struct CenterPaneArea: View {
    @Environment(AppState.self) private var appState
    @Binding var showSidebar: Bool
    @Binding var showInspector: Bool
    @AppStorage("secondaryPaneFraction") private var secondaryPaneFraction: Double = 0.5
    @State private var liveFraction: Double?
    @State private var dropTargetPane: PaneID?
    @State private var availableWidth: CGFloat = 0

    private let dividerWidth: CGFloat = 6

    var body: some View {
        if appState.secondaryPane != nil {
            // The pane widths are resolved by `SplitPaneLayout` inside the same
            // layout pass, from the bounds SwiftUI actually hands the container.
            // Earlier versions measured the width with a GeometryReader and fed
            // it back through @State: that update lands one frame after the
            // available width changes (inserting / removing the right
            // inspector), so the panes briefly kept their old fixed widths and
            // bled under the inspector or left a gap.
            let fraction = liveFraction ?? secondaryPaneFraction
            SplitPaneLayout(fraction: fraction, dividerWidth: dividerWidth) {
                paneContainer(.primary)

                PaneDivider(
                    usableWidth: max(1, availableWidth - dividerWidth),
                    committedFraction: $secondaryPaneFraction,
                    liveFraction: $liveFraction
                )

                paneContainer(.secondary)
            }
            // Width is still measured, but only to convert divider drag deltas
            // into a fraction; it never drives the layout itself.
            .background(widthReader)
            .clipped()
        } else {
            paneContainer(.primary)
        }
    }

    // Measures the container width for the divider's drag math.
    private var widthReader: some View {
        GeometryReader { proxy in
            Color.clear
                .preference(key: PaneAreaWidthKey.self, value: proxy.size.width)
        }
        .onPreferenceChange(PaneAreaWidthKey.self) { width in
            if availableWidth != width {
                availableWidth = width
            }
        }
    }

    @ViewBuilder
    private func paneContainer(_ paneId: PaneID) -> some View {
        TerminalTabView(
            showSidebar: $showSidebar,
            showInspector: $showInspector,
            paneId: paneId
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(
            Rectangle()
                .inset(by: 0.5)
                .stroke(
                    appState.activePaneId == paneId && appState.secondaryPane != nil
                        ? Color.accentColor.opacity(0.5)
                        : Color.clear,
                    lineWidth: 1
                )
                .allowsHitTesting(false)
        )
        // Cross-pane drop zone highlight
        .overlay {
            if dropTargetPane == paneId {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.accentColor.opacity(0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.accentColor, lineWidth: 2)
                    )
                    .padding(2)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: dropTargetPane)
        // Clip each pane to its own SwiftUI frame. The terminal / editor are
        // NSView-backed; without clipping their layers bleed past the animated
        // frame during a live divider drag — overflowing into the sidebar and
        // leaving stale border-stroke pixels (ghost lines) behind.
        .clipped()
        .contentShape(Rectangle())
        .simultaneousGesture(
            TapGesture().onEnded {
                if appState.activePaneId != paneId {
                    appState.activePaneId = paneId
                }
            }
        )
        .onDrop(of: [.text], delegate: PaneMoveDropDelegate(
            targetPaneId: paneId,
            appState: appState,
            dropTargetPane: $dropTargetPane
        ))
    }
}

// MARK: - Split Pane Layout

/// Places [primary, divider, secondary] horizontally. The primary pane takes
/// `fraction` of the usable width (clamped so both panes keep a minimum),
/// the secondary pane gets whatever remains. Widths are derived from the
/// bounds given to `placeSubviews`, so a change in available width (e.g. the
/// inspector opening) is reflected in the very same layout pass.
private struct SplitPaneLayout: Layout {
    var fraction: Double
    var dividerWidth: CGFloat
    static let minPaneWidth: CGFloat = 160

    static func primaryWidth(usable: CGFloat, fraction: Double) -> CGFloat {
        let minW = min(minPaneWidth, usable / 2)
        return max(minW, min(usable - minW, usable * fraction)).rounded()
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 3 else { return }
        let usable = max(0, bounds.width - dividerWidth)
        let primaryWidth = Self.primaryWidth(usable: usable, fraction: fraction)
        let secondaryWidth = max(0, usable - primaryWidth)
        let height = bounds.height
        var x = bounds.minX

        subviews[0].place(
            at: CGPoint(x: x, y: bounds.minY),
            anchor: .topLeading,
            proposal: ProposedViewSize(width: primaryWidth, height: height)
        )
        x += primaryWidth
        subviews[1].place(
            at: CGPoint(x: x, y: bounds.minY),
            anchor: .topLeading,
            proposal: ProposedViewSize(width: dividerWidth, height: height)
        )
        x += dividerWidth
        subviews[2].place(
            at: CGPoint(x: x, y: bounds.minY),
            anchor: .topLeading,
            proposal: ProposedViewSize(width: secondaryWidth, height: height)
        )
    }
}

// MARK: - Pane Area Width Preference

private struct PaneAreaWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

// MARK: - Cross-Pane Tab Drop Delegate

private struct PaneMoveDropDelegate: DropDelegate {
    let targetPaneId: PaneID
    let appState: AppState
    @Binding var dropTargetPane: PaneID?

    func validateDrop(info: DropInfo) -> Bool {
        // Only accept when split is active and dragging from the other pane
        guard appState.secondaryPane != nil,
              let source = appState.draggingTabSourcePane,
              source != targetPaneId else { return false }
        return true
    }

    func dropEntered(info: DropInfo) {
        guard appState.draggingTabSourcePane != targetPaneId else { return }
        dropTargetPane = targetPaneId
    }

    func dropExited(info: DropInfo) {
        if dropTargetPane == targetPaneId {
            dropTargetPane = nil
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard appState.draggingTabSourcePane != targetPaneId else {
            return DropProposal(operation: .cancel)
        }
        return DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        dropTargetPane = nil
        defer { appState.draggingTabSourcePane = nil }

        guard let provider = info.itemProviders(for: [.text]).first else { return false }

        provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let uuidString = object as? String,
                  let uuid = UUID(uuidString: uuidString) else { return }

            Task { @MainActor in
                if appState.activeSessions.contains(where: { $0.id == uuid && $0.paneId != targetPaneId }) {
                    appState.moveSession(sessionId: uuid, toPane: targetPaneId)
                } else if appState.openFiles.contains(where: { $0.id == uuid && $0.paneId != targetPaneId }) {
                    appState.moveOpenFile(fileId: uuid, toPane: targetPaneId)
                }
            }
        }
        return true
    }
}

private struct PaneDivider: View {
    let usableWidth: CGFloat
    @Binding var committedFraction: Double
    @Binding var liveFraction: Double?
    @State private var dragStartFraction: Double?

    var body: some View {
        Rectangle()
            .fill(Color.gray.opacity(0.001))
            .frame(width: 6)
            .overlay(Divider())
            .contentShape(Rectangle())
            .onHover { hovering in
                if hovering {
                    NSCursor.resizeLeftRight.push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if dragStartFraction == nil {
                            dragStartFraction = committedFraction
                        }
                        let delta = value.translation.width / max(1, usableWidth)
                        let newFraction = (dragStartFraction ?? committedFraction) + Double(delta)
                        liveFraction = max(0.15, min(0.85, newFraction))
                    }
                    .onEnded { _ in
                        if let final = liveFraction {
                            committedFraction = final
                        }
                        liveFraction = nil
                        dragStartFraction = nil
                    }
            )
    }
}

// MARK: - Inspector Router
// Isolated view so ContentView does not subscribe to inspectorTarget
// (which reads selectedAgentId / selectedSkillId).

private struct InspectorRouter: View {
    @Environment(AppState.self) private var appState
    @Binding var showInspector: Bool

    var body: some View {
        switch appState.inspectorTarget {
        case .skill:
            SkillInspectorView(showInspector: $showInspector)
        case .agent, .none:
            AgentInspectorView(showInspector: $showInspector)
        }
    }
}

// MARK: - Toast View

private struct ToastView: View {
    let message: String

    var body: some View {
        #if DEBUG
        let _ = Self._printChanges()
        #endif
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text(message)
                .font(.system(size: 13, weight: .medium))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
        .shadow(color: .appShadow, radius: 8, y: 4)
    }
}
