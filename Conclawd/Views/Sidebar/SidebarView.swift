import SwiftUI

/// Wraps sheet parameters so `.sheet(item:)` always receives fresh values.
struct PresetSheetConfig<P>: Identifiable {
    let id = UUID()
    var editing: P?
    var saveFromSession: AgentSession?
}

/// Sidebar showing all agents, styled to match the right inspector pane.
struct SidebarView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.l10n) private var l10n
    @Binding var showSidebar: Bool
    @State private var showingNewAgent = false
    @State private var showingNewSkill = false
    @State private var showingSkillUsageStats = false
    /// Non-nil while the AI-assisted creation sheet is up, carrying its target.
    @State private var aiCreationKind: AICreationKind?
    @State private var showingNewSchedule = false
    @State private var agentToDelete: Agent?
    @State private var skillToDelete: Skill?
    @State private var scheduleToDelete: AgentSchedule?
    @State private var scheduleToEdit: AgentSchedule?
    @State private var selectedScheduleId: UUID?
    @State private var selectedCloudTriggerId: String?
    @State private var showingFullHistory = false
    @State private var showingShortcuts = false
    @State private var showingNewSession = false
    /// Popover trigger for the inline "New Session" buttons in the empty states.
    @State private var showingNewSessionInlinePopover = false
    /// Popover trigger for the compact "+" new-session menu in section headers.
    @State private var showingNewSessionMenuPopover = false
    @State private var renamingSessionId: UUID?
    @State private var renameText: String = ""
    @FocusState private var isRenameFocused: Bool
    @State private var presetSheetConfig: PresetSheetConfig<ShellPreset>?
    @State private var sessionPresetSheetConfig: PresetSheetConfig<SessionPreset>?
    // Drag & drop state
    @State private var draggedAgentId: UUID?
    @State private var draggedSkillId: UUID?
    @State private var draggedPresetId: UUID?
    @State private var draggedSessionPresetId: UUID?
    @State private var draggedScheduleId: UUID?

    var body: some View {
        #if DEBUG
        let _ = Self._printChanges()
        #endif
        @Bindable var state = appState

        VStack(spacing: 0) {
            // Tab picker
            SidebarTabPicker(selectedTab: $state.sidebarTab)
                .padding(.horizontal, 12)
                .padding(.vertical, 3)
                .themedBackground(Color.appSurface)

            tabContentArea

            bottomBar
        }
        .onChange(of: appState.sidebarTab) { _, newTab in
            if newTab == .files {
                appState.loadFileTree()
            }
        }
        .modifier(SidebarSheetsModifier(
            showingNewSession: $showingNewSession,
            showingFullHistory: $showingFullHistory,
            showingNewAgent: $showingNewAgent,
            showingNewSkill: $showingNewSkill,
            showingSkillUsageStats: $showingSkillUsageStats,
            aiCreationKind: $aiCreationKind,
            showingNewSchedule: $showingNewSchedule,
            scheduleToEdit: $scheduleToEdit,
            presetSheetConfig: $presetSheetConfig,
            sessionPresetSheetConfig: $sessionPresetSheetConfig
        ))
        .modifier(SidebarAlertsModifier(
            agentToDelete: $agentToDelete,
            skillToDelete: $skillToDelete,
            scheduleToDelete: $scheduleToDelete
        ))
    }

    // MARK: - Tab Content Area

    private var tabContentArea: some View {
        ZStack {
            // FileTreeView is always in the tree to preserve scroll position
            FileTreeView()
                .opacity(appState.sidebarTab == .files ? 1 : 0)
                .allowsHitTesting(appState.sidebarTab == .files)

            // Other tabs are switched normally
            if appState.sidebarTab != .files {
                sidebarTabContent
            }
        }
    }

    // MARK: - Tab Content (non-files)

    @ViewBuilder
    private var sidebarTabContent: some View {
        switch appState.sidebarTab {
        case .agents:
            agentsList
        case .sessions:
            sessionsList
        case .skills:
            skillsList
        case .schedules:
            schedulesList
                .task {
                    if !appState.cloudTriggerService.hasFetched && !appState.cloudTriggerService.isLoading {
                        appState.loadCloudTriggers()
                    }
                }
        case .shells:
            terminalsList
        case .files:
            EmptyView()
        }
    }

    // MARK: - Agents List

    @ViewBuilder
    private var agentsList: some View {
        if appState.agents.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "person.3")
                    .font(.system(size: 24))
                    .foregroundStyle(Color.appTertiary)
                Text(l10n.noAgents)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.appSecondary)
                Text(l10n.addAgent)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.appTertiary)
                    .multilineTextAlignment(.center)

                Menu {
                    creationMenuItems(kind: .agent)
                } label: {
                    Label(l10n.newAgent, systemImage: "plus")
                        .font(.system(size: 12, weight: .medium))
                }
                .menuStyle(.borderedButton)
                .controlSize(.small)
                .padding(.top, 4)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    switch appState.projectSelection {
                    case .home:
                        // Home: user agents only (no project section)
                        EmptyView()

                    case .project:
                        agentSection(
                            "Project Agents",
                            agents: appState.projectAgents,
                            showAddMenu: true
                        )

                    case .all:
                        ForEach(Array(appState.agentsByProject.enumerated()), id: \.element.projectName) { index, group in
                            agentSection(
                                group.projectName,
                                agents: group.agents,
                                showAddMenu: index == 0
                            )
                        }
                    }

                    agentSection(
                        l10n.userGlobal,
                        agents: appState.userAgents,
                        showAddMenu: appState.projectSelection == .home
                    )

                    // Parse error warnings
                    if !appState.agentParseErrors.isEmpty {
                        parseErrorSection
                    }

                    // Relation warnings (cross-project, broken references)
                    if !appState.relationWarnings.isEmpty {
                        relationWarningSection
                    }
                }
                .padding(12)
            }
        }
    }

    // MARK: - Sessions List

    /// Sessions sorted by last meaningful interaction (most recent first), falling back to startedAt.
    /// Shell sessions are excluded here — they appear in the Terminals tab instead.
    private var sortedSessions: [AgentSession] {
        appState.activeSessions
            .filter { !$0.isShellSession }
            .sorted { a, b in
                let aTime = appState.processManager.lastInteraction[a.id] ?? a.startedAt
                let bTime = appState.processManager.lastInteraction[b.id] ?? b.startedAt
                return aTime > bTime
            }
    }

    /// History records, independent of project selection.
    private var historyRecords: [SessionRecord] {
        let activeIds = Set(appState.activeSessions.map(\.id))
        return Array(
            appState.sessionHistoryService.records
                .filter { !activeIds.contains($0.id) && $0.isResumable }
                .prefix(20)
        )
    }

    @ViewBuilder
    private var sessionsList: some View {
        let hasActive = !sortedSessions.isEmpty
        let history = historyRecords
        let hasPresets = !appState.sessionPresets.isEmpty

        if !hasActive && history.isEmpty && !hasPresets {
            VStack(spacing: 8) {
                Image(systemName: "terminal")
                    .font(.system(size: 24))
                    .foregroundStyle(Color.appTertiary)
                Text(l10n.noSessions)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.appSecondary)
                Text(l10n.startSessionToBegin)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.appTertiary)
                    .multilineTextAlignment(.center)

                if appState.agents.isEmpty && appState.sessionPresets.isEmpty {
                    // No agents or presets — single button for standalone session
                    Button {
                        appState.startStandaloneSession()
                    } label: {
                        Label(l10n.newSession, systemImage: "plus")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .menuStyle(.borderedButton)
                    .controlSize(.small)
                    .padding(.top, 4)
                } else {
                    // Has agents or presets — popover with options
                    Button {
                        showingNewSessionInlinePopover = true
                    } label: {
                        Label(l10n.newSession, systemImage: "plus")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .padding(.top, 4)
                    .popover(isPresented: $showingNewSessionInlinePopover, arrowEdge: .bottom) {
                        newSessionPopoverContent { showingNewSessionInlinePopover = false }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    // Active sessions
                    if hasActive {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("Active")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(Color.appSecondary)
                                    .textCase(.uppercase)
                                    .padding(.horizontal, 2)

                                Spacer()

                                newSessionMenu
                                    .pointingHandCursor()
                            }

                            VStack(spacing: 2) {
                                ForEach(sortedSessions, id: \.id) { session in
                                    sessionRow(session)
                                }
                            }
                        }
                    } else {
                        // No active sessions — show compact empty state
                        VStack(spacing: 6) {
                            HStack {
                                Spacer()
                                newSessionMenu
                                    .pointingHandCursor()
                            }

                            Image(systemName: "terminal")
                                .font(.system(size: 20))
                                .foregroundStyle(Color.appTertiary)
                            Text(l10n.noSessions)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(Color.appSecondary)
                            Text(l10n.startSessionToBegin)
                                .font(.system(size: 11))
                                .foregroundStyle(Color.appTertiary)
                                .multilineTextAlignment(.center)

                            if appState.agents.isEmpty {
                                Button {
                                    appState.startStandaloneSession()
                                } label: {
                                    Label(l10n.newSession, systemImage: "plus")
                                        .font(.system(size: 12, weight: .medium))
                                }
                                .menuStyle(.borderedButton)
                                .controlSize(.small)
                                .padding(.top, 4)
                            } else {
                                Button {
                                    showingNewSessionInlinePopover = true
                                } label: {
                                    Label(l10n.newSession, systemImage: "plus")
                                        .font(.system(size: 12, weight: .medium))
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .padding(.top, 4)
                                .popover(isPresented: $showingNewSessionInlinePopover, arrowEdge: .bottom) {
                                    newSessionPopoverContent { showingNewSessionInlinePopover = false }
                                }
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 20)
                    }

                    // Session Presets section
                    if !appState.sessionPresets.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(l10n.presets)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(Color.appSecondary)
                                .textCase(.uppercase)
                                .padding(.horizontal, 2)

                            VStack(spacing: 2) {
                                ForEach(appState.sessionPresets) { preset in
                                    sessionPresetRow(preset)
                                        .onDrag {
                                            draggedSessionPresetId = preset.id
                                            return NSItemProvider(object: preset.id.uuidString as NSString)
                                        }
                                        .onDrop(of: [.text], delegate: ItemReorderDropDelegate(
                                            targetId: preset.id,
                                            draggedId: $draggedSessionPresetId,
                                            onMove: { fromId, toId in appState.moveSessionPreset(fromId: fromId, toId: toId) }
                                        ))
                                }
                            }
                        }
                    }

                    // History section
                    if !history.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("History")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(Color.appSecondary)
                                .textCase(.uppercase)
                                .padding(.horizontal, 2)

                            ForEach(SessionTimeGroup.group(history, l10n: l10n), id: \.label) { group in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(group.label)
                                        .font(.system(size: 9, weight: .medium))
                                        .foregroundStyle(Color.appTertiary)
                                        .padding(.horizontal, 8)

                                    VStack(spacing: 2) {
                                        ForEach(group.records) { record in
                                            historyRow(record)
                                        }
                                    }
                                }
                            }

                            Button {
                                showingFullHistory = true
                            } label: {
                                Text("View All...")
                                    .font(.system(size: 11))
                                    .foregroundStyle(Color.appSecondary)
                            }
                            .buttonStyle(.plain)
                            .padding(.horizontal, 8)
                            .pointingHandCursor()
                        }
                    }
                }
                .padding(12)
            }
        }
    }

    // MARK: - Terminals List

    @ViewBuilder
    private var terminalsList: some View {
        let shells = appState.activeShellSessions
        let presets = appState.shellPresets

        if shells.isEmpty && presets.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "apple.terminal")
                    .font(.system(size: 24))
                    .foregroundStyle(Color.appTertiary)
                Text(l10n.noShells)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.appSecondary)
                Text(l10n.openShellToBegin)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.appTertiary)
                    .multilineTextAlignment(.center)

                Menu {
                    Button {
                        appState.startShellSession(shell: .zsh)
                    } label: {
                        Label("zsh", systemImage: "apple.terminal")
                    }
                    Button {
                        appState.startShellSession(shell: .bash)
                    } label: {
                        Label("bash", systemImage: "apple.terminal")
                    }

                    if !appState.shellPresets.isEmpty {
                        Divider()
                        ForEach(appState.shellPresets) { preset in
                            Button {
                                appState.startPresetSession(preset)
                            } label: {
                                Label(preset.name, systemImage: "pin.fill")
                            }
                        }
                    }

                    Divider()
                    Button {
                        presetSheetConfig = PresetSheetConfig()
                    } label: {
                        Label(l10n.newPreset, systemImage: "plus")
                    }
                } label: {
                    Label(l10n.newShell, systemImage: "plus")
                        .font(.system(size: 12, weight: .medium))
                }
                .menuStyle(.borderedButton)
                .controlSize(.small)
                .padding(.top, 4)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if !shells.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("Active")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(Color.appSecondary)
                                    .textCase(.uppercase)
                                    .padding(.horizontal, 2)

                                Spacer()

                                newShellMenu
                                    .pointingHandCursor()
                            }

                            VStack(spacing: 2) {
                                ForEach(shells, id: \.id) { session in
                                    terminalRow(session)
                                }
                            }
                        }
                    } else {
                        // No active shells — show + at top right
                        HStack {
                            Spacer()
                            newShellMenu
                                .pointingHandCursor()
                        }
                    }

                    if !presets.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(l10n.presets)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(Color.appSecondary)
                                .textCase(.uppercase)
                                .padding(.horizontal, 2)

                            VStack(spacing: 2) {
                                ForEach(presets) { preset in
                                    presetRow(preset)
                                        .onDrag {
                                            draggedPresetId = preset.id
                                            return NSItemProvider(object: preset.id.uuidString as NSString)
                                        }
                                        .onDrop(of: [.text], delegate: ItemReorderDropDelegate(
                                            targetId: preset.id,
                                            draggedId: $draggedPresetId,
                                            onMove: { fromId, toId in appState.moveShellPreset(fromId: fromId, toId: toId) }
                                        ))
                                }
                            }
                        }
                    }
                }
                .padding(12)
            }
        }
    }

    private func terminalRow(_ session: AgentSession) -> some View {
        let isSelected = appState.selectedSessionId == session.id
        let status = appState.processManager.status(sessionId: session.id)
        let displayName = session.customName ?? session.shellType?.displayName ?? "Terminal"

        return HStack(spacing: 8) {
            Image(systemName: "apple.terminal")
                .font(.system(size: 12))
                .foregroundStyle(.green)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 3) {
                    if renamingSessionId == session.id {
                        TextField(l10n.tabName, text: $renameText)
                            .font(.system(size: 12, weight: .medium))
                            .textFieldStyle(.plain)
                            .focused($isRenameFocused)
                            .onSubmit { commitSessionRename() }
                            .onExitCommand { renamingSessionId = nil; renameText = "" }
                            .onChange(of: isRenameFocused) { _, focused in
                                if !focused { commitSessionRename() }
                            }
                    } else {
                        Text(displayName)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                    }
                }

                HStack(spacing: 4) {
                    Text(statusText(status))
                        .font(.system(size: 9))
                        .foregroundStyle(statusTextColor(status))

                    let lastTime = appState.processManager.lastInteraction[session.id] ?? session.startedAt
                    Text(lastTime, format: .dateTime.hour().minute())
                        .font(.system(size: 9))
                        .foregroundStyle(Color.appTertiary)
                }
            }

            Spacer()

            if let dir = session.workingDirectory {
                Text("/\(dir.lastPathComponent)")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.appSecondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .themedBackground(Color.appSurfaceSecondary)
                    .cornerRadius(3)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.accentColor.opacity(0.15) : .clear)
        )
        .contentShape(RoundedRectangle(cornerRadius: 6))
        .pointingHandCursor()
        .onTapGesture(count: 2) {
            renameText = session.customName ?? session.shellType?.displayName ?? "Terminal"
            renamingSessionId = session.id
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                isRenameFocused = true
            }
        }
        .onTapGesture {
            appState.selectSession(session.id)
        }
        .contextMenu {
            Button(l10n.rename) {
                renameText = session.customName ?? session.shellType?.displayName ?? "Terminal"
                renamingSessionId = session.id
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    isRenameFocused = true
                }
            }
            if appState.selectedProject != nil {
                Button(l10n.saveAsPreset) {
                    presetSheetConfig = PresetSheetConfig(saveFromSession: session)
                }
            }
            Divider()
            Button(l10n.close) {
                appState.closeTab(sessionId: session.id)
            }
        }
    }

    private func presetRow(_ preset: ShellPreset) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: "pin.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.orange)
                Text(preset.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
            }

            HStack(spacing: 4) {
                Text(preset.directory.isEmpty ? "." : preset.directory)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(Color.appTertiary)
                if let cmd = preset.command, !cmd.isEmpty {
                    Text("→")
                        .font(.system(size: 9))
                        .foregroundStyle(Color.appTertiary)
                    Text(cmd)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(Color.appTertiary)
                        .lineLimit(1)
                }
            }
            .padding(.leading, 15)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(RoundedRectangle(cornerRadius: 6))
        .pointingHandCursor()
        .onTapGesture {
            appState.startPresetSession(preset)
        }
        .contextMenu {
            Button(l10n.edit) {
                presetSheetConfig = PresetSheetConfig(editing: preset)
            }
            Divider()
            Button(l10n.delete, role: .destructive) {
                appState.deleteShellPreset(preset)
            }
        }
    }

    // MARK: - Session Preset Row

    private func sessionPresetRow(_ preset: SessionPreset) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: preset.isCommandMode ? "terminal" : "pin.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(preset.isCommandMode ? .green : .blue)
                Text(preset.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
            }

            if preset.isCommandMode {
                if let raw = preset.rawCommand {
                    Text(raw)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(Color.appTertiary)
                        .lineLimit(1)
                        .padding(.leading, 15)
                }
            } else {
                HStack(spacing: 4) {
                    if preset.model != .inherit {
                        Text(preset.model.displayName)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(Color.appTertiary)
                    }
                    if preset.permissionMode != .default {
                        Text(preset.permissionMode.displayName)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(Color.appTertiary)
                    }
                    if !preset.directory.isEmpty {
                        Text(preset.directory)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(Color.appTertiary)
                            .lineLimit(1)
                    }
                }
                .padding(.leading, 15)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(RoundedRectangle(cornerRadius: 6))
        .pointingHandCursor()
        .onTapGesture {
            appState.startSessionPreset(preset)
        }
        .contextMenu {
            Button(l10n.edit) {
                sessionPresetSheetConfig = PresetSheetConfig(editing: preset)
            }
            Divider()
            Button(l10n.delete, role: .destructive) {
                appState.deleteSessionPreset(preset)
            }
        }
    }

    // MARK: - History Row

    private func historyRow(_ record: SessionRecord) -> some View {
        SessionHistoryRowView(
            record: record,
            onResume: record.isResumable ? {
                appState.resumeFromHistory(record: record)
            } : nil,
            isExtractingMemory: appState.memoryExtractingSessions.contains(record.id)
        )
            .contextMenu {
                if record.isResumable {
                    Button(l10n.resume) {
                        appState.resumeFromHistory(record: record)
                    }
                    Button(l10n.fork) {
                        appState.forkFromHistory(record: record)
                    }
                }

                Divider()

                Button(l10n.delete, role: .destructive) {
                    appState.sessionHistoryService.deleteRecord(id: record.id)
                }
            }
    }

    // MARK: - Session Row

    private func sessionRow(_ session: AgentSession) -> some View {
        let isSelected = appState.selectedSessionId == session.id
        let status: AgentProcessStatus = session.displayMode == .chat
            ? (appState.chatManagers[session.id]?.isProcessing == true ? .running : .waitingForInput)
            : appState.processManager.status(sessionId: session.id)
        let agent = appState.agents.first { $0.id == session.agentId }
        let hasUnread = appState.processManager.processes[session.id]?.hasUnreadOutput ?? false

        // Display name with number if multiple sessions for same agent
        let sameAgentSessions = appState.activeSessions.filter {
            $0.agentId == session.agentId && !$0.isCreationSession
        }
        let displayName: String = {
            if let customName = session.customName { return customName }
            if session.isCreationSession { return session.agentName }
            if sameAgentSessions.count > 1,
               let index = sameAgentSessions.firstIndex(where: { $0.id == session.id }) {
                return "\(session.agentName) #\(index + 1)"
            }
            return session.agentName
        }()

        return HStack(spacing: 6) {
            // Status icon — vertically centered
            Image(systemName: statusIconName(status))
                .font(.system(size: 12))
                .foregroundStyle(statusColor(status))
                .symbolEffect(.pulse, options: .repeating, isActive: status == .running)

            // Color bar — full height
            RoundedRectangle(cornerRadius: 1.5)
                .fill(agent?.color.swiftUIColor ?? .gray)
                .frame(width: 3)

            // Content
            VStack(alignment: .leading, spacing: 2) {
                // Row 1: name + directory badge
                HStack(spacing: 4) {
                    HStack(spacing: 3) {
                        if session.isScheduledSession {
                            Image(systemName: "clock.fill")
                                .font(.system(size: 8))
                                .foregroundStyle(.orange)
                        }
                        if renamingSessionId == session.id {
                            TextField(l10n.tabName, text: $renameText)
                                .font(.system(size: 12, weight: .medium))
                                .textFieldStyle(.plain)
                                .focused($isRenameFocused)
                                .onSubmit { commitSessionRename() }
                                .onExitCommand { renamingSessionId = nil; renameText = "" }
                                .onChange(of: isRenameFocused) { _, focused in
                                    if !focused { commitSessionRename() }
                                }
                        } else {
                            Text(displayName)
                                .font(.system(size: 12, weight: .medium))
                                .lineLimit(1)
                        }
                    }

                    if hasUnread && !isSelected {
                        Circle()
                            .fill(.blue)
                            .frame(width: 6, height: 6)
                    }

                    Spacer()

                    if let dir = session.workingDirectory ?? agent?.effectiveDirectory {
                        Text("/\(dir.lastPathComponent)")
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .foregroundStyle(Color.appSecondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .themedBackground(Color.appSurfaceSecondary)
                            .cornerRadius(3)
                            .lineLimit(1)
                    }
                }

                // Row 2: prompt text (full width)
                if let prompt = appState.processManager.lastUserPrompt[session.id] {
                    Text(prompt)
                        .font(.system(size: 10))
                        .foregroundStyle(Color.appSecondary)
                        .lineLimit(2)
                        .truncationMode(.tail)
                }

                // Row 3: status + time | shortcut
                HStack(spacing: 4) {
                    if session.isCreationSession {
                        Text("Creating...")
                            .font(.system(size: 9))
                            .foregroundStyle(.purple)
                            .lineLimit(1)
                    } else {
                        Text(statusText(status))
                            .font(.system(size: 9))
                            .foregroundStyle(statusTextColor(status))
                            .lineLimit(1)
                    }

                    let lastTime = appState.processManager.lastInteraction[session.id] ?? session.startedAt
                    Text(lastTime, format: .dateTime.hour().minute())
                        .font(.system(size: 9))
                        .foregroundStyle(Color.appTertiary)
                        .lineLimit(1)

                    Spacer()

                    // ⌘N shortcut badge
                    if let idx = appState.activeSessions.firstIndex(where: { $0.id == session.id }),
                       idx < 9 {
                        Text("⌘\(idx + 1)")
                            .font(.system(size: 9, weight: .medium, design: .rounded))
                            .foregroundStyle(Color.appTertiary)
                    }
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.accentColor.opacity(0.15) : .clear)
        )
        .contentShape(RoundedRectangle(cornerRadius: 6))
        .pointingHandCursor()
        .onTapGesture(count: 2) {
            guard !session.isCreationSession else { return }
            renameText = session.customName ?? session.agentName
            renamingSessionId = session.id
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                isRenameFocused = true
            }
        }
        .onTapGesture {
            appState.selectSession(session.id)
        }
        .contextMenu {
            sessionContextMenu(session: session)
        }
    }

    @ViewBuilder
    private func sessionContextMenu(session: AgentSession) -> some View {
        let isRunning = appState.processManager.isRunning(sessionId: session.id)

        if !session.isCreationSession {
            Button(l10n.rename) {
                renameText = session.customName ?? session.agentName
                renamingSessionId = session.id
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    isRenameFocused = true
                }
            }
        }

        if !isRunning && appState.canResumeSession(sessionId: session.id) {
            Button(l10n.resume + "  \u{2318}R") { appState.resumeSession(sessionId: session.id) }
        }

        if appState.canForkSession(sessionId: session.id) {
            Button(l10n.fork) { appState.forkSession(sessionId: session.id) }
        }

        let otherSessions = appState.otherActiveSessions(excluding: session.id)
        if !otherSessions.isEmpty {
            Menu(l10n.shareContext) {
                ForEach(otherSessions, id: \.id) { target in
                    let sameAgentSessions = otherSessions.filter {
                        $0.agentId == target.agentId && !$0.isCreationSession
                    }
                    let targetName: String = {
                        if target.isCreationSession { return target.agentName }
                        if sameAgentSessions.count > 1,
                           let index = sameAgentSessions.firstIndex(where: { $0.id == target.id }) {
                            return "\(target.agentName) #\(index + 1)"
                        }
                        return target.agentName
                    }()
                    Button(targetName) {
                        appState.shareContext(from: session.id, to: target.id)
                    }
                }
            }
        }

        if !session.isCreationSession {
            Button(l10n.duplicate + "  \u{2318}D") { appState.duplicateSession(sessionId: session.id) }
        }

        // "Save as Preset" for standalone sessions (not agent-backed)
        if !session.isShellSession && session.agentId == session.id {
            Button(l10n.saveAsPreset) {
                sessionPresetSheetConfig = PresetSheetConfig(saveFromSession: session)
            }
        }

        Button(l10n.close + "  \u{2318}W") { appState.closeTab(sessionId: session.id) }
    }

    private func commitSessionRename() {
        if let id = renamingSessionId {
            appState.renameSession(sessionId: id, name: renameText)
        }
        renamingSessionId = nil
        renameText = ""
    }

    private func statusText(_ status: AgentProcessStatus) -> String {
        switch status {
        case .running: return l10n.thinking
        case .waitingForInput: return l10n.ready
        case .stopped: return l10n.stopped
        }
    }

    private func statusTextColor(_ status: AgentProcessStatus) -> Color {
        switch status {
        case .running: return .statusRunning
        case .waitingForInput: return .statusReady
        case .stopped: return .statusStopped
        }
    }

    // MARK: - Parse Error Section

    private var parseErrorSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Parse Errors")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.orange)
                .textCase(.uppercase)
                .padding(.horizontal, 2)

            VStack(spacing: 2) {
                ForEach(appState.agentParseErrors) { error in
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.orange)

                        VStack(alignment: .leading, spacing: 1) {
                            Text(error.fileName)
                                .font(.system(size: 12, weight: .medium))
                                .lineLimit(1)
                            Text(error.error)
                                .font(.system(size: 10))
                                .foregroundStyle(Color.appSecondary)
                                .lineLimit(1)
                        }

                        Spacer()
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.orange.opacity(0.08))
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 6))
                    .onTapGesture {
                        NSWorkspace.shared.activateFileViewerSelecting([error.filePath])
                    }
                }
            }
        }
    }

    // MARK: - Relation Warning Section

    private var relationWarningSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(l10n.relationWarnings)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.orange)
                .textCase(.uppercase)
                .padding(.horizontal, 2)

            VStack(spacing: 2) {
                ForEach(appState.relationWarnings) { warning in
                    HStack(spacing: 6) {
                        Image(systemName: relationWarningIcon(for: warning.kind))
                            .font(.system(size: 10))
                            .foregroundStyle(relationWarningColor(for: warning.kind))

                        Text(warning.message)
                            .font(.system(size: 10))
                            .foregroundStyle(Color.appSecondary)
                            .lineLimit(2)

                        Spacer()
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(relationWarningColor(for: warning.kind).opacity(0.08))
                    )
                    .contextMenu {
                        if case .brokenReference(_, let childName) = warning.kind {
                            Button(l10n.removeBrokenReference) {
                                removeBrokenReference(parentId: warning.parentAgentId, childName: childName)
                            }
                        }
                    }
                }
            }
        }
    }

    private func relationWarningIcon(for kind: RelationWarningKind) -> String {
        switch kind {
        case .crossScopeUserToProject: return "exclamationmark.triangle.fill"
        case .crossProjectReference: return "folder.badge.questionmark"
        case .brokenReference: return "link.badge.plus"
        }
    }

    private func relationWarningColor(for kind: RelationWarningKind) -> Color {
        switch kind {
        case .crossScopeUserToProject: return .orange
        case .crossProjectReference, .brokenReference: return .red
        }
    }

    private func removeBrokenReference(parentId: UUID?, childName: String) {
        guard let parentId,
              var parent = appState.agents.first(where: { $0.id == parentId }) else { return }
        do {
            try appState.relationService.removeRelation(parent: &parent, childName: childName)
            appState.reloadAgents()
            appState.toastMessage = "Removed broken reference \"\(childName)\""
        } catch {
            appState.errorMessage = "Failed to remove reference: \(error.localizedDescription)"
        }
    }

    // MARK: - Schedule Section

    private var schedulesByProject: [(projectName: String, schedules: [AgentSchedule])] {
        var grouped: [String: [AgentSchedule]] = [:]
        for schedule in appState.scheduleManager.schedules where schedule.scope == .project {
            let key: String
            if let projectPath = schedule.projectPath,
               let project = appState.projects.first(where: { $0.directoryPath.path(percentEncoded: false) == projectPath }) {
                key = project.name
            } else {
                key = URL(filePath: schedule.projectPath ?? "").lastPathComponent
            }
            grouped[key, default: []].append(schedule)
        }
        let projectOrder = Dictionary(uniqueKeysWithValues: appState.projects.enumerated().map { ($1.name, $0) })
        return grouped.sorted { (projectOrder[$0.key] ?? Int.max) < (projectOrder[$1.key] ?? Int.max) }
            .map { (projectName: $0.key, schedules: $0.value) }
    }

    private func scheduleSection(_ title: String, schedules: [AgentSchedule]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Color.appSecondary)
                .textCase(.uppercase)
                .padding(.horizontal, 2)

            VStack(spacing: 2) {
                ForEach(schedules) { schedule in
                    ScheduleRowView(
                        schedule: schedule,
                        isSelected: selectedScheduleId == schedule.id
                    )
                    .onTapGesture {
                        selectedScheduleId = schedule.id
                        appState.showScheduleEditor(schedule)
                    }
                    .contextMenu {
                        scheduleContextMenu(schedule: schedule)
                    }
                    .onDrag {
                        draggedScheduleId = schedule.id
                        return NSItemProvider(object: schedule.id.uuidString as NSString)
                    }
                    .onDrop(of: [.text], delegate: ItemReorderDropDelegate(
                        targetId: schedule.id,
                        draggedId: $draggedScheduleId,
                        onMove: { fromId, toId in appState.scheduleManager.moveSchedule(fromId: fromId, toId: toId) }
                    ))
                }
            }
        }
    }

    // MARK: - Section Placeholder

    private func sectionPlaceholder(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(Color.appTertiary)
            .padding(.horizontal, 2)
            .padding(.vertical, 4)
    }

    // MARK: - Agent Section

    private func agentSection(_ title: String, agents: [Agent], showAddMenu: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.appSecondary)
                    .textCase(.uppercase)
                    .padding(.horizontal, 2)

                Spacer()

                if showAddMenu {
                    reloadButton { appState.reloadAgents() }
                    newAgentMenu
                        .pointingHandCursor()
                }
            }

            if agents.isEmpty {
                sectionPlaceholder(l10n.noAgentsInSection)
            }

            VStack(spacing: 2) {
                ForEach(agents) { agent in
                    agentRow(agent)
                        .onDrag {
                            draggedAgentId = agent.id
                            return NSItemProvider(object: agent.id.uuidString as NSString)
                        }
                        .onDrop(of: [.text], delegate: ItemReorderDropDelegate(
                            targetId: agent.id,
                            draggedId: $draggedAgentId,
                            onMove: { fromId, toId in appState.moveAgent(fromId: fromId, toId: toId) }
                        ))
                }
            }
        }
    }

    // MARK: - Agent Row

    private func agentRow(_ agent: Agent) -> some View {
        let isSelected = appState.selectedAgentId == agent.id
        let status = appState.bestStatus(agentId: agent.id)
        let count = appState.sessionCount(agentId: agent.id)

        return HStack(spacing: 8) {
            // Status icon
            Image(systemName: statusIconName(status))
                .font(.system(size: 12))
                .foregroundStyle(statusColor(status))
                .symbolEffect(.pulse, options: .repeating, isActive: status == .running)

            // Color bar
            RoundedRectangle(cornerRadius: 1.5)
                .fill(agent.color.swiftUIColor)
                .frame(width: 3, height: 20)

            VStack(alignment: .leading, spacing: 1) {
                Text(agent.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)

                if status.isActive {
                    Text(status == .running ? l10n.thinking : l10n.ready)
                        .font(.system(size: 9))
                        .foregroundStyle(status == .running ? Color.statusRunning : Color.statusReady)
                } else if !agent.description.isEmpty {
                    Text(agent.description)
                        .font(.system(size: 10))
                        .foregroundStyle(Color.appSecondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            // Session count badge
            if count > 0 {
                Text("\(count)")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 16, height: 16)
                    .background(Color.accentColor)
                    .clipShape(Circle())
            }

            if let dir = agent.effectiveDirectory {
                Text("/\(dir.lastPathComponent)")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.appSecondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .themedBackground(Color.appSurfaceSecondary)
                    .cornerRadius(3)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.accentColor.opacity(0.15) : .clear)
        )
        .contentShape(RoundedRectangle(cornerRadius: 6))
        .help(agent.effectiveDirectory?.path(percentEncoded: false) ?? "")
        .pointingHandCursor()
        .onTapGesture {
            appState.showAgentEditor(agent)
        }
        .simultaneousGesture(
            TapGesture(count: 2).onEnded {
                appState.startAgent(agent)
                appState.sidebarTab = .sessions
            }
        )
        .contextMenu {
            agentContextMenu(agent: agent)
        }
    }

    // MARK: - Skills List

    @ViewBuilder
    private var skillsList: some View {
        if appState.skills.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "book.closed")
                    .font(.system(size: 24))
                    .foregroundStyle(Color.appTertiary)
                Text(l10n.noSkills)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.appSecondary)
                Text(l10n.addSkill)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.appTertiary)
                    .multilineTextAlignment(.center)

                Menu {
                    creationMenuItems(kind: .skill)
                } label: {
                    Label(l10n.newSkill, systemImage: "plus")
                        .font(.system(size: 12, weight: .medium))
                }
                .menuStyle(.borderedButton)
                .controlSize(.small)
                .padding(.top, 4)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    switch appState.projectSelection {
                    case .home:
                        // Home: user skills only (no project section)
                        EmptyView()

                    case .project:
                        skillSection(
                            "Project Skills",
                            skills: appState.projectSkills,
                            showAddMenu: true
                        )

                    case .all:
                        ForEach(Array(appState.skillsByProject.enumerated()), id: \.element.projectName) { index, group in
                            skillSection(
                                group.projectName,
                                skills: group.skills,
                                showAddMenu: index == 0
                            )
                        }
                    }

                    skillSection(
                        l10n.userGlobal,
                        skills: appState.userSkills,
                        showAddMenu: appState.projectSelection == .home
                    )
                }
                .padding(12)
            }
        }
    }

    private func skillSection(_ title: String, skills: [Skill], showAddMenu: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.appSecondary)
                    .textCase(.uppercase)
                    .padding(.horizontal, 2)

                Spacer()

                if showAddMenu {
                    skillUsageStatsButton
                    reloadButton { appState.reloadSkills() }
                    newSkillMenu
                        .pointingHandCursor()
                }
            }

            if skills.isEmpty {
                sectionPlaceholder(l10n.noSkillsInSection)
            }

            VStack(spacing: 2) {
                ForEach(skills) { skill in
                    skillRow(skill)
                        .onDrag {
                            draggedSkillId = skill.id
                            return NSItemProvider(object: skill.id.uuidString as NSString)
                        }
                        .onDrop(of: [.text], delegate: ItemReorderDropDelegate(
                            targetId: skill.id,
                            draggedId: $draggedSkillId,
                            onMove: { fromId, toId in appState.moveSkill(fromId: fromId, toId: toId) }
                        ))
                }
            }
        }
    }

    private var skillUsageStatsButton: some View {
        Button {
            showingSkillUsageStats = true
        } label: {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
    }

    private func skillRow(_ skill: Skill) -> some View {
        let isSelected = appState.selectedSkillId == skill.id

        return HStack(spacing: 8) {
            Image(systemName: "book.closed.fill")
                .font(.system(size: 10))
                .foregroundStyle(.purple)

            VStack(alignment: .leading, spacing: 1) {
                Text(skill.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)

                if !skill.description.isEmpty {
                    Text(skill.description)
                        .font(.system(size: 10))
                        .foregroundStyle(Color.appSecondary)
                        .lineLimit(1)
                }
            }

            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.accentColor.opacity(0.15) : .clear)
        )
        .contentShape(RoundedRectangle(cornerRadius: 6))
        .pointingHandCursor()
        .onTapGesture {
            appState.selectSkill(skill)
        }
        .contextMenu {
            skillContextMenu(skill: skill)
        }
    }

    @ViewBuilder
    private func skillContextMenu(skill: Skill) -> some View {
        Menu(l10n.duplicate + "  \u{2318}D") {
            Button(l10n.userGlobal) {
                let userDir = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude/skills")
                appState.duplicateSkill(skill, to: userDir)
            }
            if let project = appState.selectedProject {
                Button("Project (\(project.name))") {
                    appState.duplicateSkill(skill, to: project.skillsDirectory)
                }
            }
            Button("Other Project...") {
                pickProjectDirectoryForSkillDuplicate(skill: skill)
            }
        }
        Divider()
        if let dir = skill.skillDirectory {
            Button(l10n.revealInFinder) {
                NSWorkspace.shared.activateFileViewerSelecting([dir])
            }
            Divider()
        }
        Button(l10n.delete, role: .destructive) { skillToDelete = skill }
    }

    // MARK: - Schedules List

    private var hasAnySchedules: Bool {
        !appState.scheduleManager.schedules.isEmpty
        || !appState.cloudTriggerService.triggers.isEmpty
        || appState.cloudTriggerService.isLoading
        || !appState.cloudTriggerService.hasFetched
    }

    @ViewBuilder
    private var schedulesList: some View {
        if hasAnySchedules {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    // Header with + button
                    HStack {
                        Spacer()
                        newScheduleButton
                            .pointingHandCursor()
                    }

                    // Project schedules grouped by project
                    ForEach(schedulesByProject, id: \.projectName) { group in
                        scheduleSection(group.projectName, schedules: group.schedules)
                    }

                    // User (global) schedules
                    let userSchedules = appState.scheduleManager.schedules.filter { $0.scope == .user }
                    if !userSchedules.isEmpty {
                        scheduleSection(l10n.userGlobal, schedules: userSchedules)
                    }

                    // Cloud schedules
                    cloudScheduleSection
                }
                .padding(12)
            }
        } else {
            VStack(spacing: 8) {
                Image(systemName: "clock")
                    .font(.system(size: 24))
                    .foregroundStyle(Color.appTertiary)
                Text(l10n.noSchedules)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.appSecondary)
                Text(l10n.addScheduleToStart)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.appTertiary)
                    .multilineTextAlignment(.center)

                Button {
                    showingNewSchedule = true
                } label: {
                    Label(l10n.newSchedule, systemImage: "plus")
                        .font(.system(size: 12, weight: .medium))
                }
                .menuStyle(.borderedButton)
                .controlSize(.small)
                .padding(.top, 4)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Cloud Schedule Section

    private var cloudScheduleSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                HStack(spacing: 4) {
                    Image(systemName: "cloud.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.blue.opacity(0.7))
                    Text(l10n.cloud)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color.appSecondary)
                        .textCase(.uppercase)
                }
                .padding(.horizontal, 2)

                Spacer()

                if appState.cloudTriggerService.isLoading {
                    ProgressView()
                        .controlSize(.mini)
                } else {
                    Button {
                        appState.loadCloudTriggers()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 9))
                            .foregroundStyle(Color.appSecondary)
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor()
                }
            }

            if let error = appState.cloudTriggerService.error {
                Text(error)
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .padding(.horizontal, 4)
            }

            VStack(spacing: 2) {
                ForEach(appState.cloudTriggerService.triggers, id: \.id) { trigger in
                    CloudTriggerRowView(
                        trigger: trigger,
                        isSelected: selectedCloudTriggerId == trigger.id
                    )
                    .onTapGesture {
                        selectedCloudTriggerId = trigger.id
                        selectedScheduleId = nil
                        appState.showCloudTriggerEditor(trigger)
                    }
                    .contextMenu {
                        cloudTriggerContextMenu(trigger: trigger)
                    }
                }
            }

            if appState.cloudTriggerService.isLoading && appState.cloudTriggerService.triggers.isEmpty {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.mini)
                    Text("Loading cloud schedules…")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.appTertiary)
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 4)
            } else if appState.cloudTriggerService.triggers.isEmpty && appState.cloudTriggerService.hasFetched {
                Text("No cloud schedules")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.appTertiary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
            }
        }
    }

    @ViewBuilder
    private func cloudTriggerContextMenu(trigger: CloudTrigger) -> some View {
        Button(l10n.runNow) {
            Task {
                try? await appState.runCloudTrigger(id: trigger.id)
            }
        }
        Divider()
        Button(trigger.enabled ? l10n.disable : l10n.enable) {
            Task {
                try? await appState.toggleCloudTrigger(trigger)
            }
        }
        Button(l10n.edit) {
            selectedCloudTriggerId = trigger.id
            selectedScheduleId = nil
            appState.showCloudTriggerEditor(trigger)
        }
        Divider()
        Button(l10n.deleteOnWeb) {
            NSWorkspace.shared.open(URL(string: "https://claude.ai/code/scheduled")!)
        }
    }

    @ViewBuilder
    private func scheduleContextMenu(schedule: AgentSchedule) -> some View {
        Button(l10n.runNow) {
            appState.scheduleManager.runNow(schedule)
        }
        Divider()
        Button(schedule.isEnabled ? l10n.disable : l10n.enable) {
            var updated = schedule
            updated.isEnabled.toggle()
            appState.scheduleManager.updateSchedule(updated)
        }
        Button(l10n.edit) {
            scheduleToEdit = schedule
        }
        Button(l10n.duplicate) {
            duplicateSchedule(schedule)
        }
        Divider()
        Button(l10n.delete, role: .destructive) {
            scheduleToDelete = schedule
        }
    }

    private func duplicateSchedule(_ schedule: AgentSchedule) {
        var copy = schedule
        copy.id = UUID()
        copy.createdAt = Date()
        copy.lastExecutedAt = nil
        copy.lastError = nil
        copy.isEnabled = false
        appState.scheduleManager.addSchedule(copy)
    }

    // MARK: - Add Icon Label & Menus

    private func reloadButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
    }

    private var addIconLabel: some View {
        Image(systemName: "plus")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: 20, height: 20)
            .contentShape(Rectangle())
    }

    private func addIconMenuStyle<V: View>(_ menu: V) -> some View {
        menu
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.secondary.opacity(0.25))
            )
    }

    /// Shared "+" menu contents: pick AI-assisted creation (which then asks for
    /// CLI and scope in a sheet) or the manual form.
    @ViewBuilder
    private func creationMenuItems(kind: AICreationKind) -> some View {
        Button {
            aiCreationKind = kind
        } label: {
            Label(l10n.createWithAI, systemImage: "sparkles")
        }

        Button {
            switch kind {
            case .agent: showingNewAgent = true
            case .skill: showingNewSkill = true
            }
        } label: {
            Label(l10n.createManually, systemImage: "square.and.pencil")
        }
    }

    private var newAgentMenu: some View {
        addIconMenuStyle(
            Menu {
                creationMenuItems(kind: .agent)
            } label: {
                addIconLabel
            }
        )
    }

    private var newSkillMenu: some View {
        addIconMenuStyle(
            Menu {
                creationMenuItems(kind: .skill)
            } label: {
                addIconLabel
            }
        )
    }

    private var newSessionMenu: some View {
        Button {
            showingNewSessionMenuPopover = true
        } label: {
            addIconLabel
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(Color.secondary.opacity(0.25))
        )
        .popover(isPresented: $showingNewSessionMenuPopover, arrowEdge: .bottom) {
            newSessionPopoverContent { showingNewSessionMenuPopover = false }
        }
    }

    /// Shared styled content for the new-session popovers. Replaces the native
    /// menu so the "From Agent" rows can use a two-line layout (agent name on
    /// top, working directory below) instead of a hard-to-read hyphenated string.
    @ViewBuilder
    private func newSessionPopoverContent(close: @escaping () -> Void) -> some View {
        ScrollView {
            newSessionPopoverRows(close: close)
        }
        .frame(width: 260)
        .frame(maxHeight: 420)
    }

    @ViewBuilder
    private func newSessionPopoverRows(close: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            NewSessionActionRow(title: "Quick Start", systemImage: "terminal") {
                close()
                appState.startStandaloneSession()
            }
            NewSessionActionRow(title: "Configure & Start…", systemImage: "slider.horizontal.3") {
                close()
                DispatchQueue.main.async { showingNewSession = true }
            }

            if !appState.sessionPresets.isEmpty {
                newSessionSectionHeader(l10n.presets)
                ForEach(appState.sessionPresets) { preset in
                    NewSessionActionRow(title: preset.name, systemImage: "pin.fill") {
                        close()
                        appState.startSessionPreset(preset)
                    }
                }
            }

            if !appState.agents.isEmpty {
                newSessionSectionHeader("From Agent")
                ForEach(appState.agentsByRecentUse) { agent in
                    NewSessionAgentRow(agent: agent) {
                        close()
                        appState.startAgent(agent)
                    }
                }
            }

            Divider()
                .padding(.horizontal, 8)
                .padding(.vertical, 4)

            NewSessionActionRow(title: l10n.newPreset, systemImage: "plus") {
                close()
                DispatchQueue.main.async { sessionPresetSheetConfig = PresetSheetConfig() }
            }
        }
        .padding(6)
    }

    @ViewBuilder
    private func newSessionSectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .medium))
            .textCase(.uppercase)
            .foregroundStyle(Color.appSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.top, 8)
            .padding(.bottom, 2)
    }

    private var newShellMenu: some View {
        addIconMenuStyle(
            Menu {
                Button {
                    appState.startShellSession(shell: .zsh)
                } label: {
                    Label("zsh", systemImage: "apple.terminal")
                }
                Button {
                    appState.startShellSession(shell: .bash)
                } label: {
                    Label("bash", systemImage: "apple.terminal")
                }

                if !appState.shellPresets.isEmpty {
                    Divider()
                    ForEach(appState.shellPresets) { preset in
                        Button {
                            appState.startPresetSession(preset)
                        } label: {
                            Label(preset.name, systemImage: "pin.fill")
                        }
                    }
                }

                Divider()
                Button {
                    presetSheetConfig = PresetSheetConfig()
                } label: {
                    Label(l10n.newPreset, systemImage: "plus")
                }
            } label: {
                addIconLabel
            }
        )
    }

    private var newScheduleButton: some View {
        Button {
            showingNewSchedule = true
        } label: {
            addIconLabel
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(Color.secondary.opacity(0.25))
        )
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        HStack {
            if appState.sidebarTab == .files {
                Menu {
                    Button {
                        appState.promptCreateFile()
                    } label: {
                        Label(l10n.newFile, systemImage: "doc.badge.plus")
                    }
                    Button {
                        appState.promptCreateDirectory()
                    } label: {
                        Label(l10n.newFolder, systemImage: "folder.badge.plus")
                    }
                    Divider()
                    Button {
                        appState.loadFileTree()
                    } label: {
                        Label(l10n.refresh, systemImage: "arrow.clockwise")
                    }
                } label: {
                    Label(l10n.newFile, systemImage: "plus")
                }
                .menuStyle(.borderlessButton)
                .pointingHandCursor()
            }

            Spacer()

            if appState.sidebarTab == .agents && !appState.agents.isEmpty {
                Button {
                    if appState.centerPane == .orgChart {
                        appState.orgChartTabOpen = false
                        appState.centerPane = .terminal
                    } else {
                        appState.orgChartTabOpen = true
                        appState.centerPane = .orgChart
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "rectangle.3.group")
                            .font(.system(size: 10))
                        Text(l10n.orgChart)
                            .font(.system(size: 10, weight: .medium))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(appState.centerPane == .orgChart ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.12))
                    )
                    .foregroundStyle(appState.centerPane == .orgChart ? .primary : .secondary)
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
            }

            Button {
                showingShortcuts.toggle()
            } label: {
                Image(systemName: "questionmark.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.appSecondary)
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
            .popover(isPresented: $showingShortcuts, arrowEdge: .top) {
                shortcutsPopover
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .themedBackground(Color.appSurface)
    }

    // MARK: - Shortcuts Popover

    private var shortcutsPopover: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(l10n.keyboardShortcuts)
                .font(.system(size: 11, weight: .semibold))

            Divider()

            shortcutRow(l10n.save, shortcut: "⌘S")
            shortcutRow(l10n.revert, shortcut: "⌘Z")
            shortcutRow(l10n.duplicate, shortcut: "⌘D")

            Divider()

            shortcutRow("Stop Session", shortcut: "⌘.")
            shortcutRow("Switch Tab 1–9", shortcut: "⌘1–9")
        }
        .padding(12)
        .frame(width: 200)
    }

    private func shortcutRow(_ label: String, shortcut: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 11))
            Spacer()
            Text(shortcut)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.appSecondary)
        }
    }

    // MARK: - Directory Picker

    private func pickProjectDirectoryForSkillDuplicate(skill: Skill) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Select project directory to duplicate skill into"

        if panel.runModal() == .OK, let url = panel.url {
            let targetDir = url.appending(path: ".claude/skills")
            appState.duplicateSkill(skill, to: targetDir)
        }
    }

    private func pickProjectDirectoryForDuplicate(agent: Agent) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Select project directory to duplicate agent into"

        if panel.runModal() == .OK, let url = panel.url {
            let targetDir = url.appending(path: ".claude/agents")
            appState.duplicateAgent(agent, to: targetDir)
        }
    }

    // MARK: - Context Menu

    @ViewBuilder
    private func agentContextMenu(agent: Agent) -> some View {
        let sessions = appState.activeSessions.filter { $0.agentId == agent.id }
        let hasActiveSessions = !sessions.isEmpty

        Button(l10n.startAgentMenu + "  \u{2318}R") { appState.startAgent(agent) }

        if appState.availableCLIProviders.count > 1 {
            let altProvider: CLIProviderType = agent.defaultProvider == .claude ? .codex : .claude
            Button("Start with \(altProvider.displayName)") { appState.startAgent(agent, provider: altProvider) }
        }

        if hasActiveSessions {
            Button(l10n.closeAllMenu + " (\(sessions.count))") { appState.closeAllSessions(agentId: agent.id) }
            Button("Restart") { appState.restartAgent(agent) }
        }

        Divider()
        Menu(l10n.duplicate + "  \u{2318}D") {
            Button(l10n.userGlobal) {
                let userDir = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude/agents")
                appState.duplicateAgent(agent, to: userDir)
            }
            if let project = appState.selectedProject {
                Button("Project (\(project.name))") {
                    appState.duplicateAgent(agent, to: project.agentsDirectory)
                }
            }
            Button("Other Project...") {
                pickProjectDirectoryForDuplicate(agent: agent)
            }
        }
        Divider()
        Button(l10n.delete, role: .destructive) { agentToDelete = agent }
    }

    // MARK: - Helpers

    private func statusIconName(_ status: AgentProcessStatus) -> String {
        switch status {
        case .running: return "bolt.fill"
        case .waitingForInput: return "checkmark.circle.fill"
        case .stopped: return "stop.circle"
        }
    }

    private func statusColor(_ status: AgentProcessStatus) -> Color {
        switch status {
        case .running: return .statusRunning
        case .waitingForInput: return .statusReady
        case .stopped: return .statusStopped
        }
    }
}

// MARK: - Sidebar Tab Icon (NSView-backed for reliable tooltip)

private struct SidebarTabPicker: View {
    @Binding var selectedTab: AppState.SidebarTab
    @Environment(\.l10n) private var l10n
    @State private var hoveredTab: AppState.SidebarTab?

    /// Persisted tab order (all tabs). The first 4 are displayed.
    @AppStorage("sidebarTabOrder") private var tabOrderRaw: String = "Sessions,Agents,Skills,Schedules,Files,Shells"

    /// All tabs in user-configured order.
    private var allOrderedTabs: [AppState.SidebarTab] {
        let raw = tabOrderRaw.split(separator: ",").map(String.init)
        var tabs = raw.compactMap { AppState.SidebarTab(rawValue: $0) }
        let existing = Set(tabs)
        for tab in AppState.SidebarTab.allCases where !existing.contains(tab) {
            tabs.append(tab)
        }
        return tabs
    }

    /// First 4 tabs shown in the tab bar.
    private var displayedTabs: [AppState.SidebarTab] {
        Array(allOrderedTabs.prefix(4))
    }

    /// Remaining tabs accessible via overflow menu.
    private var overflowTabs: [AppState.SidebarTab] {
        Array(allOrderedTabs.dropFirst(4))
    }

    /// Swap an overflow tab into the 4th visible slot.
    private func promoteToVisible(_ tab: AppState.SidebarTab) {
        var list = allOrderedTabs
        guard let fromIdx = list.firstIndex(of: tab) else { return }
        list.remove(at: fromIdx)
        list.insert(tab, at: 3) // Place in 4th slot
        tabOrderRaw = list.map(\.rawValue).joined(separator: ",")
    }

    private func tabLabel(_ tab: AppState.SidebarTab) -> String {
        switch tab {
        case .agents: return l10n.agents
        case .sessions: return l10n.sessions
        case .skills: return l10n.skills
        case .schedules: return l10n.schedules
        case .files: return l10n.files
        case .shells: return l10n.shells
        }
    }

    @ViewBuilder
    private func tabButton(_ tab: AppState.SidebarTab) -> some View {
        VStack(spacing: 2) {
            Image(systemName: tab.icon)
                .font(.system(size: 13))
                .frame(width: 28, height: 20)

            Text(tabLabel(tab))
                .font(.system(size: 8, weight: .medium))
                .lineLimit(1)
                .opacity(hoveredTab == tab || selectedTab == tab ? 1 : 0)
        }
        .frame(width: 48)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(selectedTab == tab ? Color.accentColor.opacity(0.15) : .clear)
        )
        .foregroundStyle(selectedTab == tab ? .primary : .secondary)
        .contentShape(Rectangle())
        .onTapGesture { selectedTab = tab }
        .onHover { inside in
            hoveredTab = inside ? tab : nil
        }
        .pointingHandCursor()
    }

    var body: some View {
        #if DEBUG
        let _ = Self._printChanges()
        #endif
        HStack(spacing: 4) {
            Spacer().frame(width: 8)

            ForEach(displayedTabs, id: \.self) { tab in
                tabButton(tab)
            }

            // Overflow menu for remaining tabs
            if !overflowTabs.isEmpty {
                Menu {
                    ForEach(overflowTabs, id: \.self) { tab in
                        Button {
                            promoteToVisible(tab)
                            selectedTab = tab
                        } label: {
                            Label(tabLabel(tab), systemImage: tab.icon)
                        }
                    }
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 11))
                            .frame(width: 20, height: 20)
                    }
                    .frame(width: 28)
                    .padding(.vertical, 4)
                    .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .pointingHandCursor()
            }

            Spacer().frame(width: 8)
        }
    }
}

// MARK: - Drag & Drop Reorder Delegate

/// A generic drop delegate that reorders items by UUID.
private struct ItemReorderDropDelegate: DropDelegate {
    let targetId: UUID
    @Binding var draggedId: UUID?
    let onMove: (UUID, UUID) -> Void

    func performDrop(info: DropInfo) -> Bool {
        draggedId = nil
        return true
    }

    func dropEntered(info: DropInfo) {
        guard let fromId = draggedId, fromId != targetId else { return }
        withAnimation(.default) {
            onMove(fromId, targetId)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {}
}

// MARK: - Pulsing Status Dot

private struct PulsingDot: View {
    let color: Color
    let isPulsing: Bool
    @State private var isAnimating = false

    var body: some View {
        #if DEBUG
        let _ = Self._printChanges()
        #endif
        ZStack {
            if isPulsing {
                Circle()
                    .fill(color.opacity(0.4))
                    .frame(width: 10, height: 10)
                    .scaleEffect(isAnimating ? 1.0 : 0.5)
                    .opacity(isAnimating ? 0.0 : 1.0)
            }
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
        }
        .frame(width: 10, height: 10)
        .onAppear {
            guard isPulsing else { return }
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: false)) {
                isAnimating = true
            }
        }
        .onChange(of: isPulsing) {
            if isPulsing {
                isAnimating = false
                withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: false)) {
                    isAnimating = true
                }
            } else {
                isAnimating = false
            }
        }
    }
}

// MARK: - New Session Popover Rows

/// A single-line action row (icon + title) used inside the new-session popover.
private struct NewSessionActionRow: View {
    let title: String
    let systemImage: String
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.appSecondary)
                    .frame(width: 16)
                Text(title)
                    .font(.system(size: 12))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(hovered ? Color.primary.opacity(0.08) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .pointingHandCursor()
    }
}

/// A two-line agent row (name on top, working directory below) — replaces the
/// hard-to-read "AgentName — dir" hyphenated string from the old native menu.
private struct NewSessionAgentRow: View {
    let agent: Agent
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Circle()
                    .fill(agent.color.swiftUIColor)
                    .frame(width: 7, height: 7)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(agent.name)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    if let dir = agent.effectiveDirectory {
                        HStack(spacing: 3) {
                            Image(systemName: "folder")
                                .font(.system(size: 9))
                            Text(dir.lastPathComponent)
                                .font(.system(size: 10))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .foregroundStyle(Color.appSecondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(hovered ? Color.primary.opacity(0.08) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .pointingHandCursor()
    }
}

// MARK: - Sidebar Sheets Modifier

private struct SidebarSheetsModifier: ViewModifier {
    @Binding var showingNewSession: Bool
    @Binding var showingFullHistory: Bool
    @Binding var showingNewAgent: Bool
    @Binding var showingNewSkill: Bool
    @Binding var showingSkillUsageStats: Bool
    @Binding var aiCreationKind: AICreationKind?
    @Binding var showingNewSchedule: Bool
    @Binding var scheduleToEdit: AgentSchedule?
    @Binding var presetSheetConfig: PresetSheetConfig<ShellPreset>?
    @Binding var sessionPresetSheetConfig: PresetSheetConfig<SessionPreset>?

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $showingNewSession) {
                NewSessionSheet()
            }
            .sheet(isPresented: $showingFullHistory) {
                SessionHistoryView()
            }
            .sheet(isPresented: $showingNewAgent) {
                NewAgentSheet()
            }
            .sheet(isPresented: $showingNewSkill) {
                NewSkillSheet()
            }
            .sheet(isPresented: $showingSkillUsageStats) {
                SkillUsageStatsView()
            }
            .sheet(item: $aiCreationKind) { kind in
                AICreationSheet(kind: kind)
            }
            .sheet(isPresented: $showingNewSchedule) {
                NewScheduleSheet()
            }
            .sheet(item: $scheduleToEdit) { schedule in
                NewScheduleSheet(editingSchedule: schedule)
            }
            .sheet(item: $presetSheetConfig) { config in
                ShellPresetSheet(
                    editing: config.editing,
                    saveFromSession: config.saveFromSession
                )
            }
            .sheet(item: $sessionPresetSheetConfig) { config in
                SessionPresetSheet(
                    editing: config.editing,
                    saveFromSession: config.saveFromSession
                )
            }
    }
}

// MARK: - Sidebar Alerts Modifier

private struct SidebarAlertsModifier: ViewModifier {
    @Environment(AppState.self) private var appState
    @Environment(\.l10n) private var l10n
    @Binding var agentToDelete: Agent?
    @Binding var skillToDelete: Skill?
    @Binding var scheduleToDelete: AgentSchedule?

    func body(content: Content) -> some View {
        @Bindable var state = appState

        content
            .alert(l10n.delete + " " + l10n.agent, isPresented: .init(
                get: { agentToDelete != nil },
                set: { if !$0 { agentToDelete = nil } }
            )) {
                Button(l10n.cancel, role: .cancel) { agentToDelete = nil }
                Button(l10n.delete, role: .destructive) {
                    if let agent = agentToDelete {
                        appState.deleteAgent(agent)
                        agentToDelete = nil
                    }
                }
            } message: {
                if let agent = agentToDelete {
                    Text("Delete \"\(agent.name)\"? The file will be removed from disk.")
                }
            }
            .alert(l10n.delete + " " + l10n.skill, isPresented: .init(
                get: { skillToDelete != nil },
                set: { if !$0 { skillToDelete = nil } }
            )) {
                Button(l10n.cancel, role: .cancel) { skillToDelete = nil }
                Button(l10n.delete, role: .destructive) {
                    if let skill = skillToDelete {
                        appState.deleteSkill(skill)
                        skillToDelete = nil
                    }
                }
            } message: {
                if let skill = skillToDelete {
                    Text("Delete \"\(skill.name)\"? The directory will be removed from disk.")
                }
            }
            .alert(l10n.delete + " " + l10n.schedule, isPresented: .init(
                get: { scheduleToDelete != nil },
                set: { if !$0 { scheduleToDelete = nil } }
            )) {
                Button(l10n.cancel, role: .cancel) { scheduleToDelete = nil }
                Button(l10n.delete, role: .destructive) {
                    if let schedule = scheduleToDelete {
                        appState.scheduleManager.deleteSchedule(schedule)
                        scheduleToDelete = nil
                    }
                }
            } message: {
                if let schedule = scheduleToDelete {
                    Text("Delete schedule for \"\(schedule.agentName)\"?")
                }
            }
            .alert(
                state.fileCreationIsDirectory ? l10n.newFolder : l10n.newFile,
                isPresented: $state.showingFileCreationAlert
            ) {
                TextField(
                    state.fileCreationIsDirectory ? l10n.folderName : l10n.fileName,
                    text: $state.fileCreationName
                )
                Button(l10n.cancel, role: .cancel) {}
                Button(l10n.create) {
                    appState.confirmFileCreation()
                }
            }
    }
}
