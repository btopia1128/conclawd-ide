import SwiftUI

/// Right panel showing the selected agent's editable configuration.
struct AgentInspectorView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.l10n) private var l10n
    @Binding var showInspector: Bool
    @State private var showingToolPicker = false
    @State private var showingSubAgentPicker = false
    @State private var newToolName = ""
    @State private var showingNewSchedule = false
    @State private var editingSchedule: AgentSchedule?

    var body: some View {
        #if DEBUG
        let _ = Self._printChanges()
        #endif
        VStack(spacing: 0) {
            // Header
            HStack {
                Text(l10n.inspector)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.appSecondary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .frame(height: 32)
            .themedBackground(Color.appSurface)

            Divider()

            Group {
                if let agent = appState.selectedAgent {
                    inspectorContent(for: agent)
                } else {
                    emptyState
                }
            }
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "sidebar.right")
                .font(.system(size: 32))
                .foregroundStyle(Color.appTertiary)
            Text(l10n.selectAnAgent)
                .font(.subheadline)
                .foregroundStyle(Color.appSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Inspector Content

    private func inspectorContent(for agent: Agent) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    headerSection
                    sessionsSection(for: agent)
                    cardSection(l10n.configuration) { configSection }
                    cardSection(l10n.tools) { toolsSection }
                    MemoryCardView(agent: agent)
                    schedulesSection(for: agent)
                    if appState.centerPane != .agentEditor {
                        cardSection(l10n.agentDefinition) { promptSection }
                    }
                }
                .padding(12)
            }

            // Sticky bottom actions
            actionsSection
        }
    }

    // MARK: - Header

    @ViewBuilder
    private var headerSection: some View {
        if let agent = appState.editingAgent {
            HStack(spacing: 10) {
                // Color indicator
                RoundedRectangle(cornerRadius: 4)
                    .fill(agent.color.swiftUIColor)
                    .frame(width: 4, height: 32)

                VStack(alignment: .leading, spacing: 2) {
                    Text(agent.name)
                        .font(.system(size: 15, weight: .semibold))
                    if !agent.description.isEmpty {
                        Text(agent.description)
                            .font(.system(size: 11))
                            .foregroundStyle(Color.appSecondary)
                            .lineLimit(2)
                    }
                }

                Spacer()

                Text(agent.model == .inherit ? l10n.defaultLabel : agent.model.displayName(for: agent.defaultProvider))
                    .font(.system(size: 10, weight: .medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(.fill.tertiary)
                    .cornerRadius(4)
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Configuration

    @ViewBuilder
    private var configSection: some View {
        if appState.editingAgent != nil {
            let isManual = appState.editingAgent?.rawCommand != nil

            VStack(alignment: .leading, spacing: 12) {
                // Manual toggle
                HStack {
                    Spacer()
                    Toggle(l10n.manual, isOn: Binding(
                        get: { appState.editingAgent?.rawCommand != nil },
                        set: { newValue in
                            if newValue {
                                appState.editingAgent?.rawCommand = ""
                            } else {
                                appState.editingAgent?.rawCommand = nil
                            }
                        }
                    ))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                }

                fieldRow(l10n.name) {
                    TextField(l10n.agentName, text: binding(\.name))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                }

                fieldRow(l10n.description) {
                    TextEditor(text: binding(\.description))
                        .font(.system(size: 12))
                        .scrollContentBackground(.hidden)
                        .padding(4)
                        .themedBackground(Color.appWindowBackground)
                        .cornerRadius(6)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(.separator, lineWidth: 1)
                        )
                        .frame(height: 5 * 18)
                        .filePathDrop(text: binding(\.description))
                }

                if isManual {
                    // Manual mode: raw command input
                    fieldRow(l10n.command) {
                        VStack(alignment: .leading, spacing: 4) {
                            TextEditor(text: Binding(
                                get: { appState.editingAgent?.rawCommand ?? "" },
                                set: { appState.editingAgent?.rawCommand = $0 }
                            ))
                            .font(.system(size: 12, design: .monospaced))
                            .scrollContentBackground(.hidden)
                            .padding(4)
                            .background(Color.secondary.opacity(0.08))
                            .cornerRadius(6)
                            .frame(minHeight: 60, maxHeight: 120)

                            Text(l10n.commandPlaceholder)
                                .font(.system(size: 9))
                                .foregroundStyle(Color.appTertiary)
                        }
                    }
                } else {
                    // Config mode: individual fields
                    if appState.availableCLIProviders.count > 1 {
                        fieldRow("CLI") {
                            Picker("", selection: Binding(
                                get: { appState.editingAgent?.defaultProvider ?? .claude },
                                set: { newProvider in
                                    appState.editingAgent?.defaultProvider = newProvider
                                    if let current = appState.editingAgent?.model,
                                       !AgentModel.allCases(for: newProvider).contains(current) {
                                        appState.editingAgent?.model = .inherit
                                    }
                                }
                            )) {
                                ForEach(CLIProviderType.allCases, id: \.self) { provider in
                                    Text(provider.displayName).tag(provider)
                                }
                            }
                            .labelsHidden()
                            .controlSize(.small)
                        }
                    }

                    HStack(spacing: 12) {
                        fieldRow(l10n.model) {
                            let currentProvider = appState.editingAgent?.defaultProvider ?? .claude
                            Picker("", selection: Binding(
                                get: { appState.editingAgent?.model ?? .inherit },
                                set: { appState.editingAgent?.model = $0 }
                            )) {
                                ForEach(AgentModel.allCases(for: currentProvider), id: \.self) { model in
                                    Text(model == .inherit ? l10n.defaultLabel : model.displayName(for: currentProvider)).tag(model)
                                }
                            }
                            .labelsHidden()
                            .controlSize(.small)
                        }

                        fieldRow(l10n.color) {
                            Picker("", selection: Binding(
                                get: { appState.editingAgent?.color ?? .blue },
                                set: { appState.editingAgent?.color = $0 }
                            )) {
                                ForEach(AgentColor.allCases, id: \.self) { color in
                                    HStack(spacing: 4) {
                                        Circle().fill(color.swiftUIColor).frame(width: 6, height: 6)
                                        Text(color.displayName)
                                    }
                                    .tag(color)
                                }
                            }
                            .labelsHidden()
                            .controlSize(.small)
                        }
                    }

                    HStack(spacing: 12) {
                        fieldRow(l10n.permission) {
                            Picker("", selection: Binding(
                                get: { appState.editingAgent?.permissionMode ?? .default },
                                set: { appState.editingAgent?.permissionMode = $0 }
                            )) {
                                ForEach(PermissionMode.allCases, id: \.self) { mode in
                                    Text(mode.displayName).tag(mode)
                                }
                            }
                            .labelsHidden()
                            .controlSize(.small)
                        }

                        fieldRow(l10n.maxTurns) {
                            TextField("–", value: Binding(
                                get: { appState.editingAgent?.maxTurns },
                                set: { appState.editingAgent?.maxTurns = $0 }
                            ), format: .number)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12))
                        }
                    }

                    fieldRow(l10n.customFlags) {
                        TextField(l10n.customFlagsPlaceholder, text: binding(\.customFlags))
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))
                    }
                }

                fieldRow(l10n.directory) {
                    HStack(spacing: 6) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(appState.editingAgent?.effectiveDirectory?.path(percentEncoded: false) ?? l10n.projectRoot)
                                .font(.system(size: 11))
                                .foregroundStyle(Color.appSecondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: .infinity, alignment: .leading)

                            if appState.editingAgent?.localDirectory != nil {
                                Text(l10n.localOverride)
                                    .font(.system(size: 9))
                                    .foregroundStyle(.orange)
                            } else if appState.editingAgent?.currentDirectory != nil {
                                Text(l10n.fromMdFile)
                                    .font(.system(size: 9))
                                    .foregroundStyle(Color.appTertiary)
                            }
                        }

                        Button {
                            pickWorkingDirectory()
                        } label: {
                            Image(systemName: "folder")
                                .font(.system(size: 10))
                        }
                        .controlSize(.small)
                        .pointingHandCursor()

                        if appState.editingAgent?.localDirectory != nil {
                            Button {
                                appState.editingAgent?.localDirectory = nil
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 10))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(Color.appSecondary)
                            .help(l10n.clearLocalOverride)
                            .pointingHandCursor()
                        }
                    }
                }
            }
        }
    }

    // MARK: - Tools

    @ViewBuilder
    private var toolsSection: some View {
        if let agent = appState.editingAgent {
            VStack(alignment: .leading, spacing: 10) {
                // Tools tags
                if agent.tools.isEmpty {
                    Text(l10n.noToolsConfigured)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.appTertiary)
                } else {
                    TagListView(
                        tags: agent.tools,
                        onRemove: { index in
                            appState.editingAgent?.tools.remove(at: index)
                        }
                    )
                }

                // Add tool button
                Button {
                    showingToolPicker = true
                } label: {
                    Label(l10n.addTool, systemImage: "plus")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .pointingHandCursor()
                .popover(isPresented: $showingToolPicker) {
                    toolPickerPopover
                }

                // Sub-Agents
                Divider()
                Text(l10n.subAgents)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.appSecondary)
                    .textCase(.uppercase)

                ForEach(agent.subAgentNames, id: \.self) { name in
                    HStack(spacing: 6) {
                        Image(systemName: "person.crop.circle")
                            .font(.system(size: 10))
                            .foregroundStyle(Color.appSecondary)
                        Text(name)
                            .font(.system(size: 12))
                        Spacer()
                        Button {
                            removeSubAgent(name: name)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 10))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.appSecondary)
                        .pointingHandCursor()
                    }
                }

                // Add sub-agent button
                Button {
                    showingSubAgentPicker = true
                } label: {
                    Label(l10n.addSubAgent, systemImage: "plus")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .pointingHandCursor()
                .popover(isPresented: $showingSubAgentPicker) {
                    subAgentPickerPopover
                }
            }
        }
    }

    // MARK: - Sub-Agent Management

    private func removeSubAgent(name: String) {
        guard appState.editingAgent != nil else { return }
        for i in stride(from: appState.editingAgent!.tools.count - 1, through: 0, by: -1) {
            let tool = appState.editingAgent!.tools[i]
            guard tool.hasPrefix("Agent(") && tool.hasSuffix(")") else { continue }
            let inner = String(tool.dropFirst(6).dropLast(1))
            var names = inner.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            guard names.contains(name) else { continue }
            names.removeAll { $0 == name }
            if names.isEmpty {
                appState.editingAgent!.tools.remove(at: i)
            } else {
                appState.editingAgent!.tools[i] = "Agent(\(names.joined(separator: ", ")))"
            }
        }
    }

    private func addSubAgent(name: String) {
        guard appState.editingAgent != nil else { return }

        // Check for cycles
        if let childId = appState.agents.first(where: { $0.name == name })?.id {
            let wouldCycle = appState.relationService.wouldCreateCycle(
                agents: appState.agents,
                parentId: appState.editingAgent!.id,
                childId: childId
            )
            guard !wouldCycle else {
                appState.errorMessage = l10n.cycleDetected
                return
            }
        }

        // If tools is empty, populate with defaults to avoid restricting to only Agent(child)
        if appState.editingAgent!.tools.isEmpty {
            appState.editingAgent!.tools = AgentRelationService.defaultTools
        }

        let agentToolIndex = appState.editingAgent!.tools.firstIndex {
            $0.hasPrefix("Agent(") && $0.hasSuffix(")")
        }

        if let index = agentToolIndex {
            let existing = appState.editingAgent!.tools[index]
            let inner = String(existing.dropFirst(6).dropLast(1))
            let names = inner.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            guard !names.contains(name) else { return }
            let updated = names + [name]
            appState.editingAgent!.tools[index] = "Agent(\(updated.joined(separator: ", ")))"
        } else {
            appState.editingAgent!.tools.append("Agent(\(name))")
        }

        showingSubAgentPicker = false
    }

    private var subAgentPickerPopover: some View {
        VStack(alignment: .leading, spacing: 6) {
            let currentSubAgentNames = Set(appState.editingAgent?.subAgentNames ?? [])
            let availableAgents = appState.agents.filter { candidate in
                candidate.name != appState.editingAgent?.name &&
                !currentSubAgentNames.contains(candidate.name)
            }

            if availableAgents.isEmpty {
                Text(l10n.noAvailableSubAgents)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.appTertiary)
                    .padding(.vertical, 4)
            } else {
                ForEach(availableAgents, id: \.id) { agent in
                    Button {
                        addSubAgent(name: agent.name)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "person.crop.circle")
                                .font(.system(size: 10))
                            Text(agent.name)
                                .font(.system(size: 12))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor()
                }
            }
        }
        .padding(10)
        .frame(width: 200)
    }

    // MARK: - Sessions

    private func sessionsSection(for agent: Agent) -> some View {
        let sessions = appState.activeSessions.filter { $0.agentId == agent.id && !$0.isCreationSession }

        return cardSection(l10n.sessions) {
            if sessions.isEmpty {
                Button {
                    appState.startAgent(agent)
                    appState.sidebarTab = .sessions
                } label: {
                    Label(l10n.startSession, systemImage: "play.fill")
                        .font(.system(size: 12))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .pointingHandCursor()
            } else {
                VStack(spacing: 4) {
                    ForEach(sessions, id: \.id) { session in
                        sessionRow(session, in: sessions)
                    }

                    Button {
                        appState.startAgent(agent)
                        appState.sidebarTab = .sessions
                    } label: {
                        Label(l10n.newSession, systemImage: "plus")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    .pointingHandCursor()
                    .padding(.top, 4)
                }
            }
        }
    }

    private func sessionRow(_ session: AgentSession, in sessions: [AgentSession]) -> some View {
        let isSelected = appState.selectedSessionId == session.id
        let status: AgentProcessStatus = session.displayMode == .chat
            ? (appState.chatManagers[session.id]?.isProcessing == true ? .running : .waitingForInput)
            : appState.processManager.status(sessionId: session.id)
        let displayName: String = {
            if sessions.count > 1,
               let index = sessions.firstIndex(where: { $0.id == session.id }) {
                return "\(session.agentName) #\(index + 1)"
            }
            return session.agentName
        }()

        return HStack(spacing: 6) {
            Image(systemName: sessionStatusIconName(status))
                .font(.system(size: 10))
                .foregroundStyle(sessionStatusColor(status))
                .symbolEffect(.pulse, options: .repeating, isActive: status == .running)

            Text(displayName)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)

            Spacer()

            Text(sessionStatusText(status))
                .font(.system(size: 9))
                .foregroundStyle(sessionStatusTextColor(status))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(isSelected ? Color.accentColor.opacity(0.15) : .clear)
        )
        .contentShape(RoundedRectangle(cornerRadius: 5))
        .pointingHandCursor()
        .onTapGesture {
            appState.selectedSessionId = session.id
            appState.centerPane = .terminal
            appState.sidebarTab = .sessions
        }
    }

    private func sessionStatusIconName(_ status: AgentProcessStatus) -> String {
        switch status {
        case .running: return "bolt.fill"
        case .waitingForInput: return "checkmark.circle.fill"
        case .stopped: return "stop.circle"
        }
    }

    private func sessionStatusColor(_ status: AgentProcessStatus) -> Color {
        switch status {
        case .running: return .statusRunning
        case .waitingForInput: return .statusReady
        case .stopped: return .statusStopped
        }
    }

    private func sessionStatusText(_ status: AgentProcessStatus) -> String {
        switch status {
        case .running: return l10n.thinking
        case .waitingForInput: return l10n.ready
        case .stopped: return l10n.stopped
        }
    }

    private func sessionStatusTextColor(_ status: AgentProcessStatus) -> Color {
        switch status {
        case .running: return .statusRunning
        case .waitingForInput: return .statusReady
        case .stopped: return .statusStopped
        }
    }

    // MARK: - Schedules

    private func schedulesSection(for agent: Agent) -> some View {
        let schedules = appState.scheduleManager.schedulesForAgent(name: agent.name)

        return cardSection(l10n.schedules) {
            if schedules.isEmpty {
                Button {
                    showingNewSchedule = true
                } label: {
                    Label(l10n.addSchedule, systemImage: "clock.badge.plus")
                        .font(.system(size: 12))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .pointingHandCursor()
            } else {
                VStack(spacing: 4) {
                    ForEach(schedules) { schedule in
                        scheduleRow(schedule)
                    }

                    Button {
                        showingNewSchedule = true
                    } label: {
                        Label(l10n.addSchedule, systemImage: "plus")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    .pointingHandCursor()
                    .padding(.top, 4)
                }
            }
        }
        .sheet(isPresented: $showingNewSchedule) {
            if let agent = appState.selectedAgent {
                NewScheduleSheet(preselectedAgentName: agent.name)
            }
        }
        .sheet(item: $editingSchedule) { schedule in
            NewScheduleSheet(editingSchedule: schedule)
        }
    }

    private func scheduleRow(_ schedule: AgentSchedule) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(schedule.isEnabled ? Color.green : Color.statusStopped)
                .frame(width: 6, height: 6)

            Image(systemName: schedule.scheduleType.icon)
                .font(.system(size: 9))
                .foregroundStyle(Color.appSecondary)

            Text(schedule.scheduleType.displayName)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)

            Spacer()

            // Active session count
            let activeCount = appState.scheduleManager.scheduledSessionIds[schedule.id]?.count ?? 0
            if activeCount > 0 {
                Text("\(activeCount)")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 14, height: 14)
                    .background(Color.orange)
                    .clipShape(Circle())
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 5).fill(.fill.quinary))
        .contentShape(RoundedRectangle(cornerRadius: 5))
        .pointingHandCursor()
        .onTapGesture {
            appState.showScheduleEditor(schedule)
        }
        .contextMenu {
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
                editingSchedule = schedule
            }
            Divider()
            Button(l10n.delete, role: .destructive) {
                appState.scheduleManager.deleteSchedule(schedule)
            }
        }
    }

    // MARK: - System Prompt

    @ViewBuilder
    private var promptSection: some View {
        let promptBinding = Binding(
            get: { appState.editingAgent?.systemPrompt ?? "" },
            set: { appState.editingAgent?.systemPrompt = $0 }
        )
        TextEditor(text: promptBinding)
            .font(.system(size: 11, design: .monospaced))
            .scrollContentBackground(.hidden)
            .padding(6)
            .background(.fill.quinary)
            .cornerRadius(6)
            .frame(minHeight: 120)
            .filePathDrop(text: promptBinding)
    }

    // MARK: - Actions

    private var actionsSection: some View {
        HStack(spacing: 8) {
            Button(l10n.revert) {
                appState.revertEditingAgent()
            }
            .controlSize(.small)
            .disabled(!appState.agentHasChanges)
            .pointingHandCursor()

            Spacer()

            Button(l10n.save) {
                appState.saveEditingAgent()
            }
            .controlSize(.small)
            .buttonStyle(.borderedProminent)
            .disabled(!appState.agentHasChanges)
            .pointingHandCursor()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .themedBackground(Color.appSurface)
    }

    // MARK: - Helpers

    /// Reusable card section with title and content.
    private func cardSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Color.appSecondary)
                .textCase(.uppercase)

            content()
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.fill.quinary)
        .cornerRadius(8)
    }

    /// Reusable vertical field row (label above, value below).
    private func fieldRow<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(Color.appSecondary)
            content()
        }
    }

    // MARK: - Tool Picker

    private var toolPickerPopover: some View {
        VStack(alignment: .leading, spacing: 6) {
            let commonTools = ["Read", "Edit", "Write", "Bash", "Grep", "Glob", "WebSearch", "WebFetch"]
            let currentTools = Set(appState.editingAgent?.tools ?? [])

            ForEach(commonTools.filter { !currentTools.contains($0) }, id: \.self) { tool in
                Button {
                    appState.editingAgent?.tools.append(tool)
                    showingToolPicker = false
                } label: {
                    Text(tool)
                        .font(.system(size: 12))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
            }

            Divider()

            HStack(spacing: 4) {
                TextField(l10n.custom, text: $newToolName)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
                Button(l10n.add) {
                    let trimmed = newToolName.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.isEmpty else { return }
                    appState.editingAgent?.tools.append(trimmed)
                    newToolName = ""
                    showingToolPicker = false
                }
                .controlSize(.small)
                .disabled(newToolName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(10)
        .frame(width: 180)
    }

    // MARK: - Working Directory Picker

    private func pickWorkingDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = l10n.selectWorkingDirectory

        if panel.runModal() == .OK, let url = panel.url {
            appState.editingAgent?.localDirectory = url
        }
    }

    private func binding(_ keyPath: WritableKeyPath<Agent, String>) -> Binding<String> {
        Binding(
            get: { appState.editingAgent?[keyPath: keyPath] ?? "" },
            set: { appState.editingAgent?[keyPath: keyPath] = $0 }
        )
    }
}

// MARK: - Tag List View

struct TagListView: View {
    let tags: [String]
    var onRemove: ((Int) -> Void)?

    var body: some View {
        #if DEBUG
        let _ = Self._printChanges()
        #endif
        FlowLayout(spacing: 4) {
            ForEach(Array(tags.enumerated()), id: \.offset) { index, tag in
                HStack(spacing: 4) {
                    Text(tag)
                        .font(.system(size: 11))

                    if let onRemove {
                        Button {
                            onRemove(index)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 7, weight: .bold))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.appSecondary)
                        .pointingHandCursor()
                    }
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(.fill.tertiary)
                .cornerRadius(4)
            }
        }
    }
}

// MARK: - Flow Layout

struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = computeLayout(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = computeLayout(proposal: proposal, subviews: subviews)
        for (index, offset) in result.offsets.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + offset.x, y: bounds.minY + offset.y), proposal: .unspecified)
        }
    }

    private func computeLayout(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, offsets: [CGPoint]) {
        let maxWidth = proposal.width ?? .infinity
        var offsets: [CGPoint] = []
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var lineHeight: CGFloat = 0
        var maxX: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX + size.width > maxWidth && currentX > 0 {
                currentX = 0
                currentY += lineHeight + spacing
                lineHeight = 0
            }
            offsets.append(CGPoint(x: currentX, y: currentY))
            lineHeight = max(lineHeight, size.height)
            currentX += size.width + spacing
            maxX = max(maxX, currentX)
        }

        return (CGSize(width: maxX, height: currentY + lineHeight), offsets)
    }
}
