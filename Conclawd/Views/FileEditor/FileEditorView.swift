import SwiftUI

/// Center pane editor for files opened from the file tree.
struct FileEditorView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.l10n) private var l10n
    @State private var markdownRelativeScrollPositions: [URL: Double] = [:]
    var paneId: PaneID = .primary

    /// The selected file for this pane (not the forwarding accessor).
    private var paneSelectedFile: OpenFile? {
        guard let id = appState.pane(paneId).selectedFileId else { return nil }
        return appState.openFiles.first { $0.id == id }
    }

    var body: some View {
        if let file = paneSelectedFile {
            // No `.id` on the Group: keeping the subtree alive across file
            // switches lets `MarkdownPreviewView` reuse its WKWebView instead
            // of spawning a fresh one every time. Views that DO need fresh
            // per-file state carry their own `.id(file.id)` below.
            Group {
                if file.kind == .text {
                    VStack(spacing: 0) {
                        contentView(for: file)
                        bottomBar(for: file)
                    }
                    // ⌘S is owned by the File > Save menu command (see ConclawdApp):
                    // registering it here as well made the two compete, so the
                    // shortcut either fired against a stale view or just beeped.
                    .overlay {
                        if file.isMarkdown {
                            Button("") { appState.toggleFileViewMode(fileId: file.id) }
                                .keyboardShortcut("v", modifiers: [.command, .option])
                                .frame(width: 0, height: 0)
                                .opacity(0)
                        }
                    }
                } else {
                    MediaPreviewView(file: file)
                        .id(file.id)
                }
            }
        } else {
            emptyState
        }
    }

    @ViewBuilder
    private func contentView(for file: OpenFile) -> some View {
        if file.isMarkdown {
            let showPreview = file.viewMode == .preview
            ZStack {
                // `.id(file.id)` gives each file a fresh editor (scroll /
                // cursor state). `MarkdownPreviewView` deliberately has no
                // `.id` so it persists across file switches and reuses its
                // WKWebView — only its `content` is swapped.
                FileTextEditor(file: file, paneId: paneId)
                    .relativeScrollPosition(relativeScrollPositionBinding(for: file.url))
                    .id(file.id)
                    .opacity(showPreview ? 0 : 1)
                    .allowsHitTesting(!showPreview)
                MarkdownPreviewView(
                    fileURL: file.url,
                    content: file.content,
                    baseURL: file.url.deletingLastPathComponent(),
                    relativeScrollPosition: relativeScrollPositionBinding(for: file.url),
                    isVisible: showPreview
                )
                // Opaque surface behind the WebView: it stays transparent
                // until it finishes painting the new content, so without this
                // the editor underneath would briefly flash through.
                .background(Color.appSurface)
                .opacity(showPreview ? 1 : 0)
                .allowsHitTesting(showPreview)
            }
        } else {
            FileTextEditor(file: file, paneId: paneId)
                .id(file.id)
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

    private func relativeScrollPositionBinding(for fileURL: URL) -> Binding<Double> {
        Binding(
            get: { markdownRelativeScrollPositions[fileURL, default: 0] },
            set: { markdownRelativeScrollPositions[fileURL] = min(max($0, 0), 1) }
        )
    }
}

// MARK: - Text editor subview

private struct FileTextEditor: View {
    let file: OpenFile
    let paneId: PaneID
    private var relativeScrollPosition: Binding<Double>?
    @Environment(AppState.self) private var appState

    init(file: OpenFile, paneId: PaneID, relativeScrollPosition: Binding<Double>? = nil) {
        self.file = file
        self.paneId = paneId
        self.relativeScrollPosition = relativeScrollPosition
    }

    /// Reads through to the live copy in `AppState` instead of the `OpenFile`
    /// snapshot this view was built with. `updateNSView` writes this value back
    /// into the text view whenever it differs, so a stale snapshot here would
    /// silently revert whatever the user typed since the last body evaluation.
    private var contentBinding: Binding<String> {
        let fileId = file.id
        let fallback = file.content
        return Binding(
            get: { appState.openFiles.first { $0.id == fileId }?.content ?? fallback },
            set: { appState.updateFileContent(fileId: fileId, content: $0) }
        )
    }

    var body: some View {
        let language = SyntaxHighlightTextView.language(for: file.fileExtension, fileName: file.fileName)
        SyntaxHighlightTextView(
            text: contentBinding,
            language: language,
            showLineNumbers: appState.editorShowLineNumbers,
            wordWrap: appState.editorWordWrap,
            relativeScrollPosition: relativeScrollPosition?.wrappedValue ?? 0,
            onRelativeScrollPositionChange: { relativeScrollPosition?.wrappedValue = $0 },
            onMouseDown: {
                if appState.activePaneId != paneId {
                    appState.activePaneId = paneId
                }
            }
        )
        .filePathDrop(text: contentBinding)
    }

    func relativeScrollPosition(_ relativeScrollPosition: Binding<Double>) -> FileTextEditor {
        FileTextEditor(file: file, paneId: paneId, relativeScrollPosition: relativeScrollPosition)
    }
}
