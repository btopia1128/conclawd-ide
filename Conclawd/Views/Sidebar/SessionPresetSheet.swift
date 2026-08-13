import SwiftUI

/// Sheet for creating or editing a session preset (saved standalone Claude configuration).
struct SessionPresetSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.l10n) private var l10n
    @Environment(\.dismiss) private var dismiss

    /// If non-nil, we are editing an existing preset.
    let editing: SessionPreset?
    /// If non-nil, pre-fill from an active standalone session ("Save as Preset").
    let saveFromSession: AgentSession?

    @State private var name: String = ""
    @State private var provider: CLIProviderType = .claude
    @State private var model: AgentModel = .inherit
    @State private var permissionMode: PermissionMode = .default
    @State private var directory: String = ""
    @State private var systemPrompt: String = ""
    @State private var customFlags: String = ""
    @State private var isCommandMode: Bool = false
    @State private var rawCommand: String = ""

    private var isEditing: Bool { editing != nil }

    var body: some View {
        VStack(spacing: 20) {
            HStack {
                Text(isEditing ? l10n.editPreset : l10n.newPreset)
                    .font(.headline)

                Spacer()

                Toggle(l10n.manual, isOn: $isCommandMode)
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }

            Grid(alignment: .leading, verticalSpacing: 12) {
                // Name (always shown)
                GridRow {
                    Text(l10n.name)
                        .frame(width: 100, alignment: .trailing)
                    TextField("", text: $name)
                        .textFieldStyle(.roundedBorder)
                }

                if isCommandMode {
                    // Manual mode: full command input
                    GridRow {
                        Text(l10n.command)
                            .frame(width: 100, alignment: .trailing)
                        VStack(alignment: .leading, spacing: 4) {
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
                    }

                    GridRow {
                        Text(l10n.directory)
                            .frame(width: 100, alignment: .trailing)
                        HStack {
                            TextField("", text: $directory)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 12, design: .monospaced))
                            Button {
                                pickDirectory()
                            } label: {
                                Image(systemName: "folder")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                } else {
                    // Form mode: CLI provider
                    GridRow {
                        Text("CLI")
                            .frame(width: 100, alignment: .trailing)
                        Picker("", selection: $provider) {
                            ForEach(CLIProviderType.allCases, id: \.self) { p in
                                Text(p.displayName).tag(p)
                            }
                        }
                        .labelsHidden()
                        .onChange(of: provider) {
                            let valid = AgentModel.allCases(for: provider)
                            if !valid.contains(model) {
                                model = .inherit
                            }
                        }
                    }

                    GridRow {
                        Text(l10n.directory)
                            .frame(width: 100, alignment: .trailing)
                        HStack {
                            TextField("", text: $directory)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 12, design: .monospaced))
                            Button {
                                pickDirectory()
                            } label: {
                                Image(systemName: "folder")
                            }
                            .buttonStyle(.borderless)
                        }
                    }

                    // GUI mode: individual fields
                    GridRow {
                        Text(l10n.model)
                            .frame(width: 100, alignment: .trailing)
                        Picker("", selection: $model) {
                            ForEach(AgentModel.allCases(for: provider), id: \.rawValue) { m in
                                Text(m == .inherit ? l10n.defaultLabel : m.displayName(for: provider))
                                    .tag(m)
                            }
                        }
                        .labelsHidden()
                    }

                    GridRow {
                        Text(l10n.permissions)
                            .frame(width: 100, alignment: .trailing)
                        Picker("", selection: $permissionMode) {
                            ForEach(PermissionMode.allCases, id: \.self) { mode in
                                Text(mode.displayName).tag(mode)
                            }
                        }
                        .labelsHidden()
                    }

                    GridRow {
                        Text(l10n.customFlags)
                            .frame(width: 100, alignment: .trailing)
                        TextField("", text: $customFlags)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))
                    }

                    GridRow {
                        Text(l10n.systemPrompt)
                            .frame(width: 100, alignment: .trailing)
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

            HStack {
                Button(l10n.cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(isEditing ? l10n.save : l10n.create) {
                    save()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear { prefill() }
    }

    private func prefill() {
        if let preset = editing {
            name = preset.name
            provider = preset.provider
            model = preset.model
            permissionMode = preset.permissionMode
            directory = preset.directory
            systemPrompt = preset.systemPrompt ?? ""
            customFlags = preset.customFlags ?? ""
            if let raw = preset.rawCommand {
                isCommandMode = true
                rawCommand = raw
            }
        } else if let session = saveFromSession {
            name = session.customName ?? session.agentName
            if let dir = session.workingDirectory {
                directory = dir.path(percentEncoded: false)
            }
        }
    }

    private func save() {
        var preset = editing ?? SessionPreset(
            name: name.trimmingCharacters(in: .whitespaces)
        )
        preset.name = name.trimmingCharacters(in: .whitespaces)
        preset.provider = provider
        preset.directory = directory

        if isCommandMode {
            let trimmedRaw = rawCommand.trimmingCharacters(in: .whitespacesAndNewlines)
            preset.rawCommand = trimmedRaw.isEmpty ? nil : trimmedRaw
            // Clear GUI-only fields when in command mode
            preset.model = .inherit
            preset.permissionMode = .default
            preset.systemPrompt = nil
            preset.customFlags = nil
        } else {
            let trimmedPrompt = systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedFlags = customFlags.trimmingCharacters(in: .whitespacesAndNewlines)
            preset.rawCommand = nil
            preset.model = model
            preset.permissionMode = permissionMode
            preset.systemPrompt = trimmedPrompt.isEmpty ? nil : trimmedPrompt
            preset.customFlags = trimmedFlags.isEmpty ? nil : trimmedFlags
        }

        appState.saveSessionPreset(preset)
    }

    private func pickDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if let projectDir = appState.selectedProject?.directoryPath {
            panel.directoryURL = projectDir
        }
        panel.message = l10n.selectWorkingDirectory
        guard panel.runModal() == .OK, let url = panel.url else { return }
        directory = url.path(percentEncoded: false)
    }
}
