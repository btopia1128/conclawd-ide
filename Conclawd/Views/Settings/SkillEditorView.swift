import SwiftUI

/// Center pane editor for the selected skill's SKILL.md content,
/// or a read-only viewer for bundled files.
struct SkillEditorView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.l10n) private var l10n

    var body: some View {
        if appState.viewingBundledFileURL != nil {
            bundledFileViewer
        } else if appState.editingSkill != nil {
            VStack(spacing: 0) {
                editor
                bottomBar
            }
            .overlay {
                // Hidden buttons for keyboard shortcuts
                Button("") { appState.saveEditingSkill() }
                    .keyboardShortcut("s", modifiers: .command)
                    .frame(width: 0, height: 0)
                    .opacity(0)
            }
        } else {
            emptyState
        }
    }

    // MARK: - SKILL.md Editor

    private var editor: some View {
        @Bindable var state = appState

        return SyntaxHighlightTextView(
            text: Binding(
                get: { state.editingSkill?.content ?? "" },
                set: { state.editingSkill?.content = $0 }
            ),
            language: "markdown",
            showLineNumbers: state.editorShowLineNumbers,
            wordWrap: state.editorWordWrap,
            highlightSkillVariables: true
        )
        .filePathDrop(text: Binding(
            get: { state.editingSkill?.content ?? "" },
            set: { state.editingSkill?.content = $0 }
        ))
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        HStack(spacing: 12) {
            if let skill = appState.editingSkill {
                Image(systemName: "book.closed.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.purple)

                Text(skill.name)
                    .font(.system(size: 12, weight: .medium))

                if let dir = skill.skillDirectory {
                    Text(dir.path(percentEncoded: false))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Color.appTertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }

            Spacer()

            Button(l10n.revert) {
                appState.revertEditingSkill()
            }
            .controlSize(.small)
            .disabled(!appState.skillHasChanges)
            .pointingHandCursor()

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

    // MARK: - Bundled File Viewer

    private var bundledFileViewer: some View {
        BundledFileContentView(fileURL: appState.viewingBundledFileURL!)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "book.closed")
                .font(.system(size: 48))
                .foregroundStyle(Color.appIconMuted)
            Text(l10n.noSkillSelected)
                .font(.headline)
                .foregroundStyle(Color.appMuted)
            Text(l10n.selectSkillToEdit)
                .font(.subheadline)
                .foregroundStyle(Color.appSubtle)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .themedBackground(Color.appSurface)
    }
}

// MARK: - Bundled File Content View

/// Editor/viewer for a bundled file within a skill directory.
/// Text files are editable; binary files show a placeholder.
private struct BundledFileContentView: View {
    let fileURL: URL
    @Environment(AppState.self) private var appState
    @Environment(\.l10n) private var l10n
    @State private var content: String = ""
    @State private var originalContent: String = ""
    @State private var loadError: Bool = false

    private var hasChanges: Bool {
        content != originalContent
    }

    var body: some View {
        VStack(spacing: 0) {
            if loadError {
                binaryPlaceholder
            } else {
                SyntaxHighlightTextView(
                    text: $content,
                    language: SyntaxHighlightTextView.language(for: fileURL.pathExtension, fileName: fileURL.lastPathComponent),
                    showLineNumbers: appState.editorShowLineNumbers,
                    wordWrap: appState.editorWordWrap
                )
            }

            fileBottomBar
        }
        .overlay {
            if !loadError {
                Button("") { saveFile() }
                    .keyboardShortcut("s", modifiers: .command)
                    .frame(width: 0, height: 0)
                    .opacity(0)
            }
        }
        .onAppear { loadContent() }
        .onChange(of: fileURL) { loadContent() }
    }

    // MARK: - Binary Placeholder

    private var binaryPlaceholder: some View {
        VStack(spacing: 8) {
            Image(systemName: "doc.fill")
                .font(.system(size: 32))
                .foregroundStyle(Color.appSecondary)
            Text(l10n.binaryFile)
                .font(.subheadline)
                .foregroundStyle(Color.appSecondary)
            Text(fileURL.lastPathComponent)
                .font(.caption)
                .foregroundStyle(Color.appTertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .themedBackground(Color.appSurface)
    }

    // MARK: - Bottom Bar

    private var fileBottomBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "doc.text")
                .font(.system(size: 11))
                .foregroundStyle(Color.appSecondary)

            Text(fileURL.lastPathComponent)
                .font(.system(size: 12, weight: .medium))

            Text(fileURL.path(percentEncoded: false))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Color.appTertiary)
                .lineLimit(1)
                .truncationMode(.head)

            Spacer()

            if !loadError {
                Button(l10n.revert) { revertFile() }
                    .controlSize(.small)
                    .disabled(!hasChanges)
                    .pointingHandCursor()

                Button(l10n.save) { saveFile() }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                    .disabled(!hasChanges)
                    .pointingHandCursor()
            }

            // Open in external editor (main button + editor picker menu)
            HStack(spacing: 0) {
                Button {
                    appState.openInExternalEditor(fileURL)
                } label: {
                    Label("Open in \(appState.preferredEditorName)", systemImage: "arrow.up.right.square")
                        .font(.system(size: 11))
                }
                .controlSize(.small)
                .pointingHandCursor()

                Menu {
                    ForEach(appState.availableEditors) { editor in
                        Button {
                            appState.preferredEditorBundleId = editor.id
                        } label: {
                            HStack {
                                Text(editor.name)
                                if appState.preferredEditorBundleId == editor.id {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }

                    Divider()

                    Button(l10n.chooseApplication) {
                        appState.chooseExternalEditor()
                    }

                    if appState.preferredEditorBundleId != nil {
                        Button(l10n.resetToDefault) {
                            appState.preferredEditorBundleId = nil
                        }
                    }
                } label: {
                    EmptyView()
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .themedBackground(Color.appSurface)
    }

    // MARK: - Actions

    private func loadContent() {
        do {
            let text = try String(contentsOf: fileURL, encoding: .utf8)
            content = text
            originalContent = text
            loadError = false
        } catch {
            content = ""
            originalContent = ""
            loadError = true
        }
    }

    private func saveFile() {
        do {
            try content.write(to: fileURL, atomically: true, encoding: .utf8)
            originalContent = content
        } catch {
            appState.errorMessage = "Failed to save file: \(error.localizedDescription)"
        }
    }

    private func revertFile() {
        content = originalContent
    }
}
