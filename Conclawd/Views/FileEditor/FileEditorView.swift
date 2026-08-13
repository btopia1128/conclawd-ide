import SwiftUI

/// Center pane editor for files opened from the file tree.
struct FileEditorView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.l10n) private var l10n
    var paneId: PaneID = .primary

    /// The selected file for this pane (not the forwarding accessor).
    private var paneSelectedFile: OpenFile? {
        guard let id = appState.pane(paneId).selectedFileId else { return nil }
        return appState.openFiles.first { $0.id == id }
    }

    var body: some View {
        if let file = paneSelectedFile {
            Group {
                if file.kind == .text {
                    VStack(spacing: 0) {
                        contentView(for: file)
                        bottomBar(for: file)
                    }
                    .overlay {
                        Button("") { appState.saveFile(fileId: file.id) }
                            .keyboardShortcut("s", modifiers: .command)
                            .frame(width: 0, height: 0)
                            .opacity(0)
                        if file.isMarkdown {
                            Button("") { appState.toggleFileViewMode(fileId: file.id) }
                                .keyboardShortcut("v", modifiers: [.command, .shift])
                                .frame(width: 0, height: 0)
                                .opacity(0)
                        }
                    }
                } else {
                    MediaPreviewView(file: file)
                }
            }
            .id(file.id)
        } else {
            emptyState
        }
    }

    @ViewBuilder
    private func contentView(for file: OpenFile) -> some View {
        if file.isMarkdown {
            let showPreview = file.viewMode == .preview
            ZStack {
                FileTextEditor(file: file, paneId: paneId)
                    .opacity(showPreview ? 0 : 1)
                    .allowsHitTesting(!showPreview)
                MarkdownPreviewView(
                    content: file.content,
                    baseURL: file.url.deletingLastPathComponent(),
                    isVisible: showPreview
                )
                .opacity(showPreview ? 1 : 0)
                .allowsHitTesting(showPreview)
            }
        } else {
            FileTextEditor(file: file, paneId: paneId)
        }
    }

    // MARK: - Bottom Bar

    private func bottomBar(for file: OpenFile) -> some View {
        HStack(spacing: 12) {
            if let project = appState.selectedProject {
                Text(file.relativePath(from: project.directoryPath))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Color.appTertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
            } else {
                Text(file.fileName)
                    .font(.system(size: 12, weight: .medium))
            }

            Spacer()

            // Markdown preview toggle (only for .md/.markdown files)
            if file.isMarkdown {
                Button {
                    appState.toggleFileViewMode(fileId: file.id)
                } label: {
                    Image(systemName: file.viewMode == .preview ? "pencil" : "eye.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(file.viewMode == .preview ? Color.accentColor : Color.appTertiary)
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
                .help(file.viewMode == .preview ? l10n.showSource : l10n.showPreview)
            }

            // Word wrap / line number toggles — kept in layout (invisible in preview) so the
            // preview toggle button stays in the same horizontal position across modes.
            let isPreview = file.isMarkdown && file.viewMode == .preview
            Button {
                appState.editorWordWrap.toggle()
            } label: {
                Image(systemName: "text.wordwrap")
                    .font(.system(size: 11))
                    .foregroundStyle(appState.editorWordWrap ? Color.accentColor : Color.appTertiary)
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
            .opacity(isPreview ? 0 : 1)
            .allowsHitTesting(!isPreview)

            Button {
                appState.editorShowLineNumbers.toggle()
            } label: {
                Image(systemName: "list.number")
                    .font(.system(size: 11))
                    .foregroundStyle(appState.editorShowLineNumbers ? Color.accentColor : Color.appTertiary)
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
            .opacity(isPreview ? 0 : 1)
            .allowsHitTesting(!isPreview)

            Button(l10n.revert) {
                revertFile(file)
            }
            .controlSize(.small)
            .disabled(!file.hasChanges)
            .pointingHandCursor()

            Button(l10n.save) {
                appState.saveFile(fileId: file.id)
            }
            .controlSize(.small)
            .buttonStyle(.borderedProminent)
            .disabled(!file.hasChanges)
            .pointingHandCursor()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .themedBackground(Color.appSurface)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.text")
                .font(.system(size: 48))
                .foregroundStyle(Color.appIconMuted)
            Text(l10n.selectProjectToViewFiles)
                .font(.headline)
                .foregroundStyle(Color.appMuted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .themedBackground(Color.appSurface)
    }

    // MARK: - Helpers

    private func revertFile(_ file: OpenFile) {
        guard let data = try? Data(contentsOf: file.url),
              let content = String(data: data, encoding: .utf8) else { return }
        appState.updateFileContent(fileId: file.id, content: content)
        // Reset hasChanges after revert
        if let index = appState.openFiles.firstIndex(where: { $0.id == file.id }) {
            appState.openFiles[index].hasChanges = false
        }
    }
}

// MARK: - Text editor subview

private struct FileTextEditor: View {
    let file: OpenFile
    let paneId: PaneID
    @Environment(AppState.self) private var appState

    var body: some View {
        let language = SyntaxHighlightTextView.language(for: file.fileExtension, fileName: file.fileName)
        SyntaxHighlightTextView(
            text: Binding(
                get: { file.content },
                set: { appState.updateFileContent(fileId: file.id, content: $0) }
            ),
            language: language,
            showLineNumbers: appState.editorShowLineNumbers,
            wordWrap: appState.editorWordWrap,
            onMouseDown: {
                if appState.activePaneId != paneId {
                    appState.activePaneId = paneId
                }
            }
        )
        .filePathDrop(text: Binding(
            get: { file.content },
            set: { appState.updateFileContent(fileId: file.id, content: $0) }
        ))
    }
}

