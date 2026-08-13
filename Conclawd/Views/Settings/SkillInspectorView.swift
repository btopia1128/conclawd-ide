import SwiftUI
import UniformTypeIdentifiers

/// Right panel showing the selected skill's metadata and info.
/// The skill content editor is shown in the center pane (SkillEditorView).
struct SkillInspectorView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.l10n) private var l10n
    @Binding var showInspector: Bool
    @State private var showingToolPicker = false
    @State private var newToolName = ""

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

            if appState.editingSkill != nil {
                inspectorContent
            } else {
                emptyState
            }
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "book.closed")
                .font(.system(size: 32))
                .foregroundStyle(Color.appTertiary)
            Text(l10n.selectASkill)
                .font(.subheadline)
                .foregroundStyle(Color.appSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Inspector Content

    private var inspectorContent: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    headerSection
                    usageSection
                    cardSection(l10n.behavior) { behaviorSection }
                    cardSection(l10n.configuration) { configSection }
                    cardSection(l10n.allowedToolsLabel) { allowedToolsSection }
                    cardSection(l10n.bundledFiles) { bundledFilesSection }
                }
                .padding(12)
            }

            actionsSection
        }
        .onAppear {
            appState.skillUsageService.loadUsageCounts()
        }
    }

    // MARK: - Header

    @ViewBuilder
    private var headerSection: some View {
        if let skill = appState.editingSkill {
            HStack(spacing: 10) {
                Image(systemName: "book.closed.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.purple)

                VStack(alignment: .leading, spacing: 2) {
                    Text(skill.name)
                        .font(.system(size: 15, weight: .semibold))
                    if !skill.description.isEmpty {
                        Text(skill.description)
                            .font(.system(size: 11))
                            .foregroundStyle(Color.appSecondary)
                            .lineLimit(2)
                    }
                }

                Spacer()
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Usage

    @ViewBuilder
    private var usageSection: some View {
        if appState.skillUsageService.isHookInstalled, let skill = appState.editingSkill {
            let count = appState.skillUsageService.count(for: skill.name)
            cardSection(l10n.usageCount) {
                HStack(spacing: 4) {
                    Text("\(count)")
                        .font(.system(size: 20, weight: .semibold, design: .rounded))
                    Text(l10n.timesUsed)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.appSecondary)
                }
            }
        }
    }

    // MARK: - Behavior

    @ViewBuilder
    private var behaviorSection: some View {
        @Bindable var state = appState

        VStack(alignment: .leading, spacing: 12) {
            // Manual Only — disable-model-invocation
            Toggle(isOn: Binding(
                get: { state.editingSkill?.disableModelInvocation ?? false },
                set: { state.editingSkill?.disableModelInvocation = $0 }
            )) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(l10n.manualOnly)
                        .font(.system(size: 12))
                    Text(l10n.manualOnlyDescription)
                        .font(.system(size: 10))
                        .foregroundStyle(Color.appTertiary)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)

            // Show in / Menu — user-invocable
            Toggle(isOn: Binding(
                get: { state.editingSkill?.userInvocable ?? true },
                set: { state.editingSkill?.userInvocable = $0 }
            )) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(l10n.showInMenu)
                        .font(.system(size: 12))
                    Text(l10n.showInMenuDescription)
                        .font(.system(size: 10))
                        .foregroundStyle(Color.appTertiary)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)

            // Context
            fieldRow(l10n.skillContext) {
                Picker("", selection: Binding(
                    get: { state.editingSkill?.context ?? .inline },
                    set: { state.editingSkill?.context = $0 }
                )) {
                    ForEach(SkillContext.allCases, id: \.self) { ctx in
                        Text(ctx.displayName).tag(ctx)
                    }
                }
                .labelsHidden()
                .controlSize(.small)
            }

            // Agent Type (only when context=fork)
            if state.editingSkill?.context == .fork {
                fieldRow(l10n.agentType) {
                    TextField("Explore", text: Binding(
                        get: { state.editingSkill?.agentType ?? "" },
                        set: { state.editingSkill?.agentType = $0.isEmpty ? nil : $0 }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                }
            }
        }
    }

    // MARK: - Configuration

    @ViewBuilder
    private var configSection: some View {
        @Bindable var state = appState

        VStack(alignment: .leading, spacing: 12) {
            fieldRow(l10n.name) {
                TextField(l10n.skillName, text: Binding(
                    get: { state.editingSkill?.name ?? "" },
                    set: { state.editingSkill?.name = $0 }
                ))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
            }

            fieldRow(l10n.description) {
                TextEditor(text: Binding(
                    get: { state.editingSkill?.description ?? "" },
                    set: { state.editingSkill?.description = $0 }
                ))
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
                .filePathDrop(text: Binding(
                    get: { state.editingSkill?.description ?? "" },
                    set: { state.editingSkill?.description = $0 }
                ))
            }

            HStack(spacing: 12) {
                // Model Picker
                fieldRow(l10n.model) {
                    let modelBinding = Binding<AgentModel>(
                        get: { state.editingSkill?.model ?? .inherit },
                        set: {
                            state.editingSkill?.model = ($0 == .inherit) ? nil : $0
                        }
                    )
                    Picker("", selection: modelBinding) {
                        ForEach(AgentModel.allCases, id: \.self) { model in
                            Text(model == .inherit ? l10n.defaultLabel : model.displayName).tag(model)
                        }
                    }
                    .labelsHidden()
                    .controlSize(.small)
                }

                // Effort Picker
                fieldRow(l10n.effort) {
                    let effortBinding = Binding<SkillEffort?>(
                        get: { state.editingSkill?.effort },
                        set: { state.editingSkill?.effort = $0 }
                    )
                    Picker("", selection: effortBinding) {
                        Text(l10n.inherit).tag(nil as SkillEffort?)
                        ForEach(SkillEffort.allCases, id: \.self) { e in
                            Text(e.displayName).tag(e as SkillEffort?)
                        }
                    }
                    .labelsHidden()
                    .controlSize(.small)
                }
            }

            // Argument Hint
            fieldRow(l10n.argumentHint) {
                TextField("[arg1] [arg2]", text: Binding(
                    get: { state.editingSkill?.argumentHint ?? "" },
                    set: { state.editingSkill?.argumentHint = $0.isEmpty ? nil : $0 }
                ))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
            }
        }
    }

    // MARK: - Allowed Tools

    @ViewBuilder
    private var allowedToolsSection: some View {
        @Bindable var state = appState

        VStack(alignment: .leading, spacing: 10) {
            if let skill = state.editingSkill {
                if skill.allowedTools.isEmpty {
                    Text(l10n.noToolsConfigured)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.appTertiary)
                } else {
                    TagListView(
                        tags: skill.allowedTools,
                        onRemove: { index in
                            state.editingSkill?.allowedTools.remove(at: index)
                        }
                    )
                }

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
                    VStack(spacing: 8) {
                        TextField(l10n.addTool, text: $newToolName)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12))
                            .frame(width: 200)
                            .onSubmit {
                                addTool()
                            }

                        HStack {
                            Spacer()
                            Button(l10n.add) {
                                addTool()
                            }
                            .controlSize(.small)
                            .buttonStyle(.borderedProminent)
                            .disabled(newToolName.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                    .padding(12)
                }
            }
        }
    }

    private func addTool() {
        let tool = newToolName.trimmingCharacters(in: .whitespaces)
        guard !tool.isEmpty else { return }
        appState.editingSkill?.allowedTools.append(tool)
        newToolName = ""
        showingToolPicker = false
    }

    // MARK: - Bundled Files

    @ViewBuilder
    private var bundledFilesSection: some View {
        if let skill = appState.editingSkill {
            VStack(alignment: .leading, spacing: 8) {
                let files = skill.bundledFiles
                if files.isEmpty {
                    Text(l10n.noBundledFiles)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.appTertiary)
                } else {
                    ForEach(files, id: \.absoluteString) { url in
                        let relativePath = relativePathFromSkillDir(url: url, skill: skill)
                        let isViewing = appState.viewingBundledFileURL == url
                        HStack(spacing: 6) {
                            Image(systemName: iconForExtension(url.pathExtension))
                                .font(.system(size: 10))
                                .foregroundStyle(colorForExtension(url.pathExtension))
                            Text(relativePath)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(isViewing ? Color.accentColor : .primary)
                            Spacer()
                            Button {
                                appState.openInExternalEditor(url)
                            } label: {
                                Image(systemName: "arrow.up.right.square")
                                    .font(.system(size: 10))
                                    .foregroundStyle(Color.appSecondary)
                            }
                            .buttonStyle(.plain)
                            .help("Open in \(appState.preferredEditorName)")
                            .pointingHandCursor()
                        }
                        .padding(.vertical, 2)
                        .padding(.horizontal, 4)
                        .background(isViewing ? Color.accentColor.opacity(0.1) : Color.clear)
                        .cornerRadius(4)
                        .contentShape(Rectangle())
                        .pointingHandCursor()
                        .onTapGesture {
                            appState.openBundledFile(url)
                        }
                    }
                }

                if let skillDir = skill.skillDirectory {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([skillDir])
                    } label: {
                        Label(l10n.revealInFinder, systemImage: "folder")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    .pointingHandCursor()
                }
            }
        }
    }

    private func relativePathFromSkillDir(url: URL, skill: Skill) -> String {
        guard let skillDir = skill.skillDirectory else { return url.lastPathComponent }
        let basePath = skillDir.path(percentEncoded: false)
        let filePath = url.path(percentEncoded: false)
        if filePath.hasPrefix(basePath) {
            let relative = String(filePath.dropFirst(basePath.count))
            return relative.hasPrefix("/") ? String(relative.dropFirst()) : relative
        }
        return url.lastPathComponent
    }

    private func iconForExtension(_ ext: String) -> String {
        switch ext.lowercased() {
        case "py": return "chevron.left.forwardslash.chevron.right"
        case "sh", "bash", "zsh": return "terminal"
        case "js", "ts": return "chevron.left.forwardslash.chevron.right"
        case "md": return "doc.text"
        case "json", "yaml", "yml": return "curlybraces"
        case "html", "css": return "globe"
        default: return "doc"
        }
    }

    private func colorForExtension(_ ext: String) -> Color {
        switch ext.lowercased() {
        case "py": return .blue
        case "sh", "bash", "zsh": return .green
        case "js", "ts": return .statusReady
        case "md": return .appSecondary
        case "json", "yaml", "yml": return .orange
        default: return .appSecondary
        }
    }

    // MARK: - Actions

    private var actionsSection: some View {
        HStack(spacing: 8) {
            Button(l10n.revert) {
                appState.revertEditingSkill()
            }
            .controlSize(.small)
            .disabled(!appState.skillHasChanges)
            .pointingHandCursor()

            Spacer()

            Button(l10n.save) {
                appState.saveEditingSkill()
            }
            .controlSize(.small)
            .buttonStyle(.borderedProminent)
            .disabled(!appState.skillHasChanges)
            .pointingHandCursor()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .themedBackground(Color.appSurface)
    }

    // MARK: - Helpers

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

    private func fieldRow<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(Color.appSecondary)
            content()
        }
    }
}
