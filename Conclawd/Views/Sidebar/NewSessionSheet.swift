import SwiftUI

/// Sheet for configuring and launching a standalone Claude session.
struct NewSessionSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.l10n) private var l10n
    @Environment(\.dismiss) private var dismiss

    @State private var sessionName: String = "Terminal"
    @State private var selectedModel: AgentModel = .inherit
    @State private var permissionMode: PermissionMode = .default
    @State private var selectedProvider: CLIProviderType = .claude
    @State private var systemPrompt: String = ""
    @State private var customFlags: String = ""
    @State private var workingDirectory: URL?
    @State private var isCommandMode: Bool = false
    @State private var rawCommand: String = ""

    var body: some View {
        VStack(spacing: 20) {
            HStack {
                Text(l10n.newSession)
                    .font(.headline)

                Spacer()

                Toggle(l10n.manual, isOn: $isCommandMode)
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }

            Form {
                Section {
                    TextField(l10n.name, text: $sessionName)

                    LabeledContent(l10n.directory) {
                        HStack(spacing: 4) {
                            Text(workingDirectory?.path(percentEncoded: false) ?? l10n.notSelected)
                                .font(.system(size: 11))
                                .foregroundStyle(Color.appSecondary)
                                .lineLimit(1)
                                .truncationMode(.middle)

                            Button(l10n.browse) {
                                let panel = NSOpenPanel()
                                panel.canChooseDirectories = true
                                panel.canChooseFiles = false
                                panel.allowsMultipleSelection = false
                                if let dir = workingDirectory {
                                    panel.directoryURL = dir
                                }
                                if panel.runModal() == .OK {
                                    workingDirectory = panel.url
                                }
                            }
                            .controlSize(.small)
                        }
                    }
                }

                if isCommandMode {
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
                } else {
                    Section {
                        if appState.availableCLIProviders.count > 1 {
                            Picker("CLI", selection: $selectedProvider) {
                                ForEach(CLIProviderType.allCases, id: \.self) { provider in
                                    Text(provider.displayName).tag(provider)
                                }
                            }
                            .onChange(of: selectedProvider) {
                                let valid = AgentModel.allCases(for: selectedProvider)
                                if !valid.contains(selectedModel) {
                                    selectedModel = .inherit
                                }
                            }
                        }

                        Picker(l10n.model, selection: $selectedModel) {
                            ForEach(AgentModel.allCases(for: selectedProvider), id: \.rawValue) { model in
                                Text(model == .inherit ? l10n.defaultLabel : model.displayName(for: selectedProvider))
                                    .tag(model)
                            }
                        }

                        Picker(l10n.permissions, selection: $permissionMode) {
                            ForEach(PermissionMode.allCases, id: \.self) { mode in
                                Text(mode.displayName).tag(mode)
                            }
                        }
                    }

                    Section(l10n.customFlags) {
                        TextEditor(text: $customFlags)
                            .font(.system(size: 12, design: .monospaced))
                            .frame(minHeight: 40, maxHeight: 80)
                            .scrollContentBackground(.hidden)
                            .padding(4)
                            .background(Color.secondary.opacity(0.08))
                            .cornerRadius(6)
                    }

                    Section(l10n.systemPrompt) {
                        TextEditor(text: $systemPrompt)
                            .font(.system(size: 12, design: .monospaced))
                            .frame(minHeight: 60, maxHeight: 120)
                            .scrollContentBackground(.hidden)
                            .padding(4)
                            .background(Color.secondary.opacity(0.08))
                            .cornerRadius(6)
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Button(l10n.cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)

                Spacer()

                Button(l10n.start) {
                    let name = sessionName.trimmingCharacters(in: .whitespaces)
                    if isCommandMode {
                        let trimmedRaw = rawCommand.trimmingCharacters(in: .whitespacesAndNewlines)
                        appState.startManualSession(
                            name: name.isEmpty ? "Terminal" : name,
                            rawCommand: trimmedRaw,
                            workingDirectory: workingDirectory
                        )
                    } else {
                        let trimmedFlags = customFlags.trimmingCharacters(in: .whitespacesAndNewlines)
                        appState.startStandaloneSession(
                            name: name.isEmpty ? "Terminal" : name,
                            model: selectedModel,
                            permissionMode: permissionMode,
                            workingDirectory: workingDirectory,
                            systemPrompt: systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                ? nil : systemPrompt,
                            customFlags: trimmedFlags.isEmpty ? nil : trimmedFlags,
                            provider: selectedProvider
                        )
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420, height: 580)
        .task {
            workingDirectory = appState.selectedProject?.directoryPath
        }
    }
}
