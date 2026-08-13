import SwiftUI

/// The target to duplicate — either an agent or a skill.
enum DuplicateTarget: Identifiable {
    case agent(Agent)
    case skill(Skill)

    var id: UUID {
        switch self {
        case .agent(let a): a.id
        case .skill(let s): s.id
        }
    }

    var name: String {
        switch self {
        case .agent(let a): a.name
        case .skill(let s): s.name
        }
    }

    var scope: AgentScope {
        switch self {
        case .agent(let a): a.scope
        case .skill(let s): s.scope
        }
    }

    var label: String {
        switch self {
        case .agent: "Agent"
        case .skill: "Skill"
        }
    }

    var userDirectory: String {
        switch self {
        case .agent: ".claude/agents"
        case .skill: ".claude/skills"
        }
    }
}

/// Sheet for duplicating an agent or skill with scope selection.
struct DuplicateSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.l10n) private var l10n
    @Environment(\.dismiss) private var dismiss

    let target: DuplicateTarget

    @State private var scope: AgentScope = .user
    @State private var projectDirectory: URL?

    private var resolvedProjectDirectory: URL? {
        projectDirectory ?? appState.selectedProject?.directoryPath
    }

    private var canDuplicate: Bool {
        if scope == .user { return true }
        guard let dir = resolvedProjectDirectory else { return false }
        return FileManager.default.fileExists(atPath: dir.path(percentEncoded: false))
    }

    private var saveLocationText: String {
        if scope == .user {
            return "~/\(target.userDirectory)/"
        }
        if let dir = resolvedProjectDirectory {
            return "\(dir.lastPathComponent)/\(target.userDirectory)/"
        }
        return l10n.notSelected
    }

    var body: some View {
        VStack(spacing: 20) {
            Text("\(l10n.duplicateLabel) \(target.label)")
                .font(.headline)

            Form {
                Section {
                    LabeledContent(target.label) {
                        Text(target.name)
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

                Button(l10n.duplicate) {
                    let home = FileManager.default.homeDirectoryForCurrentUser
                    let destination: URL?
                    if scope == .user {
                        destination = home.appending(path: target.userDirectory)
                    } else {
                        destination = resolvedProjectDirectory?.appending(path: target.userDirectory)
                    }

                    switch target {
                    case .agent(let agent):
                        appState.duplicateAgent(agent, to: destination)
                    case .skill(let skill):
                        appState.duplicateSkill(skill, to: destination)
                    }
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canDuplicate)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 400)
        .onAppear {
            scope = target.scope
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
        }
    }
}
