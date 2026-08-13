import SwiftUI

/// Sheet for creating a new agent.
struct NewAgentSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.l10n) private var l10n

    @State private var name = ""
    @State private var description = ""
    @State private var model: AgentModel = .inherit
    @State private var scope: AgentScope = .user
    @State private var projectDirectory: URL?
    @State private var customFlags: String = ""
    @State private var workingDirectory: URL?
    @State private var defaultProvider: CLIProviderType = .claude
    @State private var isManual: Bool = false
    @State private var rawCommand: String = ""

    /// The resolved project directory: explicit selection or the current selectedProject.
    private var resolvedProjectDirectory: URL? {
        projectDirectory ?? appState.selectedProject?.directoryPath
    }

    /// Whether Create button should be enabled.
    private var canCreate: Bool {
        let hasName = !name.trimmingCharacters(in: .whitespaces).isEmpty
        if scope == .user {
            return hasName
        }
        guard let dir = resolvedProjectDirectory else { return false }
        let dirExists = FileManager.default.fileExists(atPath: dir.path(percentEncoded: false))
        return hasName && dirExists
    }

    /// Display text for the save location.
    private var saveLocationText: String {
        if scope == .user {
            return "~/.claude/agents/"
        }
        if let dir = resolvedProjectDirectory {
            return "\(dir.lastPathComponent)/.claude/agents/"
        }
        return l10n.notSelected
    }

    var body: some View {
        VStack(spacing: 20) {
            HStack {
                Text(l10n.newAgent)
                    .font(.headline)

                Spacer()

                Toggle(l10n.manual, isOn: $isManual)
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }

            Form {
                // -- Scope & Location --
                Section {
                    Picker(l10n.scope, selection: $scope) {
                        Text(l10n.userGlobal).tag(AgentScope.user)
                        Text(l10n.projectSpecific).tag(AgentScope.project)
                    }
                    .onChange(of: scope) {
                        if scope == .user {
                            projectDirectory = nil
                            workingDirectory = nil
                        } else {
                            workingDirectory = resolvedProjectDirectory
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

                // -- Agent Settings --
                Section {
                    TextField(l10n.name, text: $name)
                        .textFieldStyle(.roundedBorder)

                    TextField(l10n.description, text: $description)
                        .textFieldStyle(.roundedBorder)
                }

                if isManual {
                    // Manual mode: raw command input
                    Section(l10n.command) {
                        TextEditor(text: $rawCommand)
                            .font(.system(size: 12, design: .monospaced))
                            .frame(minHeight: 80, maxHeight: 160)
                            .scrollContentBackground(.hidden)
                            .padding(4)
                            .background(Color.secondary.opacity(0.08))
                            .cornerRadius(6)
                        Text(l10n.commandPlaceholder)
                            .font(.system(size: 10))
                            .foregroundStyle(Color.appTertiary)
                    }

                    // -- Working Directory --
                    Section {
                        LabeledContent(l10n.workingDirectory) {
                            HStack(spacing: 4) {
                                Text(workingDirectory?.path(percentEncoded: false) ?? l10n.notSelected)
                                    .font(.system(size: 11))
                                    .foregroundStyle(workingDirectory != nil ? .primary : .secondary)
                                    .lineLimit(1)
                                    .truncationMode(.head)

                                Button(l10n.browseShort) {
                                    pickWorkingDirectory()
                                }
                                .controlSize(.small)
                            }
                        }
                    }
                } else {
                    // Form mode: individual fields
                    Section {
                        if appState.availableCLIProviders.count > 1 {
                            Picker("CLI", selection: $defaultProvider) {
                                ForEach(CLIProviderType.allCases, id: \.self) { provider in
                                    Text(provider.displayName).tag(provider)
                                }
                            }
                            .onChange(of: defaultProvider) {
                                let valid = AgentModel.allCases(for: defaultProvider)
                                if !valid.contains(model) {
                                    model = .inherit
                                }
                            }
                        }

                        Picker(l10n.model, selection: $model) {
                            ForEach(AgentModel.allCases(for: defaultProvider), id: \.self) { m in
                                Text(m == .inherit ? l10n.defaultLabel : m.displayName(for: defaultProvider)).tag(m)
                            }
                        }
                    }

                    // -- Working Directory --
                    Section {
                        LabeledContent(l10n.workingDirectory) {
                            HStack(spacing: 4) {
                                Text(workingDirectory?.path(percentEncoded: false) ?? l10n.notSelected)
                                    .font(.system(size: 11))
                                    .foregroundStyle(workingDirectory != nil ? .primary : .secondary)
                                    .lineLimit(1)
                                    .truncationMode(.head)

                                Button(l10n.browseShort) {
                                    pickWorkingDirectory()
                                }
                                .controlSize(.small)
                            }
                        }
                    }

                    // -- Custom CLI Flags --
                    Section(l10n.customFlags) {
                        TextEditor(text: $customFlags)
                            .font(.system(size: 12, design: .monospaced))
                            .frame(minHeight: 40, maxHeight: 80)
                            .scrollContentBackground(.hidden)
                            .padding(4)
                            .background(Color.secondary.opacity(0.08))
                            .cornerRadius(6)
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
                    let sanitizedName = name
                        .lowercased()
                        .replacingOccurrences(of: " ", with: "-")
                        .filter { $0.isLetter || $0.isNumber || $0 == "-" }

                    guard !sanitizedName.isEmpty else { return }
                    let trimmedFlags = customFlags.trimmingCharacters(in: .whitespacesAndNewlines)
                    let trimmedRaw = rawCommand.trimmingCharacters(in: .whitespacesAndNewlines)
                    appState.createAgent(
                        name: sanitizedName,
                        description: description,
                        model: isManual ? .inherit : model,
                        scope: scope,
                        projectDirectory: resolvedProjectDirectory,
                        localDirectory: workingDirectory,
                        customFlags: isManual ? nil : (trimmedFlags.isEmpty ? nil : trimmedFlags),
                        defaultProvider: defaultProvider,
                        rawCommand: isManual ? (trimmedRaw.isEmpty ? nil : trimmedRaw) : nil
                    )
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
            if scope == .project {
                workingDirectory = resolvedProjectDirectory
            }
        }
    }

    private func pickProjectDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = l10n.selectProjectDirectory

        if panel.runModal() == .OK, let url = panel.url {
            projectDirectory = url
            workingDirectory = url
        }
    }

    private func pickWorkingDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = l10n.selectWorkingDirectory
        if let dir = workingDirectory {
            panel.directoryURL = dir
        }

        if panel.runModal() == .OK, let url = panel.url {
            workingDirectory = url
        }
    }
}
