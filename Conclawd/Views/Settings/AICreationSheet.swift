import SwiftUI

/// What an AI-assisted creation session should produce.
enum AICreationKind: String, Identifiable {
    case agent
    case skill

    var id: String { rawValue }
}

/// Sheet for starting an AI-assisted agent/skill creation session.
///
/// The CLI × scope combinations used to be spelled out as separate items in the
/// "+" menu, which grew to five entries once Codex was available. The menu now
/// only picks auto (this sheet) vs. manual, and the target is chosen here.
struct AICreationSheet: View {
    let kind: AICreationKind

    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.l10n) private var l10n

    @State private var provider: CLIProviderType = .claude
    @State private var scope: AgentScope = .project
    @State private var projectDirectory: URL?

    /// The resolved project directory: explicit selection or the current selectedProject.
    private var resolvedProjectDirectory: URL? {
        projectDirectory ?? appState.selectedProject?.directoryPath
    }

    private var hasCodexCLI: Bool {
        appState.availableCLIProviders.contains(.codex)
    }

    private var title: String {
        kind == .agent ? l10n.createAgentWithAI : l10n.createSkillWithAI
    }

    /// Directory the session writes into, relative to its scope root.
    private var targetSubpath: String {
        let root = provider == .claude ? ".claude" : ".codex"
        return kind == .agent ? "\(root)/agents" : "\(root)/skills"
    }

    private var saveLocationText: String {
        if scope == .user {
            return "~/\(targetSubpath)/"
        }
        if let dir = resolvedProjectDirectory {
            return "\(dir.lastPathComponent)/\(targetSubpath)/"
        }
        return l10n.notSelected
    }

    private var canCreate: Bool {
        scope == .user || resolvedProjectDirectory != nil
    }

    var body: some View {
        VStack(spacing: 20) {
            Text(title)
                .font(.headline)

            Form {
                Section {
                    if hasCodexCLI {
                        Picker("CLI", selection: $provider) {
                            ForEach(CLIProviderType.allCases, id: \.self) { provider in
                                Text(provider.displayName).tag(provider)
                            }
                        }
                    }

                    Picker(l10n.scope, selection: $scope) {
                        Text(l10n.userGlobal).tag(AgentScope.user)
                        Text(l10n.projectSpecific).tag(AgentScope.project)
                    }
                    .onChange(of: scope) {
                        if scope == .user {
                            projectDirectory = nil
                        }
                    }

                    if scope == .project {
                        LabeledContent(l10n.project) {
                            HStack(spacing: 4) {
                                Text(resolvedProjectDirectory?.path(percentEncoded: false) ?? l10n.notSelected)
                                    .font(.system(size: 11))
                                    .foregroundStyle(resolvedProjectDirectory != nil ? .primary : .secondary)
                                    .lineLimit(1)
                                    .truncationMode(.head)

                                Button(l10n.browseShort) {
                                    pickProjectDirectory()
                                }
                                .controlSize(.small)
                            }
                        }
                    }

                    LabeledContent(l10n.saveTo) {
                        Text(saveLocationText)
                            .font(.system(size: 11))
                            .foregroundStyle(Color.appSecondary)
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Button(l10n.cancel) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button(l10n.create) {
                    startSession()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canCreate)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 440)
        .task {
            // Project scope is the common case, but it needs a project to target.
            if appState.selectedProject == nil {
                scope = .user
            }
        }
    }

    private func startSession() {
        let directory = scope == .project ? resolvedProjectDirectory : nil
        switch (kind, provider) {
        case (.agent, .claude):
            appState.startCreationSession(scope: scope, projectDirectory: directory)
        case (.agent, .codex):
            appState.startCodexCreationSession(scope: scope, projectDirectory: directory)
        case (.skill, .claude):
            appState.startSkillCreationSession(scope: scope, projectDirectory: directory)
        case (.skill, .codex):
            appState.startCodexSkillCreationSession(scope: scope, projectDirectory: directory)
        }
    }

    private func pickProjectDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = l10n.selectProjectDirectory
        if let dir = resolvedProjectDirectory {
            panel.directoryURL = dir
        }

        if panel.runModal() == .OK, let url = panel.url {
            projectDirectory = url
        }
    }
}
