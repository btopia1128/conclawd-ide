import SwiftUI

// MARK: - App Delegate (Graceful Shutdown)

final class AppDelegate: NSObject, NSApplicationDelegate {
    var appState: AppState?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let appState else { return .terminateNow }

        let sessionIds = appState.activeSessions.map(\.id)
        guard !sessionIds.isEmpty else { return .terminateNow }

        // Close all active sessions — same flow as right-click → close in the sidebar
        for sessionId in sessionIds {
            appState.closeTab(sessionId: sessionId)
        }

        // Wait briefly for process termination callbacks (resume ID capture, memory extraction)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            NSApplication.shared.reply(toApplicationShouldTerminate: true)
        }

        return .terminateLater
    }
}

// MARK: - App

@main
struct ConclawdApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var appState = AppState()
    @State private var duplicateTarget: DuplicateTarget?
    @AppStorage("appearanceMode") private var appearanceMode: String = AppearanceMode.dark.rawValue
    @AppStorage("terminalColorScheme") private var terminalColorScheme: String = TerminalColorScheme.default.rawValue
    @AppStorage("appLanguage") private var appLanguage: String = AppLanguage.en.rawValue

    private var currentAppearance: AppearanceMode {
        AppearanceMode(rawValue: appearanceMode) ?? .dark
    }

    private var l10n: L10n {
        L10n(raw: appLanguage)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appState)
                .environment(\.l10n, l10n)
                .frame(minWidth: 900, minHeight: 600)
                .preferredColorScheme(currentAppearance.colorScheme)
                .onChange(of: appearanceMode) {
                    appState.processManager.updateTheme()
                }
                .onChange(of: terminalColorScheme) {
                    appState.processManager.updateTheme()
                }
                .onAppear {
                    appDelegate.appState = appState
                }
                .alert("Error", isPresented: .init(
                    get: { appState.errorMessage != nil },
                    set: { if !$0 { appState.errorMessage = nil } }
                )) {
                    Button("OK") { appState.errorMessage = nil }
                } message: {
                    Text(appState.errorMessage ?? "")
                }
                .sheet(item: $duplicateTarget) { target in
                    DuplicateSheet(target: target)
                        .environment(appState)
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1200, height: 800)
        .commands {
            appCommands
        }

        Settings {
            PreferencesView()
        }
    }

    private var closeTabDisabled: Bool {
        switch appState.centerPane {
        case .fileEditor: return appState.selectedFileId == nil
        case .agentEditor: return false
        case .skillEditor: return false
        case .scheduleEditor: return false
        case .terminal, .orgChart, .settings: return appState.selectedSessionId == nil
        }
    }

    @CommandsBuilder
    private var appCommands: some Commands {
        // Save / Revert for inspector
        CommandGroup(replacing: .saveItem) {
            Button("Save") {
                appState.saveFromMenu()
            }
            .keyboardShortcut("s", modifiers: .command)
            .disabled(!appState.canSaveFromMenu)

            Button("Revert") {
                switch appState.inspectorTarget {
                case .agent:
                    appState.revertEditingAgent()
                case .skill:
                    appState.revertEditingSkill()
                case .none:
                    break
                }
                if appState.centerPane == .agentEditor {
                    appState.revertAgentEditor()
                }
            }
            .keyboardShortcut("z", modifiers: [.command, .option])
            .disabled(!appState.agentHasChanges && !appState.skillHasChanges && !appState.agentEditorHasChanges)
        }

        // Never gated on a project selection: the file tree always has a root
        // (the selected project, or the home directory in All Projects / Home
        // mode), and creation follows that same root.
        CommandGroup(replacing: .newItem) {
            Button("New File") {
                appState.promptCreateFile()
            }
            .keyboardShortcut("n", modifiers: .command)

            Button("New Folder") {
                appState.promptCreateDirectory()
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
        }

        CommandGroup(after: .sidebar) {
            Picker("Appearance", selection: $appearanceMode) {
                ForEach(AppearanceMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode.rawValue)
                }
            }
            .pickerStyle(.inline)

            Divider()

            Button(appState.secondaryPane == nil ? "Split Editor" : "Close Split") {
                appState.toggleSplitView()
            }
            .keyboardShortcut("\\", modifiers: .command)
        }

        CommandGroup(after: .toolbar) {
            Button("Duplicate") {
                if let sessionId = appState.selectedSessionId {
                    appState.duplicateSession(sessionId: sessionId)
                } else if let agent = appState.selectedAgent {
                    duplicateTarget = .agent(agent)
                } else if let skill = appState.selectedSkill {
                    duplicateTarget = .skill(skill)
                }
            }
            .keyboardShortcut("d", modifiers: .command)
            .disabled(appState.selectedSessionId == nil && appState.selectedAgent == nil && appState.selectedSkill == nil)

            Button("Start Agent") {
                if let agent = appState.selectedAgent {
                    appState.startAgent(agent)
                }
            }

            Button("Close Tab") {
                switch appState.centerPane {
                case .fileEditor:
                    if let fileId = appState.selectedFileId {
                        appState.closeFileTab(fileId: fileId)
                    }
                case .agentEditor:
                    appState.closeAgentEditor()
                case .skillEditor:
                    appState.closeSkillEditor()
                case .scheduleEditor:
                    appState.closeScheduleEditor()
                case .terminal, .orgChart, .settings:
                    if let sessionId = appState.selectedSessionId {
                        appState.closeTab(sessionId: sessionId)
                    }
                }
            }
            .keyboardShortcut("w", modifiers: .command)
            .disabled(closeTabDisabled)

            Divider()

            // Cmd+1-9: Switch terminal tabs
            ForEach(1...9, id: \.self) { index in
                Button("Tab \(index)") {
                    appState.selectSessionByIndex(index - 1)
                }
                .keyboardShortcut(KeyEquivalent(Character("\(index)")), modifiers: .command)
            }
        }
    }
}
