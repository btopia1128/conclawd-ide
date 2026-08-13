import SwiftUI

/// Sheet for creating or editing a shell preset.
struct ShellPresetSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.l10n) private var l10n
    @Environment(\.dismiss) private var dismiss

    /// If non-nil, we are editing an existing preset.
    let editing: ShellPreset?
    /// If non-nil, pre-fill from an active shell session ("Save as Preset").
    let saveFromSession: AgentSession?

    @State private var name: String = ""
    @State private var directory: String = ""
    @State private var command: String = ""
    @State private var shell: ShellType = .zsh

    private var isEditing: Bool { editing != nil }

    var body: some View {
        VStack(spacing: 20) {
            Text(isEditing ? l10n.editPreset : l10n.newPreset)
                .font(.headline)

            Grid(alignment: .leading, verticalSpacing: 12) {
                GridRow {
                    Text(l10n.name)
                        .frame(width: 80, alignment: .trailing)
                    TextField("", text: $name)
                        .textFieldStyle(.roundedBorder)
                }

                GridRow {
                    Text("Shell")
                        .frame(width: 80, alignment: .trailing)
                    Picker("", selection: $shell) {
                        ForEach(ShellType.allCases, id: \.self) { type in
                            Text(type.displayName).tag(type)
                        }
                    }
                    .labelsHidden()
                }

                GridRow {
                    Text(l10n.directory)
                        .frame(width: 80, alignment: .trailing)
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

                GridRow {
                    Text(l10n.command)
                        .frame(width: 80, alignment: .trailing)
                    TextField("", text: $command)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
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
        .frame(width: 400)
        .onAppear { prefill() }
    }

    private func prefill() {
        if let preset = editing {
            name = preset.name
            directory = preset.directory
            command = preset.command ?? ""
            shell = preset.shell
        } else if let session = saveFromSession {
            shell = session.shellType ?? .zsh
            if let dir = session.workingDirectory {
                directory = dir.path(percentEncoded: false)
            }
            name = session.customName ?? session.shellType?.displayName ?? ""
        }
    }

    private func save() {
        let trimmedCommand = command.trimmingCharacters(in: .whitespaces)
        var preset = editing ?? ShellPreset(
            name: name.trimmingCharacters(in: .whitespaces),
            directory: directory
        )
        preset.name = name.trimmingCharacters(in: .whitespaces)
        preset.directory = directory
        preset.command = trimmedCommand.isEmpty ? nil : trimmedCommand
        preset.shell = shell
        appState.saveShellPreset(preset)
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
