import SwiftUI
import SwiftTerm
import UniformTypeIdentifiers

/// Background color matching the current terminal theme.
private var terminalBackground: SwiftUI.Color {
    SwiftUI.Color(nsColor: TerminalTheme.current.background)
}

/// Displays terminal tabs for running agent sessions, parameterized by which
/// main pane (primary/secondary) it belongs to.
struct TerminalTabView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.l10n) private var l10n
    @Binding var showSidebar: Bool
    @Binding var showInspector: Bool
    /// Which main pane this view instance belongs to. Defaults to `.primary`
    /// so existing call sites work without modification.
    var paneId: PaneID = .primary

    /// Read-only access to this view's pane state.
    private var pane: PaneState { appState.pane(paneId) }

    /// Sessions owned by this pane.
    private var paneSessions: [AgentSession] {
        appState.activeSessions.filter { $0.paneId == paneId }
    }

    /// Sessions sorted for tab display, filtered to this pane.
    private var paneSortedSessions: [AgentSession] {
        appState.sortedActiveSessions.filter { $0.paneId == paneId }
    }

    /// Open files owned by this pane.
    private var paneOpenFiles: [OpenFile] {
        appState.openFiles.filter { $0.paneId == paneId }
    }

    /// Whether this pane has any open files.
    private var paneFileEditorTabOpen: Bool { !paneOpenFiles.isEmpty }

    // Org chart state (owned here so tab bar can show controls)
    @State private var orgChartViewModel = OrgChartViewModel()
    @State private var orgChartFilter: OrgChartFilter = .project
    @State private var orgChartShowGlobalAgents = true

    // Tab rename state
    @State private var renamingSessionId: UUID?
    @State private var renameText: String = ""
    @FocusState private var isRenameFieldFocused: Bool

    // Drag reorder state
    @State private var draggingSessionId: UUID?
    @State private var draggingFileId: UUID?

    /// The session ID to display in the terminal.
    private var displayedSessionId: UUID? {
        if let sessionId = pane.selectedSessionId,
           paneSessions.contains(where: { $0.id == sessionId }) {
            return sessionId
        }
        return paneSessions.last?.id
    }

    /// The session object currently displayed.
    private var displayedSession: AgentSession? {
        guard let id = displayedSessionId else { return nil }
        return paneSessions.first { $0.id == id }
    }

    /// The agent selected in THIS pane (not the forwarding accessor).
    private var paneSelectedAgent: Agent? {
        guard let agentId = pane.selectedAgentId else { return nil }
        return appState.agents.first { $0.id == agentId }
    }

    /// Whether the selected agent has no active sessions (needs a Start button).
    private var selectedAgentNeedsStart: Bool {
        guard let agentId = pane.selectedAgentId else { return false }
        // If the user explicitly selected a session, don't overlay a different agent's start screen
        if let selectedId = pane.selectedSessionId,
           paneSessions.contains(where: { $0.id == selectedId }) {
            return false
        }
        let hasSession = paneSessions.contains { $0.agentId == agentId }
        return !hasSession
    }

    private var showingOrgChart: Bool {
        pane.centerPane == .orgChart
    }

    private var isShowingAgentEditor: Bool {
        pane.centerPane == .agentEditor
    }

    private var isShowingSettings: Bool {
        pane.centerPane == .settings
    }

    private var isShowingSkillEditor: Bool {
        pane.centerPane == .skillEditor
    }

    private var isShowingScheduleEditor: Bool {
        pane.centerPane == .scheduleEditor
    }

    private var isShowingFileEditor: Bool {
        pane.centerPane == .fileEditor
    }

    /// True when the terminal content is the active center pane.
    private var isShowingTerminal: Bool {
        pane.centerPane == .terminal
    }

    var body: some View {
        #if DEBUG
        let _ = Self._printChanges()
        #endif
        VStack(spacing: 0) {
            tabBar

            Divider()

            ZStack {
                // Terminal / Chat / empty state (base layer — stable structure to avoid AttributeGraph cycles)
                let hasChat = !showingOrgChart && displayedSession?.displayMode == .chat
                let hasTerminal = !showingOrgChart && !hasChat && !paneSessions.isEmpty
                let hasAgentStart = !showingOrgChart && !hasChat && !hasTerminal && paneSelectedAgent != nil
                let hasNoSelection = !showingOrgChart && !hasChat && !hasTerminal && !hasAgentStart

                terminalContent
                    .opacity(hasTerminal ? 1 : 0)
                    .allowsHitTesting(hasTerminal)

                if let session = displayedSession, session.displayMode == .chat {
                    chatContent(sessionId: session.id)
                        .opacity(hasChat ? 1 : 0)
                        .allowsHitTesting(hasChat)
                }

                if let agent = paneSelectedAgent {
                    selectedButNotStarted(agent: agent)
                        .opacity(hasAgentStart ? 1 : 0)
                        .allowsHitTesting(hasAgentStart)
                }

                noSelection
                    .opacity(hasNoSelection ? 1 : 0)
                    .allowsHitTesting(hasNoSelection)

                // Org chart (kept alive while tab is open)
                if pane.orgChartTabOpen {
                    OrgChartView(viewModel: orgChartViewModel, filter: orgChartFilter, showGlobalAgents: $orgChartShowGlobalAgents)
                        .opacity(showingOrgChart ? 1 : 0)
                        .allowsHitTesting(showingOrgChart)
                        .task {
                            if case .project = appState.projectSelection {
                                orgChartFilter = .project
                            } else {
                                orgChartFilter = .all
                            }
                            refreshOrgChart()
                        }
                        .onChange(of: appState.agents) { refreshOrgChart() }
                        .onChange(of: orgChartFilter) { refreshOrgChart() }
                        .onChange(of: orgChartShowGlobalAgents) { refreshOrgChart() }
                        .onChange(of: appState.projectSelection) {
                            if case .project = appState.projectSelection {
                                orgChartFilter = .project
                            } else {
                                orgChartFilter = .all
                            }
                            // refreshOrgChart() is triggered by onChange(of: orgChartFilter)
                        }
                }

                // Agent editor (kept alive while tab is open)
                if pane.agentEditorTabOpen {
                    AgentEditorView()
                        .id("agent-editor-\(appState.editorShowLineNumbers)-\(appState.editorWordWrap)")
                        .opacity(isShowingAgentEditor ? 1 : 0)
                        .allowsHitTesting(isShowingAgentEditor)
                }

                // Skill editor (kept alive while tab is open)
                if pane.skillEditorTabOpen {
                    SkillEditorView()
                        .id("skill-editor-\(appState.editorShowLineNumbers)-\(appState.editorWordWrap)")
                        .opacity(isShowingSkillEditor ? 1 : 0)
                        .allowsHitTesting(isShowingSkillEditor)
                }

                // Schedule editor (kept alive while tab is open)
                if pane.scheduleEditorTabOpen {
                    ScheduleEditorView()
                        .opacity(isShowingScheduleEditor ? 1 : 0)
                        .allowsHitTesting(isShowingScheduleEditor)
                }

                // Settings (kept alive while tab is open)
                if pane.settingsTabOpen {
                    SettingsView()
                        .opacity(isShowingSettings ? 1 : 0)
                        .allowsHitTesting(isShowingSettings)
                }

                // File editor (kept alive while any file is open in this pane)
                if paneFileEditorTabOpen {
                    FileEditorView(paneId: paneId)
                        .id("file-editor-\(paneId)-\(appState.editorShowLineNumbers)-\(appState.editorWordWrap)")
                        .opacity(isShowingFileEditor ? 1 : 0)
                        .allowsHitTesting(isShowingFileEditor)
                }
            }
        }
    }

    private func refreshOrgChart() {
        orgChartViewModel.update(
            agents: appState.agents,
            relations: appState.relations,
            filter: orgChartFilter,
            showGlobalAgents: orgChartShowGlobalAgents
        )
    }

    /// Agent is selected in sidebar but not yet started
    private func selectedButNotStarted(agent: Agent) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "terminal")
                .font(.system(size: 48))
                .foregroundStyle(Color.appMuted)

            Text(agent.name)
                .font(.title2.bold())
                .foregroundStyle(.primary)

            if !agent.description.isEmpty {
                Text(agent.description)
                    .font(.subheadline)
                    .foregroundStyle(Color.appMuted)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 300)
            }

            Button {
                appState.startAgent(agent)
            } label: {
                Label("Start Agent", systemImage: "terminal")
                    .font(.body.bold())
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(terminalBackground)
        .onHover { hovering in
            if hovering {
                NSCursor.arrow.push()
            } else {
                NSCursor.pop()
            }
        }
    }

    /// Nothing selected at all
    private var noSelection: some View {
        VStack(spacing: 12) {
            Image(systemName: "terminal")
                .font(.system(size: 48))
                .foregroundStyle(Color.appIconMuted)
            Text(l10n.noAgentSelected)
                .font(.headline)
                .foregroundStyle(Color.appMuted)
            Text(l10n.selectAgentToStart)
                .font(.subheadline)
                .foregroundStyle(Color.appSubtle)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(terminalBackground)
    }

    // MARK: - Tab Bar

    @State private var showFileMenu = false

    /// Whether any secondary (swappable) tabs exist in this pane.
    private var hasSecondaryTabs: Bool {
        pane.scheduleEditorTabOpen
    }

    // MARK: - Editor Tab Builders (sorted / unsorted)

    @ViewBuilder
    private var fileEditorTabs: some View {
        ForEach(paneOpenFiles) { file in
            editorTab(
                icon: fileTabIcon(for: file),
                iconColor: fileTabColor(for: file),
                name: file.fileName,
                hasChanges: file.hasChanges,
                isSelected: isShowingFileEditor && pane.selectedFileId == file.id,
                onTap: {
                    appState.updatePane(paneId) {
                        $0.selectedFileId = file.id
                        $0.centerPane = .fileEditor
                    }
                },
                onClose: { appState.closeFileTab(fileId: file.id) }
            )
            .opacity(draggingFileId == file.id ? 0.5 : 1.0)
            .onDrag {
                draggingFileId = file.id
                appState.draggingTabSourcePane = paneId
                return NSItemProvider(object: file.id.uuidString as NSString)
            }
        }
    }

    @ViewBuilder
    private var otherEditorTabs: some View {
        // Org chart tab
        if pane.orgChartTabOpen {
            editorTab(
                icon: "rectangle.3.group",
                iconColor: .green,
                name: l10n.orgChart,
                isSelected: showingOrgChart,
                onTap: { appState.updatePane(paneId) { $0.centerPane = .orgChart } },
                onClose: {
                    appState.updatePane(paneId) {
                        $0.orgChartTabOpen = false
                        if $0.centerPane == .orgChart {
                            $0.centerPane = .terminal
                        }
                    }
                }
            )
        }

        // Agent editor tab
        if pane.agentEditorTabOpen, let name = pane.agentEditorTabName {
            editorTab(
                icon: "pencil.line",
                iconColor: .orange,
                name: name,
                isSelected: isShowingAgentEditor,
                onTap: {
                    appState.updatePane(paneId) { $0.centerPane = .agentEditor }
                    // Restore selectedAgentId so the inspector shows agent info
                    if pane.selectedAgentId == nil, let agent = appState.editingAgent {
                        appState.updatePane(paneId) {
                            $0.selectedSkillId = nil
                            $0.selectedAgentId = agent.id
                        }
                    }
                },
                onClose: { appState.closeAgentEditor() }
            )
        }

        // Skill editor tab
        if pane.skillEditorTabOpen, let name = pane.skillEditorTabName {
            editorTab(
                icon: "book.closed.fill",
                iconColor: .purple,
                name: name,
                isSelected: isShowingSkillEditor && pane.viewingBundledFileURL == nil,
                onTap: {
                    appState.closeBundledFile()
                    appState.updatePane(paneId) { $0.centerPane = .skillEditor }
                    // Restore selectedSkillId so the inspector shows skill info
                    if pane.selectedSkillId == nil, let skill = appState.editingSkill {
                        appState.updatePane(paneId) {
                            $0.selectedAgentId = nil
                            $0.selectedSkillId = skill.id
                        }
                    }
                },
                onClose: { appState.closeSkillEditor() }
            )

            // Bundled file tab
            if isShowingSkillEditor, let fileURL = pane.viewingBundledFileURL {
                editorTab(
                    icon: "doc.text",
                    iconColor: .appSecondary,
                    name: fileURL.lastPathComponent,
                    isSelected: true,
                    onClose: { appState.closeBundledFile() }
                )
            }
        }

        // Schedule editor tab
        if isShowingScheduleEditor, let name = pane.scheduleEditorTabName {
            editorTab(
                icon: "clock",
                iconColor: .cyan,
                name: name,
                isSelected: true,
                onClose: { appState.closeScheduleEditor() }
            )
        }

        // Settings tab
        if pane.settingsTabOpen {
            editorTab(
                icon: "gearshape",
                iconColor: .appSecondary,
                name: l10n.settings,
                isSelected: isShowingSettings,
                onTap: { appState.updatePane(paneId) { $0.centerPane = .settings } },
                onClose: {
                    appState.updatePane(paneId) {
                        $0.settingsTabOpen = false
                        if $0.centerPane == .settings {
                            $0.centerPane = .terminal
                        }
                    }
                }
            )
        }
    }

    private var tabBar: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    if appState.isTabSortEnabled {
                        // Sorted: agent sessions → shell sessions → file editors → other editors
                        ForEach(Array(paneSortedSessions.enumerated()), id: \.element.id) { index, session in
                            let isSelected = isShowingTerminal && displayedSessionId == session.id
                            tabButton(session: session, isSelected: isSelected, tabIndex: index + 1)
                        }
                        fileEditorTabs
                        otherEditorTabs
                    } else {
                        // Original order: sessions then editors as opened
                        ForEach(Array(paneSessions.enumerated()), id: \.element.id) { index, session in
                            let isSelected = isShowingTerminal && displayedSessionId == session.id
                            tabButton(session: session, isSelected: isSelected, tabIndex: index + 1)
                        }
                        otherEditorTabs
                        fileEditorTabs
                    }
                }
                .padding(.horizontal, 4)
            }

            Spacer()

            // Tab sort toggle button
            tabSortButton
                .padding(.trailing, hasSecondaryTabs ? 0 : 8)

            // Secondary tabs dropdown (3-dot button)
            if hasSecondaryTabs {
                secondaryTabMenu
                    .padding(.trailing, 8)
            }
        }
        .frame(height: 32)
        .themedBackground(Color.appSurface)
    }

    // MARK: - Secondary Tab Menu

    private var secondaryTabMenu: some View {
        Menu {
            // Schedule editor entry
            if pane.scheduleEditorTabOpen, let name = pane.scheduleEditorTabName {
                Button {
                    appState.updatePane(paneId) { $0.centerPane = .scheduleEditor }
                } label: {
                    HStack {
                        Image(systemName: "clock")
                        Text(name)
                        if isShowingScheduleEditor {
                            Spacer()
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }

            Divider()

            // Close all secondary tabs
            Button(role: .destructive) {
                if pane.scheduleEditorTabOpen {
                    appState.closeScheduleEditor()
                }
            } label: {
                Label(l10n.closeAll, systemImage: "xmark.circle")
            }
        } label: {
            Image(systemName: "chevron.down")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.appSecondary)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .pointingHandCursor()
    }

    // MARK: - Tab Sort Button

    private var tabSortButton: some View {
        Button {
            withAnimation(.default) {
                appState.isTabSortEnabled.toggle()
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(appState.isTabSortEnabled ? Color.accentColor : Color.appSecondary)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
    }

    // MARK: - Editor Tab

    private func editorTab(
        icon: String,
        iconColor: SwiftUI.Color,
        name: String,
        hasChanges: Bool = false,
        isSelected: Bool = true,
        onTap: (() -> Void)? = nil,
        onClose: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 8))
                .foregroundStyle(iconColor)

            Text(name)
                .font(.system(size: 12))
                .lineLimit(1)

            if hasChanges {
                Circle()
                    .fill(Color.primary)
                    .frame(width: 5, height: 5)
            }

            Button {
                onClose()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Color.appSecondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(isSelected ? SwiftUI.Color.accentColor.opacity(0.15) : SwiftUI.Color.clear)
        .cornerRadius(6)
        .contentShape(Rectangle())
        .onTapGesture {
            onTap?()
        }
    }

    // MARK: - Terminal Content

    private var isShowingCreationSession: Bool {
        guard let sessionId = displayedSessionId else { return false }
        return appState.activeSessions.first(where: { $0.id == sessionId })?.isCreationSession == true
    }

    /// Whether the currently displayed session is stopped and can be resumed.
    private var canResumeDisplayedSession: Bool {
        guard let sessionId = displayedSessionId else { return false }
        return !appState.processManager.isRunning(sessionId: sessionId)
            && appState.canResumeSession(sessionId: sessionId)
    }

    private var terminalContent: some View {
        Group {
            if selectedAgentNeedsStart, let agent = paneSelectedAgent {
                ZStack {
                    TerminalHostRepresentable(
                        selectedSessionId: displayedSessionId,
                        processManager: appState.processManager
                    )
                    .opacity(0.3)

                    VStack(spacing: 12) {
                        Image(systemName: "terminal")
                            .font(.system(size: 36))
                            .foregroundStyle(Color.appMuted)
                        Text(agent.name)
                            .font(.title3.bold())
                            .foregroundStyle(.primary)
                        Button {
                            appState.startAgent(agent)
                        } label: {
                            Label(l10n.startAgent, systemImage: "play.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(terminalBackground.opacity(0.85))
                }
            } else {
                VStack(spacing: 0) {
                    if isShowingCreationSession {
                        creationSessionBanner
                    }

                    TerminalHostRepresentable(
                        selectedSessionId: displayedSessionId,
                        processManager: appState.processManager
                    )
                    .overlay(alignment: .bottomTrailing) {
                        attachFileButton
                            .padding(.bottom, 8)
                            .padding(.trailing, 20)
                    }

                    if isExtractingMemory {
                        memorySavingBanner
                    } else if canResumeDisplayedSession {
                        resumeBanner
                    }
                }
            }
        }
    }

    // MARK: - Attach File

    private var attachFileButton: some View {
        Button {
            openFileAttachPanel()
        } label: {
            Image(systemName: "paperclip")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .background(.ultraThinMaterial)
                .cornerRadius(6)
        }
        .buttonStyle(.plain)
        .help(l10n.attachFile)
    }

    private func openFileAttachPanel() {
        guard let sessionId = displayedSessionId else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.message = l10n.attachFile

        if panel.runModal() == .OK {
            for url in panel.urls {
                let path = url.path(percentEncoded: false)
                appState.processManager.sendPasteInput(sessionId: sessionId, text: path)
            }
        }
    }

    // MARK: - Memory Saving Banner

    private var isExtractingMemory: Bool {
        guard let sessionId = displayedSessionId else { return false }
        return appState.memoryExtractingSessions.contains(sessionId)
    }

    private var memorySavingBanner: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)

            Text("Saving memories...")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.purple.opacity(0.08))
    }

    // MARK: - Resume Banner

    private var resumeBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.clockwise")
                .foregroundStyle(.orange)

            Text(l10n.sessionStopped)
                .font(.system(size: 12, weight: .medium))

            Spacer()

            Button {
                if let sessionId = displayedSessionId {
                    appState.resumeSession(sessionId: sessionId)
                }
            } label: {
                Label(l10n.resume, systemImage: "play.fill")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.1))
    }

    // MARK: - Creation Session Banner

    private var creationBannerText: String {
        if appState.creationSession?.isSkillCreation == true {
            return l10n.describeSkillToCreate
        }
        return l10n.describeAgentToCreate
    }

    private var creationBannerExample: String {
        if appState.creationSession?.isSkillCreation == true {
            return l10n.skillCreationExample
        }
        return l10n.agentCreationExample
    }

    private var creationSessionBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .foregroundStyle(.purple)

            Text(creationBannerText)
                .font(.system(size: 12, weight: .medium))

            Spacer()

            Text(creationBannerExample)
                .font(.system(size: 11))
                .foregroundStyle(Color.appSecondary)

            Button(l10n.cancel) {
                appState.endCreationSession()
            }
            .controlSize(.small)
            .buttonStyle(.bordered)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.purple.opacity(0.1))
    }

    // MARK: - Chat Content

    private func chatContent(sessionId: UUID) -> some View {
        Group {
            if let chatManager = appState.chatManagers[sessionId] {
                ChatView(chatManager: chatManager)
            } else {
                Text("Chat session not found")
                    .foregroundStyle(Color.appMuted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    // MARK: - Tab Button

    private func tabButton(session: AgentSession, isSelected: Bool, tabIndex: Int? = nil) -> some View {
        let displayName = sessionDisplayName(session)
        let isChatMode = session.displayMode == .chat
        let status = isChatMode
            ? (appState.chatManagers[session.id]?.isProcessing == true ? AgentProcessStatus.running : .waitingForInput)
            : appState.processManager.status(sessionId: session.id)
        let isRenaming = renamingSessionId == session.id

        return HStack(spacing: 6) {
            if session.isCreationSession {
                Image(systemName: "sparkles")
                    .font(.system(size: 8))
                    .foregroundStyle(.purple)
            } else if session.isShellSession {
                Image(systemName: "apple.terminal")
                    .font(.system(size: 10))
                    .foregroundStyle(.green)
            } else if isChatMode {
                Image(systemName: "bubble.left.and.bubble.right")
                    .font(.system(size: 9))
                    .foregroundStyle(Color.accentColor)
            } else {
                Image(systemName: statusIcon(for: session.id))
                    .font(.system(size: 10))
                    .foregroundStyle(statusColor(for: session.id))
                    .symbolEffect(.pulse, options: .repeating, isActive: status == .running)
            }

            if isRenaming {
                TextField(l10n.tabName, text: $renameText)
                    .font(.system(size: 12))
                    .textFieldStyle(.plain)
                    .frame(minWidth: 60, maxWidth: 150)
                    .focused($isRenameFieldFocused)
                    .onSubmit { commitRename() }
                    .onExitCommand { renamingSessionId = nil; renameText = "" }
                    .onChange(of: isRenameFieldFocused) { _, focused in
                        if !focused { commitRename() }
                    }
                    .onAppear { isRenameFieldFocused = true }
            } else {
                Text(displayName)
                    .font(.system(size: 12))
                    .lineLimit(1)
            }

            if !isRenaming, let idx = tabIndex, idx <= 9 {
                Text("⌘\(idx)")
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.appTertiary)
            }

            Button {
                appState.closeTab(sessionId: session.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Color.appSecondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
        .cornerRadius(6)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            guard !session.isCreationSession else { return }
            renameText = session.customName ?? sessionDisplayName(session)
            renamingSessionId = session.id
        }
        .onTapGesture(count: 1) {
            appState.updatePane(paneId) {
                $0.selectedSessionId = session.id
                $0.centerPane = .terminal
            }
            // Also select the agent for inspector (filePath fallback for reloadAgents UUID changes)
            if !session.isCreationSession {
                let agent = appState.agents.first(where: { $0.id == session.agentId })
                    ?? appState.agents.first(where: {
                        session.agentFilePath != nil && $0.filePath?.path(percentEncoded: false) == session.agentFilePath
                    })
                if let agent {
                    appState.selectAgent(agent)
                } else {
                    appState.updatePane(paneId) { $0.selectedAgentId = nil }
                }
            }
        }
        .contextMenu {
            if !session.isCreationSession {
                Button(l10n.rename) {
                    renameText = session.customName ?? sessionDisplayName(session)
                    renamingSessionId = session.id
                }
            }

            // Move-to-other-pane (only when split is open)
            if appState.secondaryPane != nil {
                let target: PaneID = paneId == .primary ? .secondary : .primary
                Button("Move to Other Pane") {
                    appState.moveSession(sessionId: session.id, toPane: target)
                }
            }

            if !session.isShellSession {
                if !appState.processManager.isRunning(sessionId: session.id)
                    && appState.canResumeSession(sessionId: session.id) {
                    Button(l10n.resume) {
                        appState.resumeSession(sessionId: session.id)
                    }
                }

                let otherSessions = appState.otherActiveSessions(excluding: session.id)
                if !otherSessions.isEmpty {
                    Menu(l10n.shareContext) {
                        ForEach(otherSessions, id: \.id) { target in
                            Button(target.agentName) {
                                appState.shareContext(from: session.id, to: target.id)
                            }
                        }
                    }
                }

                if !session.isCreationSession {
                    Button(l10n.duplicate) {
                        appState.duplicateSession(sessionId: session.id)
                    }
                }
            }

            Divider()

            Button(l10n.close) {
                appState.closeTab(sessionId: session.id)
            }
        }
        .opacity(draggingSessionId == session.id ? 0.5 : 1.0)
        .onDrag {
            guard !appState.isTabSortEnabled else { return NSItemProvider() }
            draggingSessionId = session.id
            appState.draggingTabSourcePane = paneId
            return NSItemProvider(object: session.id.uuidString as NSString)
        }
        .onDrop(of: [UTType.text], delegate: TabReorderDropDelegate(
            targetId: session.id,
            draggingId: $draggingSessionId,
            reorder: { fromId, toId in
                guard !appState.isTabSortEnabled else { return }
                reorderSessions(from: fromId, to: toId)
            }
        ))
    }

    /// Returns display name with session number if multiple sessions exist for the same agent.
    private func sessionDisplayName(_ session: AgentSession) -> String {
        if let customName = session.customName { return customName }
        if session.isCreationSession { return session.agentName }

        let sameAgentSessions = appState.activeSessions.filter {
            $0.agentId == session.agentId && !$0.isCreationSession
        }
        if sameAgentSessions.count > 1,
           let index = sameAgentSessions.firstIndex(where: { $0.id == session.id }) {
            return "\(session.agentName) #\(index + 1)"
        }
        return session.agentName
    }

    private func commitRename() {
        if let id = renamingSessionId {
            appState.renameSession(sessionId: id, name: renameText)
        }
        renamingSessionId = nil
        renameText = ""
    }

    private func sessionStatus(for sessionId: UUID) -> AgentProcessStatus {
        if let session = appState.activeSessions.first(where: { $0.id == sessionId }),
           session.displayMode == .chat {
            return appState.chatManagers[sessionId]?.isProcessing == true ? .running : .waitingForInput
        }
        return appState.processManager.status(sessionId: sessionId)
    }

    private func statusIcon(for sessionId: UUID) -> String {
        switch sessionStatus(for: sessionId) {
        case .running: return "bolt.fill"
        case .waitingForInput: return "checkmark.circle.fill"
        case .stopped: return "stop.circle"
        }
    }

    private func statusColor(for sessionId: UUID) -> SwiftUI.Color {
        switch sessionStatus(for: sessionId) {
        case .running: return .statusRunning
        case .waitingForInput: return .statusReady
        case .stopped: return .statusStopped
        }
    }

    // MARK: - Tab Reorder

    private func reorderSessions(from sourceId: UUID, to targetId: UUID) {
        guard let fromIndex = appState.activeSessions.firstIndex(where: { $0.id == sourceId }),
              let toIndex = appState.activeSessions.firstIndex(where: { $0.id == targetId }) else { return }
        withAnimation(.default) {
            appState.activeSessions.move(
                fromOffsets: IndexSet(integer: fromIndex),
                toOffset: toIndex > fromIndex ? toIndex + 1 : toIndex
            )
        }
    }

    private func reorderFiles(from sourceId: UUID, to targetId: UUID) {
        guard let fromIndex = appState.openFiles.firstIndex(where: { $0.id == sourceId }),
              let toIndex = appState.openFiles.firstIndex(where: { $0.id == targetId }) else { return }
        withAnimation(.default) {
            appState.openFiles.move(
                fromOffsets: IndexSet(integer: fromIndex),
                toOffset: toIndex > fromIndex ? toIndex + 1 : toIndex
            )
        }
    }

    private func fileTabIcon(for file: OpenFile) -> String {
        switch file.kind {
        case .image: return "photo"
        case .video: return "play.rectangle"
        case .text: return "doc.text"
        }
    }

    private func fileTabColor(for file: OpenFile) -> SwiftUI.Color {
        switch file.kind {
        case .image: return .green
        case .video: return .purple
        case .text: break
        }
        switch file.fileExtension.lowercased() {
        case "swift": return .orange
        case "ts", "tsx", "mts": return .blue
        case "js", "mjs", "cjs", "jsx": return .yellow
        case "py": return .green
        case "md", "markdown": return .cyan
        case "json": return .purple
        case "html", "htm": return .red
        case "css", "scss": return .pink
        default: return .appSecondary
        }
    }
}

// MARK: - Tab Reorder Drop Delegate

private struct TabReorderDropDelegate: DropDelegate {
    let targetId: UUID
    @Binding var draggingId: UUID?
    let reorder: (UUID, UUID) -> Void

    func performDrop(info: DropInfo) -> Bool {
        draggingId = nil
        return true
    }

    func dropEntered(info: DropInfo) {
        guard let dragging = draggingId, dragging != targetId else { return }
        reorder(dragging, targetId)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func validateDrop(info: DropInfo) -> Bool {
        draggingId != nil
    }
}
