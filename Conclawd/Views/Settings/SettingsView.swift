import SwiftUI

/// Settings view displayed in the center pane with sidebar navigation.
struct SettingsView: View {
    @Environment(\.l10n) private var l10n
    @State private var selectedTab: SettingsTab = .general

    enum SettingsTab: String, CaseIterable, Identifiable {
        case general
        case terminal
        case agents
        case notifications

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .general: return "gear"
            case .terminal: return "terminal"
            case .agents: return "person.2"
            case .notifications: return "bell"
            }
        }

        func displayName(_ l10n: L10n) -> String {
            switch self {
            case .general: return l10n.general
            case .terminal: return l10n.terminal
            case .agents: return l10n.agents
            case .notifications: return l10n.notifications
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            // Sidebar
            VStack(alignment: .leading, spacing: 2) {
                ForEach(SettingsTab.allCases) { tab in
                    HStack(spacing: 8) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 13))
                            .frame(width: 20)
                            .foregroundStyle(selectedTab == tab ? Color.accentColor : Color.appSecondary)

                        Text(tab.displayName(l10n))
                            .font(.system(size: 13))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 7)
                    .padding(.horizontal, 10)
                    .background(
                        selectedTab == tab
                            ? Color.accentColor.opacity(0.12)
                            : Color.clear,
                        in: RoundedRectangle(cornerRadius: 6)
                    )
                    .foregroundStyle(selectedTab == tab ? .primary : Color.appSecondary)
                    .contentShape(Rectangle())
                    .pointingHandCursor()
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.15)) { selectedTab = tab }
                    }
                }

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 16)
            .frame(width: 170)
            .themedBackground(Color.appWindowBackground)

            Divider()

            // Content
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    switch selectedTab {
                    case .general:
                        GeneralSettingsSection()
                    case .terminal:
                        TerminalSettingsSection()
                    case .agents:
                        AgentSettingsSection()
                    case .notifications:
                        NotificationSettingsSection()
                    }
                }
                .frame(maxWidth: 640, alignment: .leading)
                .padding(.horizontal, 32)
                .padding(.vertical, 28)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .themedBackground(Color.appWindowBackground)
        }
        .themedBackground(Color.appWindowBackground)
        .onHover { hovering in
            if hovering { NSCursor.arrow.push() } else { NSCursor.pop() }
        }
    }
}

// MARK: - General

private struct GeneralSettingsSection: View {
    @Environment(\.l10n) private var l10n
    @Environment(AppState.self) private var appState
    @AppStorage("appearanceMode") private var appearanceMode: String = AppearanceMode.dark.rawValue
    @AppStorage("appLanguage") private var appLanguage: String = AppLanguage.en.rawValue
    @AppStorage(AppState.initialProjectKey) private var initialProject: String = "home"

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text(l10n.general)
                .font(.title2)
                .fontWeight(.bold)

            // Language
            SettingsGroup(l10n.language) {
                SettingsRow(l10n.language) {
                    Picker("", selection: $appLanguage) {
                        ForEach(AppLanguage.allCases, id: \.self) { lang in
                            Text(lang.displayName).tag(lang.rawValue)
                        }
                    }
                    .frame(width: 200)
                    .labelsHidden()
                }
            }

            // Appearance
            SettingsGroup(l10n.appearance) {
                SettingsRow(l10n.theme) {
                    Picker("", selection: $appearanceMode) {
                        ForEach(AppearanceMode.allCases, id: \.self) { mode in
                            Text(mode.displayName(l10n)).tag(mode.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 280)
                    .labelsHidden()
                }
            }

            // Startup
            SettingsGroup(l10n.startup) {
                SettingsRow(l10n.initialProject) {
                    Picker("", selection: $initialProject) {
                        Text(l10n.home).tag("home")
                        Text(l10n.allProjects).tag("all")

                        if !appState.projects.isEmpty {
                            Divider()
                            ForEach(appState.projects) { project in
                                Text(project.name).tag(project.directoryPath.path(percentEncoded: false))
                            }
                        }

                        // Show browsed path if it's not in recent projects
                        if isBrowsedPath {
                            Divider()
                            Text(browseDisplayName).tag(initialProject)
                        }

                        Divider()
                        Label(l10n.openProject, systemImage: "folder.badge.plus").tag("__browse__")
                    }
                    .frame(width: 200)
                    .labelsHidden()
                    .onChange(of: initialProject) { oldValue, newValue in
                        if newValue == "__browse__" {
                            initialProject = oldValue
                            browseForProject()
                        }
                    }
                }

                Text(l10n.projectShownOnLaunch)
                    .font(.caption)
                    .foregroundStyle(Color.appSecondary)
                    .padding(.leading, SettingsLayout.helpTextLeading)
            }

            // Sidebar
            SidebarTabsSection()

            // Claude CLI
            ClaudeCLISection()
        }
    }

    /// Whether the current initialProject value is a browsed path not in recent projects.
    private var isBrowsedPath: Bool {
        guard initialProject != "home", initialProject != "all" else { return false }
        return !appState.projects.contains { $0.directoryPath.path(percentEncoded: false) == initialProject }
    }

    /// Display name for a browsed path (last path component).
    private var browseDisplayName: String {
        URL(fileURLWithPath: initialProject).lastPathComponent
    }

    private func browseForProject() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Select a project directory"

        if panel.runModal() == .OK, let url = panel.url {
            initialProject = url.path(percentEncoded: false)
        }
    }
}

private struct ClaudeCLISection: View {
    @Environment(\.l10n) private var l10n
    @AppStorage(ClaudePathResolver.manualPathKey) private var claudeBinaryPath: String = ""
    @State private var detectedClaudePath: String?

    var body: some View {
        SettingsGroup(l10n.claudeCLI) {
            VStack(alignment: .leading, spacing: 8) {
                SettingsRow(l10n.binaryPath) {
                    HStack(spacing: 8) {
                        TextField(l10n.autoDetectIfEmpty, text: $claudeBinaryPath)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 300)

                        Button(l10n.browse) {
                            browseClaude()
                        }
                        .pointingHandCursor()
                    }
                }

                pathStatus
                    .padding(.leading, SettingsLayout.helpTextLeading)
            }
        }
        .onAppear {
            detectedClaudePath = ClaudePathResolver().resolve()
        }
    }

    @ViewBuilder
    private var pathStatus: some View {
        if claudeBinaryPath.isEmpty {
            if let detected = detectedClaudePath {
                Label("\(l10n.autoDetected): \(detected)", systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(.green)
            } else {
                Label(l10n.claudeBinaryNotFound, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        } else if FileManager.default.isExecutableFile(atPath: claudeBinaryPath) {
            Label(l10n.validExecutable, systemImage: "checkmark.circle")
                .font(.caption)
                .foregroundStyle(.green)
        } else {
            Label(l10n.fileNotFoundOrNotExecutable, systemImage: "xmark.circle")
                .font(.caption)
                .foregroundStyle(.red)
        }
    }

    private func browseClaude() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = l10n.selectClaudeBinary
        panel.directoryURL = URL(fileURLWithPath: "/usr/local/bin")

        if panel.runModal() == .OK, let url = panel.url {
            claudeBinaryPath = url.path(percentEncoded: false)
        }
    }
}

// MARK: - Sidebar Tabs

private struct SidebarTabsSection: View {
    @Environment(\.l10n) private var l10n
    @AppStorage("sidebarTabOrder") private var tabOrderRaw: String = "Sessions,Agents,Skills,Schedules,Files,Shells"
    @State private var draggedTab: AppState.SidebarTab?

    private var orderedTabs: [AppState.SidebarTab] {
        let raw = tabOrderRaw.split(separator: ",").map(String.init)
        var tabs = raw.compactMap { AppState.SidebarTab(rawValue: $0) }
        // Append any missing tabs (e.g. newly added ones)
        let existing = Set(tabs)
        for tab in AppState.SidebarTab.allCases where !existing.contains(tab) {
            tabs.append(tab)
        }
        return tabs
    }

    private func moveTab(from: AppState.SidebarTab, to: AppState.SidebarTab) {
        var list = orderedTabs
        guard let fromIdx = list.firstIndex(of: from),
              fromIdx != list.firstIndex(of: to) else { return }
        let item = list.remove(at: fromIdx)
        let insertAt = list.firstIndex(of: to) ?? list.endIndex
        list.insert(item, at: insertAt)
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

    var body: some View {
        SettingsGroup(l10n.sidebar) {
            let tabs = orderedTabs
            VStack(alignment: .leading, spacing: 4) {
                ForEach(tabs, id: \.self) { tab in
                    let index = tabs.firstIndex(of: tab) ?? 0
                    let visible = index < 4

                    HStack(spacing: 10) {
                        Image(systemName: "line.3.horizontal")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.appTertiary)
                            .frame(width: 14)

                        Image(systemName: tab.icon)
                            .font(.system(size: 13))
                            .frame(width: 20)
                            .foregroundStyle(visible ? .primary : Color.appTertiary)

                        Text(tabLabel(tab))
                            .font(.system(size: 13))
                            .foregroundStyle(visible ? .primary : Color.appTertiary)

                        Spacer()

                        if visible {
                            Text("\(index + 1)")
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .foregroundStyle(Color.appTertiary)
                        }
                    }
                    .padding(.vertical, 2)
                    .contentShape(Rectangle())
                    .opacity(draggedTab == tab ? 0.4 : 1)
                    .onDrag {
                        draggedTab = tab
                        return NSItemProvider(object: tab.rawValue as NSString)
                    }
                    .onDrop(of: [.text], delegate: SidebarTabReorderDelegate(
                        targetTab: tab,
                        draggedTab: $draggedTab,
                        onMove: moveTab
                    ))
                }

                Divider()
                    .padding(.vertical, 2)
            }

            Text(l10n.sidebarTabsDesc)
                .font(.caption)
                .foregroundStyle(Color.appSecondary)
                .padding(.leading, SettingsLayout.helpTextLeading)
        }
    }
}

private struct SidebarTabReorderDelegate: DropDelegate {
    let targetTab: AppState.SidebarTab
    @Binding var draggedTab: AppState.SidebarTab?
    let onMove: (AppState.SidebarTab, AppState.SidebarTab) -> Void

    func performDrop(info: DropInfo) -> Bool {
        draggedTab = nil
        return true
    }

    func dropEntered(info: DropInfo) {
        guard let from = draggedTab, from != targetTab else { return }
        withAnimation(.default) {
            onMove(from, targetTab)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }
}

// MARK: - Terminal

private struct TerminalSettingsSection: View {
    @Environment(AppState.self) private var appState
    @Environment(\.l10n) private var l10n
    @AppStorage("terminalFontSize") private var terminalFontSize: Double = 13
    @AppStorage("terminalCursorStyle") private var cursorStyle: String = TerminalCursorStyleSetting.block.rawValue
    @AppStorage("terminalColorScheme") private var termColorScheme: String = TerminalColorScheme.default.rawValue

    var body: some View {
        @Bindable var state = appState

        VStack(alignment: .leading, spacing: 24) {
            Text(l10n.terminal)
                .font(.title2)
                .fontWeight(.bold)

            SettingsGroup(l10n.editor) {
                SettingsRow(l10n.lineNumbers) {
                    Toggle("", isOn: $state.editorShowLineNumbers)
                        .labelsHidden()
                }

                SettingsRow(l10n.wordWrap) {
                    Toggle("", isOn: $state.editorWordWrap)
                        .labelsHidden()
                }
            }

            SettingsGroup(l10n.font) {
                SettingsRow(l10n.size) {
                    HStack(spacing: 8) {
                        Slider(value: $terminalFontSize, in: 9...24, step: 1)
                            .frame(width: 200)

                        Text("\(Int(terminalFontSize)) pt")
                            .monospacedDigit()
                            .foregroundStyle(Color.appSecondary)
                            .frame(width: 40, alignment: .trailing)
                    }
                }
            }

            SettingsGroup(l10n.cursor) {
                SettingsRow(l10n.style) {
                    Picker("", selection: $cursorStyle) {
                        ForEach(TerminalCursorStyleSetting.allCases, id: \.self) { style in
                            Text(style.displayName(l10n)).tag(style.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 200)
                    .labelsHidden()
                }
            }

            SettingsGroup(l10n.colorScheme) {
                SettingsRow(l10n.scheme) {
                    Picker("", selection: $termColorScheme) {
                        ForEach(TerminalColorScheme.allCases, id: \.self) { scheme in
                            Text(scheme.displayName).tag(scheme.rawValue)
                        }
                    }
                    .frame(width: 200)
                    .labelsHidden()
                }

                if let scheme = TerminalColorScheme(rawValue: termColorScheme) {
                    colorPreview(scheme.theme)
                        .padding(.leading, SettingsLayout.helpTextLeading)
                }
            }
        }
    }

    private func colorPreview(_ theme: TerminalTheme) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color(nsColor: theme.background))
                .frame(width: 60, height: 30)
                .overlay(
                    Text("Aa")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Color(nsColor: theme.foreground))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(.quaternary, lineWidth: 1)
                )
        }
    }
}

// MARK: - Agents

private struct AgentSettingsSection: View {
    @Environment(\.l10n) private var l10n
    @Environment(AppState.self) private var appState
    @AppStorage("defaultModel") private var defaultModel: String = AgentModel.inherit.rawValue
    @AppStorage("maxConcurrentAgents") private var maxConcurrentAgents: Int = 0
    @AppStorage(AppState.memoryExtractionProviderKey) private var memoryProvider: String = "claude"
    @AppStorage(AppState.commitMessageProviderKey) private var commitProvider: String = "claude"
    @State private var skillTrackingEnabled = false
    @State private var codexSyncEnabled = false

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text(l10n.agents)
                .font(.title2)
                .fontWeight(.bold)

            SettingsGroup(l10n.model) {
                SettingsRow(l10n.defaultLabel) {
                    Picker("", selection: $defaultModel) {
                        Text(l10n.noneUseCLIDefault).tag(AgentModel.inherit.rawValue)
                        ForEach(AgentModel.allCases.filter { $0 != .inherit }, id: \.rawValue) { model in
                            Text(model.displayName).tag(model.rawValue)
                        }
                    }
                    .frame(width: 200)
                    .labelsHidden()
                }

                Text(l10n.appliedWhenInherit)
                    .font(.caption)
                    .foregroundStyle(Color.appSecondary)
                    .padding(.leading, SettingsLayout.helpTextLeading)
            }

            SettingsGroup(l10n.concurrency) {
                SettingsRow(l10n.maxSessions) {
                    HStack(spacing: 8) {
                        Picker("", selection: $maxConcurrentAgents) {
                            Text(l10n.unlimited).tag(0)
                            ForEach([1, 2, 3, 4, 5, 8, 10], id: \.self) { n in
                                Text("\(n)").tag(n)
                            }
                        }
                        .frame(width: 200)
                        .labelsHidden()
                    }
                }

                Text(l10n.limitsMaxSessions)
                    .font(.caption)
                    .foregroundStyle(Color.appSecondary)
                    .padding(.leading, SettingsLayout.helpTextLeading)
            }

            SettingsGroup(l10n.skillUsageTracking) {
                SettingsRow(l10n.trackSkillUsage) {
                    Toggle("", isOn: $skillTrackingEnabled)
                        .labelsHidden()
                        .onChange(of: skillTrackingEnabled) {
                            if skillTrackingEnabled {
                                appState.skillUsageService.installHook()
                            } else {
                                appState.skillUsageService.uninstallHook()
                            }
                        }
                }

                Text(l10n.skillUsageTrackingDesc)
                    .font(.caption)
                    .foregroundStyle(Color.appSecondary)
                    .padding(.leading, SettingsLayout.helpTextLeading)
            }

            SettingsGroup(l10n.codexIntegration) {
                SettingsRow(l10n.codexSkillSync) {
                    Toggle("", isOn: $codexSyncEnabled)
                        .labelsHidden()
                        .onChange(of: codexSyncEnabled) {
                            if codexSyncEnabled {
                                appState.codexSyncService.enable()
                            } else {
                                appState.codexSyncService.disable()
                            }
                        }
                }

                Text(l10n.codexSkillSyncDesc)
                    .font(.caption)
                    .foregroundStyle(Color.appSecondary)
                    .padding(.leading, SettingsLayout.helpTextLeading)
            }

            SettingsGroup(l10n.backgroundTasks) {
                SettingsRow(l10n.memoryExtractionProvider) {
                    Picker("", selection: $memoryProvider) {
                        Text(l10n.createForClaudeCode).tag("claude")
                        Text(l10n.createForCodex).tag("codex")
                    }
                    .frame(width: 200)
                    .labelsHidden()
                }

                SettingsRow(l10n.commitMessageProvider) {
                    Picker("", selection: $commitProvider) {
                        Text(l10n.createForClaudeCode).tag("claude")
                        Text(l10n.createForCodex).tag("codex")
                    }
                    .frame(width: 200)
                    .labelsHidden()
                }

                Text(l10n.backgroundTasksDesc)
                    .font(.caption)
                    .foregroundStyle(Color.appSecondary)
                    .padding(.leading, SettingsLayout.helpTextLeading)
            }
        }
        .onAppear {
            skillTrackingEnabled = appState.skillUsageService.isHookInstalled
            codexSyncEnabled = appState.codexSyncService.isEnabled
        }
    }
}

// MARK: - Notifications

private struct NotificationSettingsSection: View {
    @Environment(\.l10n) private var l10n
    private let service = ClaudeSettingsService.shared

    private static let macSounds = [
        "Glass", "Ping", "Pop", "Purr", "Tink",
        "Basso", "Blow", "Bottle", "Frog", "Funk",
        "Hero", "Morse", "Sosumi", "Submarine",
    ]

    @State private var stopEnabled = false
    @State private var stopMessage = "completed"
    @State private var stopSound = "Glass"

    @State private var notificationEnabled = false
    @State private var notificationMessage = "needs your attention"
    @State private var notificationSound = "Glass"

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 4) {
                Text(l10n.notifications)
                    .font(.title2)
                    .fontWeight(.bold)

                Text(l10n.configuresClaudeCodeHooks)
                    .font(.caption)
                    .foregroundStyle(Color.appSecondary)
            }

            // Stop (task completion)
            SettingsGroup(l10n.taskCompletion) {
                VStack(alignment: .leading, spacing: 10) {
                    SettingsRow(l10n.enabled) {
                        Toggle("", isOn: $stopEnabled)
                            .labelsHidden()
                            .onChange(of: stopEnabled) {
                                saveHook(event: "Stop", enabled: stopEnabled, message: stopMessage, sound: stopSound)
                            }
                    }

                    if stopEnabled {
                        SettingsRow(l10n.message) {
                            TextField(l10n.notificationMessage, text: $stopMessage)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 200)
                                .onSubmit {
                                    saveHook(event: "Stop", enabled: stopEnabled, message: stopMessage, sound: stopSound)
                                }
                        }

                        SettingsRow(l10n.sound) {
                            soundPicker(selection: $stopSound) {
                                saveHook(event: "Stop", enabled: stopEnabled, message: stopMessage, sound: stopSound)
                            }
                        }
                    }
                }

                Text(l10n.notifyWhenFinished)
                    .font(.caption)
                    .foregroundStyle(Color.appSecondary)
                    .padding(.leading, SettingsLayout.helpTextLeading)
            }

            // Notification (waiting for input / permission)
            SettingsGroup(l10n.attentionRequired) {
                VStack(alignment: .leading, spacing: 10) {
                    SettingsRow(l10n.enabled) {
                        Toggle("", isOn: $notificationEnabled)
                            .labelsHidden()
                            .onChange(of: notificationEnabled) {
                                saveHook(event: "Notification", enabled: notificationEnabled, message: notificationMessage, sound: notificationSound)
                            }
                    }

                    if notificationEnabled {
                        SettingsRow(l10n.message) {
                            TextField(l10n.notificationMessage, text: $notificationMessage)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 200)
                                .onSubmit {
                                    saveHook(event: "Notification", enabled: notificationEnabled, message: notificationMessage, sound: notificationSound)
                                }
                        }

                        SettingsRow(l10n.sound) {
                            soundPicker(selection: $notificationSound) {
                                saveHook(event: "Notification", enabled: notificationEnabled, message: notificationMessage, sound: notificationSound)
                            }
                        }
                    }
                }

                Text(l10n.notifyWhenAttention)
                    .font(.caption)
                    .foregroundStyle(Color.appSecondary)
                    .padding(.leading, SettingsLayout.helpTextLeading)
            }

            // Test button
            Button {
                playTestNotification()
            } label: {
                Label(l10n.sendTestNotification, systemImage: "bell.badge")
            }
            .pointingHandCursor()
            .padding(.leading, SettingsLayout.helpTextLeading)
        }
        .onAppear { loadFromSettings() }
    }

    private func soundPicker(selection: Binding<String>, onChange: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Picker("", selection: selection) {
                Text(l10n.none).tag("")
                ForEach(Self.macSounds, id: \.self) { sound in
                    Text(sound).tag(sound)
                }
            }
            .frame(width: 140)
            .labelsHidden()
            .onChange(of: selection.wrappedValue) { onChange() }

            Button {
                let soundName = selection.wrappedValue
                if !soundName.isEmpty {
                    NSSound(named: NSSound.Name(soundName))?.play()
                }
            } label: {
                Image(systemName: "speaker.wave.2")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .help(l10n.previewSound)
            .pointingHandCursor()
        }
    }

    private func loadFromSettings() {
        stopEnabled = service.hasNotificationHook(event: "Stop")
        stopMessage = service.getNotificationMessage(event: "Stop") ?? l10n.completed
        stopSound = service.getNotificationSound(event: "Stop") ?? "Glass"

        notificationEnabled = service.hasNotificationHook(event: "Notification")
        notificationMessage = service.getNotificationMessage(event: "Notification") ?? l10n.needsYourAttention
        notificationSound = service.getNotificationSound(event: "Notification") ?? "Glass"
    }

    private func saveHook(event: String, enabled: Bool, message: String, sound: String) {
        service.setNotificationHook(
            event: event,
            enabled: enabled,
            message: message,
            sound: sound.isEmpty ? nil : sound
        )
    }

    private func playTestNotification() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "display notification \"\(l10n.testNotification)\" with title \"Claude Code\" sound name \"Glass\""]
        try? process.run()
    }
}

// MARK: - Layout Constants

private enum SettingsLayout {
    static let labelWidth: CGFloat = 110
    static let helpTextLeading: CGFloat = labelWidth + 8
}

// MARK: - Reusable Components

private struct SettingsGroup<Content: View>: View {
    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundStyle(Color.appSecondary)
                .textCase(.uppercase)
                .tracking(0.5)

            VStack(alignment: .leading, spacing: 10) {
                content
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background, in: RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.appBorder.opacity(0.5), lineWidth: 0.5)
            )
        }
    }
}

private struct SettingsRow<Content: View>: View {
    let label: String
    let content: Content

    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Text(label)
                .font(.system(size: 13))
                .lineLimit(1)
                .frame(width: SettingsLayout.labelWidth, alignment: .trailing)
                .foregroundStyle(Color.appSecondary)

            content
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}
