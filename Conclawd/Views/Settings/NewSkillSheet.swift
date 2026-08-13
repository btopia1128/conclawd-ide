import SwiftUI

/// Sheet for creating a new skill.
struct NewSkillSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.l10n) private var l10n

    @State private var name = ""
    @State private var description = ""
    @State private var scope: AgentScope = .user
    @State private var projectDirectory: URL?

    private var canCreate: Bool {
        let hasName = !name.trimmingCharacters(in: .whitespaces).isEmpty
        let hasProjectDir = scope == .user || projectDirectory != nil
        return hasName && hasProjectDir
    }

    private var saveLocationText: String {
        if scope == .user {
            return "~/.claude/skills/ (+ ~/.agents/skills/ symlink)"
        }
        if let dir = projectDirectory {
            return "\(dir.lastPathComponent)/.claude/skills/ (+ .agents/skills/ symlink)"
        }
        return l10n.notSelected
    }

    var body: some View {
        VStack(spacing: 20) {
            Text(l10n.newSkill)
                .font(.headline)

            Form {
                Section {
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
                                Text(projectDirectory?.path(percentEncoded: false) ?? l10n.notSelected)
                                    .font(.system(size: 11))
                                    .foregroundStyle(projectDirectory != nil ? .primary : .secondary)
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

                Section {
                    TextField(l10n.name, text: $name)
                        .textFieldStyle(.roundedBorder)

                    TextField(l10n.description, text: $description)
                        .textFieldStyle(.roundedBorder)
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
                    appState.createSkill(
                        name: sanitizedName,
                        description: description,
                        scope: scope,
                        projectDirectory: projectDirectory
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
    }

    private func pickProjectDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = l10n.selectProjectDirectory

        if panel.runModal() == .OK, let url = panel.url {
            projectDirectory = url
        }
    }
}
