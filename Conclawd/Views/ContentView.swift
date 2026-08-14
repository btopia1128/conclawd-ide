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
                canCreate: appState.selectedProject != nil,
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
            // Width comes from a background measurement (see `widthReader`)
            // rather than from a container `GeometryReader`. A container reader
            // reports a stale width when a sibling (the right inspector) is
            // inserted/removed with an animated transition, which made the
            // secondary pane bleed under the inspector on open and leave a
            // blank gap on close. The resolved background size always reflects
            // the real available width.
            let usable = max(1, availableWidth - dividerWidth)
            let fraction = liveFraction ?? secondaryPaneFraction
            let primaryWidth = max(160, min(usable - 160, usable * fraction)).rounded()
            let secondaryWidth = max(0, usable - primaryWidth)
            // The width is measured from a clear container view that is pinned to
            // the real available space (`maxWidth: .infinity`), NOT from the pane
            // HStack. The HStack sizes itself to its fixed-width children, so
            // measuring it would feed its (possibly overflowing) content width
            // back into `availableWidth` — a self-reinforcing loop that, once the
            // right inspector opens and shrinks the container, leaves the panes
            // too wide so they bleed over and clip the inspector. Measuring the
            // clear container instead always reflects the true available width.
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(widthReader)
                .overlay(alignment: .leading) {
                    HStack(spacing: 0) {
                        paneContainer(.primary)
                            .frame(width: primaryWidth)

                        PaneDivider(
                            usableWidth: usable,
                            committedFraction: $secondaryPaneFraction,
                            liveFraction: $liveFraction
                        )

                        paneContainer(.secondary)
                            .frame(width: secondaryWidth)
                    }
                }
                .clipped()
        } else {
            paneContainer(.primary)
        }
    }

    // Measures the real container width and feeds it back via a preference so
    // the split ratio always tracks the current available space.
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
