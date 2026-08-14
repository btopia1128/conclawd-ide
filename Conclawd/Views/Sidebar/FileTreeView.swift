import SwiftUI
import UniformTypeIdentifiers

/// A flattened representation of a file node with its depth for rendering.
private struct FlatFileNode: Identifiable {
    var id: UUID { node.id }
    let node: FileNode
    let depth: Int
}

/// Displays a directory tree in the sidebar for the selected project.
struct FileTreeView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.l10n) private var l10n
    @State private var isDropTargeted: Bool = false

    /// Flatten the tree so that LazyVStack can lazily render ALL nodes.
    private var flattenedNodes: [FlatFileNode] {
        var result: [FlatFileNode] = []
        var stack: [(FileNode, Int)] = appState.fileTreeRoots.reversed().map { ($0, 0) }
        while let (node, depth) = stack.popLast() {
            result.append(FlatFileNode(node: node, depth: depth))
            if node.isDirectory, node.isExpanded, let children = node.children {
                stack.append(contentsOf: children.reversed().map { ($0, depth + 1) })
            }
        }
        return result
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(flattenedNodes) { item in
                    FileNodeRow(node: item.node, depth: item.depth)
                }
            }
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .contentShape(Rectangle())
            .onTapGesture {
                FileTreeFocus.take()
                appState.clearTreeSelection()
            }
        }
        .background(isDropTargeted ? Color.accentColor.opacity(0.08) : Color.clear)
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(Color.accentColor, lineWidth: isDropTargeted ? 1.5 : 0)
                .padding(2)
        )
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            FileDropHelper.handle(providers: providers, into: nil, appState: appState)
        }
        .background(
            FileTreeCommandView(
                onF2: { appState.beginRenameSelectedTreeNode() },
                canCopy: { appState.canCopyFileTreeSelection },
                canPaste: { appState.canPasteIntoFileTree },
                onCopy: { appState.copyFileNodes(appState.selectedTreeNodes) },
                onCut: { appState.cutFileNodes(appState.selectedTreeNodes) },
                onPaste: { appState.pasteFileNodes() }
            )
        )
        .contextMenu {
            Button {
                appState.promptCreateFile()
            } label: {
                Label(l10n.newFile, systemImage: "doc.badge.plus")
            }
            Button {
                appState.promptCreateDirectory()
            } label: {
                Label(l10n.newFolder, systemImage: "folder.badge.plus")
            }

            Divider()

            Button {
                appState.pasteFileNodes(intoDirectoryURL: appState.fileTreeRootURL)
            } label: {
                Label(l10n.pasteFile, systemImage: "doc.on.clipboard")
            }
            .disabled(!appState.canPasteIntoFileTree)
        }
    }
}

/// Tracks the file tree drag currently in flight.
///
/// SwiftUI's `.onDrag` hands AppKit an `NSItemProvider` whose data is *promised*:
/// the drag pasteboard advertises the type but only produces bytes asynchronously.
/// AppKit drop targets (`performDragOperation`) have to resolve the payload
/// synchronously, so `readObjects(forClasses:)` comes back empty for drags that
/// started inside the app. Since those drags never leave the process, the source
/// records the URLs here and drop targets read them directly.
@MainActor
enum FileDragSession {
    /// URLs of the nodes being dragged out of the file tree, empty when the
    /// in-flight drag didn't come from the tree.
    private(set) static var draggedURLs: [URL] = []
    private static var clearMonitor: Any?

    /// Whether a file tree drag is currently in flight.
    static var isActive: Bool { !draggedURLs.isEmpty }

    static func begin(urls: [URL]) {
        draggedURLs = urls
        installClearMonitor()
    }

    /// Read and clear the dragged URLs. Called by whichever drop target
    /// receives the drag, since that ends the session.
    @discardableResult
    static func consume() -> [URL] {
        defer { end() }
        return draggedURLs
    }

    /// A drag that ends outside the app (Finder, another editor) never reaches
    /// one of our drop targets, so the recorded URLs are also discarded on the
    /// user's next click — before any subsequent drag can start.
    private static func installClearMonitor() {
        guard clearMonitor == nil else { return }
        clearMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { event in
            MainActor.assumeIsolated { end() }
            return event
        }
    }

    private static func end() {
        draggedURLs = []
        if let monitor = clearMonitor {
            NSEvent.removeMonitor(monitor)
        }
        clearMonitor = nil
    }
}

/// Resolves file URLs from drag providers and forwards them to AppState.
/// Items dragged from within the file tree are *moved*; items coming from
/// outside the app (Finder, other apps) are *copied*.
/// Returns true if any provider supplied a file URL.
enum FileDropHelper {
    @MainActor
    static func handle(providers: [NSItemProvider], into destination: FileNode?, appState: AppState) -> Bool {
        let fileProviders = providers.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }
        guard !fileProviders.isEmpty else { return false }
        let destinationDirectoryURL = resolvedDestinationDirectoryURL(for: destination)

        // Nodes registered when the drag started inside the tree. The drag
        // ends here, so consume them regardless of the outcome.
        let internalURLs = FileDragSession.consume()

        // Dragging within the tree is a move; the promised pasteboard data
        // may never resolve, so act on the recorded nodes directly.
        if !internalURLs.isEmpty {
            appState.moveFileNodes(internalURLs, toDirectoryURL: destinationDirectoryURL)
            return true
        }

        let group = DispatchGroup()
        let accumulator = URLAccumulator()

        for provider in fileProviders {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url {
                    accumulator.append(url)
                }
                group.leave()
            }
        }

        group.notify(queue: .main) {
            let urls = accumulator.snapshot()
            guard !urls.isEmpty else { return }
            Task { @MainActor in
                appState.importDroppedFiles(urls, toDirectoryURL: destinationDirectoryURL)
            }
        }
        return true
    }

    private static func resolvedDestinationDirectoryURL(for destination: FileNode?) -> URL? {
        if let destination, destination.isDirectory {
            return destination.url
        }
        if let destination {
            return destination.url.deletingLastPathComponent()
        }
        return nil
    }

    private final class URLAccumulator: @unchecked Sendable {
        private let lock = NSLock()
        private var urls: [URL] = []

        func append(_ url: URL) {
            lock.lock()
            urls.append(url)
            lock.unlock()
        }

        func snapshot() -> [URL] {
            lock.lock()
            defer { lock.unlock() }
            return urls
        }
    }
}

// MARK: - File Tree Commands (F2 / ⌘C / ⌘X / ⌘V)

/// Gives the file tree a place in the responder chain.
///
/// ⌘C / ⌘X / ⌘V are the standard Edit menu items, so they can't be claimed with
/// a global monitor without stealing them from the terminal and the editors.
/// Instead the tree owns them the AppKit way: clicking anywhere in the tree makes
/// the backing view the first responder, and `copy:` / `cut:` / `paste:` arrive
/// through the responder chain only while it holds focus.
@MainActor
enum FileTreeFocus {
    static weak var commandView: FileTreeCommandNSView?

    /// Move focus to the file tree (called when the user clicks inside it).
    static func take() {
        guard let view = commandView, let window = view.window else { return }
        guard window.firstResponder !== view else { return }
        window.makeFirstResponder(view)
    }
}

/// Backing view for the file tree's keyboard commands. Also hosts the F2 rename
/// monitor, which stays a global monitor so renaming keeps working regardless of
/// where focus currently sits.
final class FileTreeCommandNSView: NSView, NSMenuItemValidation {
    var onF2: (() -> Bool)?
    var canCopy: (() -> Bool)?
    var canPaste: (() -> Bool)?
    var onCopy: (() -> Void)?
    var onCut: (() -> Void)?
    var onPaste: (() -> Void)?

    private var f2Monitor: Any?

    override var acceptsFirstResponder: Bool { true }

    @objc func copy(_ sender: Any?) { onCopy?() }
    @objc func cut(_ sender: Any?) { onCut?() }
    @objc func paste(_ sender: Any?) { onPaste?() }

    /// Handles ⌘C / ⌘X / ⌘V directly while the tree holds focus, so the commands
    /// work even if the standard Edit menu items aren't around to route them.
    /// Guarded on first responder: key equivalents are offered to the whole view
    /// hierarchy, not just the focused view.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self,
              event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
              let key = event.charactersIgnoringModifiers else {
            return super.performKeyEquivalent(with: event)
        }

        switch key {
        case "c" where canCopy?() ?? false:
            onCopy?()
            return true
        case "x" where canCopy?() ?? false:
            onCut?()
            return true
        case "v" where canPaste?() ?? false:
            onPaste?()
            return true
        default:
            return super.performKeyEquivalent(with: event)
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(copy(_:)), #selector(cut(_:)):
            return canCopy?() ?? false
        case #selector(paste(_:)):
            return canPaste?() ?? false
        default:
            return true
        }
    }

    func startF2Monitor() {
        guard f2Monitor == nil else { return }
        f2Monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.keyCode == 120 else { return event }
            let handled = MainActor.assumeIsolated { self.onF2?() ?? false }
            return handled ? nil : event
        }
    }

    func stopF2Monitor() {
        if let f2Monitor { NSEvent.removeMonitor(f2Monitor) }
        f2Monitor = nil
    }
}

/// Installs `FileTreeCommandNSView` behind the tree.
private struct FileTreeCommandView: NSViewRepresentable {
    let onF2: () -> Bool
    let canCopy: () -> Bool
    let canPaste: () -> Bool
    let onCopy: () -> Void
    let onCut: () -> Void
    let onPaste: () -> Void

    func makeNSView(context: Context) -> FileTreeCommandNSView {
        let view = FileTreeCommandNSView()
        apply(to: view)
        view.startF2Monitor()
        FileTreeFocus.commandView = view
        return view
    }

    func updateNSView(_ nsView: FileTreeCommandNSView, context: Context) {
        apply(to: nsView)
    }

    static func dismantleNSView(_ nsView: FileTreeCommandNSView, coordinator: ()) {
        nsView.stopF2Monitor()
    }

    private func apply(to view: FileTreeCommandNSView) {
        view.onF2 = onF2
        view.canCopy = canCopy
        view.canPaste = canPaste
        view.onCopy = onCopy
        view.onCut = onCut
        view.onPaste = onPaste
    }
}

// MARK: - File Node Row

private struct FileNodeRow: View {
    @Environment(AppState.self) private var appState
    @Environment(\.l10n) private var l10n
    @Bindable var node: FileNode
    let depth: Int
    @State private var isDropTargeted: Bool = false
    @State private var editingName: String = ""
    @FocusState private var isNameFieldFocused: Bool

    private var isRenaming: Bool { appState.renamingNodeId == node.id }

    /// Marked by ⌘X and waiting to be pasted somewhere.
    private var isCut: Bool { appState.cutFileURLs.contains(node.url.standardizedFileURL) }

    var body: some View {
        HStack(spacing: 4) {
            if node.isDirectory {
                Image(systemName: node.isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Color.appSecondary)
                    .frame(width: 12)
            } else {
                Spacer()
                    .frame(width: 12)
            }

            Image(systemName: iconName(for: node))
                .font(.system(size: 12))
                .foregroundStyle(iconColor(for: node))
                .frame(width: 16)

            if isRenaming {
                TextField("", text: $editingName)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .focused($isNameFieldFocused)
                    .onSubmit { commitRename() }
                    .onExitCommand { appState.cancelRename() }
                    .onAppear {
                        editingName = node.name
                        isNameFieldFocused = true
                    }
                    .onChange(of: isNameFieldFocused) { _, focused in
                        // Commit when focus leaves the field (e.g. clicking elsewhere).
                        if !focused && isRenaming { commitRename() }
                    }
            } else {
                Text(node.name)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .opacity(isCut ? 0.45 : 1)
        .padding(.leading, CGFloat(depth) * 16 + 8)
        .padding(.trailing, 8)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isDropTargeted ? Color.accentColor.opacity(0.2) : fileBackground)
        .contentShape(Rectangle())
        .onDrag {
            appState.beginTreeDrag(from: node)
            return NSItemProvider(object: node.url as NSURL)
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            FileDropHelper.handle(providers: providers, into: node, appState: appState)
        }
        .onTapGesture {
            guard !isRenaming else { return }
            FileTreeFocus.take()
            let flags = NSEvent.modifierFlags
            let shouldActivate = appState.handleTreeSelection(
                for: node,
                extend: flags.contains(.shift),
                toggle: flags.contains(.command)
            )
            guard shouldActivate else { return }
            if node.isDirectory {
                toggleExpand()
            } else {
                appState.openFile(url: node.url)
            }
        }
        .contextMenu {
            let targets = appState.treeActionTargets(for: node)
            if targets.count > 1 {
                multiSelectionMenu(targets)
            } else {
                singleNodeMenu
            }
        }
    }

    // MARK: - Context Menus

    @ViewBuilder
    private var singleNodeMenu: some View {
        Button {
            appState.copyFileNodes([node])
        } label: {
            Label(l10n.copyFile, systemImage: "doc.on.doc")
        }

        Button {
            appState.cutFileNodes([node])
        } label: {
            Label(l10n.cutFile, systemImage: "scissors")
        }

        Button {
            appState.pasteFileNodes(into: node)
        } label: {
            Label(l10n.pasteFile, systemImage: "doc.on.clipboard")
        }
        .disabled(!appState.canPasteIntoFileTree)

        Divider()

        Button {
            copyToPasteboard([node.url.path(percentEncoded: false)])
        } label: {
            Label(l10n.copyPath, systemImage: "doc.on.clipboard")
        }

        if appState.selectedProject != nil {
            Button {
                copyToPasteboard([relativePath(for: node.url)])
            } label: {
                Label(l10n.copyRelativePath, systemImage: "doc.on.clipboard.fill")
            }
        }

        Divider()

        Button {
            NSWorkspace.shared.activateFileViewerSelecting([node.url])
        } label: {
            Label(l10n.revealInFinder, systemImage: "folder")
        }

        if !node.isDirectory {
            Button {
                NSWorkspace.shared.open(node.url)
            } label: {
                Label(l10n.openWithDefaultApp, systemImage: "arrow.up.right.square")
            }
        }

        if node.isDirectory {
            Divider()

            Button {
                appState.promptCreateFile(in: node)
            } label: {
                Label(l10n.newFile, systemImage: "doc.badge.plus")
            }
            Button {
                appState.promptCreateDirectory(in: node)
            } label: {
                Label(l10n.newFolder, systemImage: "folder.badge.plus")
            }
        }

        Divider()

        Button {
            appState.beginRename(node)
        } label: {
            Label(l10n.rename, systemImage: "pencil")
        }

        Button(role: .destructive) {
            confirmAndDelete([node])
        } label: {
            Label(l10n.moveToTrash, systemImage: "trash")
        }
    }

    @ViewBuilder
    private func multiSelectionMenu(_ targets: [FileNode]) -> some View {
        Button {
            appState.copyFileNodes(targets)
        } label: {
            Label(l10n.copyItems(count: targets.count), systemImage: "doc.on.doc")
        }

        Button {
            appState.cutFileNodes(targets)
        } label: {
            Label(l10n.cutItems(count: targets.count), systemImage: "scissors")
        }

        Divider()

        Button {
            copyToPasteboard(targets.map { $0.url.path(percentEncoded: false) })
        } label: {
            Label(l10n.copyPaths(count: targets.count), systemImage: "doc.on.clipboard")
        }

        if appState.selectedProject != nil {
            Button {
                copyToPasteboard(targets.map { relativePath(for: $0.url) })
            } label: {
                Label(l10n.copyRelativePaths(count: targets.count), systemImage: "doc.on.clipboard.fill")
            }
        }

        Divider()

        Button {
            NSWorkspace.shared.activateFileViewerSelecting(targets.map(\.url))
        } label: {
            Label(l10n.revealItemsInFinder(count: targets.count), systemImage: "folder")
        }

        Divider()

        Button(role: .destructive) {
            confirmAndDelete(targets)
        } label: {
            Label(l10n.moveToTrashItems(count: targets.count), systemImage: "trash")
        }
    }

    // MARK: - Actions

    private func copyToPasteboard(_ values: [String]) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(values.joined(separator: "\n"), forType: .string)
    }

    /// Path relative to the selected project root, falling back to the full path.
    private func relativePath(for url: URL) -> String {
        let fullPath = url.path(percentEncoded: false)
        guard let projectDir = appState.selectedProject?.directoryPath else { return fullPath }
        let basePath = projectDir.path(percentEncoded: false)
        return fullPath.hasPrefix(basePath)
            ? String(fullPath.dropFirst(basePath.count + 1))
            : fullPath
    }

    private func commitRename() {
        guard isRenaming else { return }
        appState.renameFileNode(node, to: editingName)
    }

    private func confirmAndDelete(_ targets: [FileNode]) {
        guard !targets.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = l10n.moveToTrashConfirmTitle
        alert.informativeText = targets.count == 1
            ? l10n.moveToTrashConfirmMessage(name: targets[0].name)
            : l10n.moveToTrashConfirmMessage(count: targets.count)
        alert.alertStyle = .warning
        alert.addButton(withTitle: l10n.moveToTrash)
        alert.addButton(withTitle: l10n.cancel)
        if alert.runModal() == .alertFirstButtonReturn {
            appState.deleteFileNodes(targets)
        }
    }

    private var fileBackground: Color {
        if appState.selectedTreeNodeIds.contains(node.id) {
            return Color.accentColor.opacity(0.15)
        }
        if !node.isDirectory,
           let selectedId = appState.selectedFileId,
           appState.openFiles.contains(where: { $0.id == selectedId && $0.url == node.url }) {
            return Color.accentColor.opacity(0.15)
        }
        return .clear
    }

    private func toggleExpand() {
        node.isExpanded.toggle()
        if node.isExpanded && !node.isLoaded {
            appState.fileTreeService.expandNode(node)
        }
    }

    private func iconName(for node: FileNode) -> String {
        if node.isDirectory {
            return node.isExpanded ? "folder.fill" : "folder"
        }
        switch node.url.pathExtension.lowercased() {
        case "swift": return "swift"
        case "js", "mjs", "cjs", "ts", "mts", "tsx", "jsx": return "chevron.left.forwardslash.chevron.right"
        case "json", "yaml", "yml", "toml", "xml", "plist": return "doc.text"
        case "md", "markdown", "txt", "rtf": return "doc.plaintext"
        case "png", "jpg", "jpeg", "gif", "svg", "webp", "ico": return "photo"
        case "py", "rb", "go", "rs", "java", "kt", "c", "cpp", "h", "cs": return "chevron.left.forwardslash.chevron.right"
        case "sh", "bash", "zsh": return "terminal"
        case "css", "scss", "less": return "paintbrush"
        case "html", "htm": return "globe"
        case "sql": return "cylinder"
        default: return "doc"
        }
    }

    private func iconColor(for node: FileNode) -> Color {
        if node.isDirectory {
            return .accentColor
        }
        switch node.url.pathExtension.lowercased() {
        case "swift": return .orange
        case "ts", "tsx", "mts": return .blue
        case "js", "mjs", "cjs", "jsx": return .yellow
        case "py": return .green
        case "md", "markdown": return .cyan
        case "json": return .purple
        case "html", "htm": return .red
        case "css", "scss": return .pink
        default: return .appSecondary
        }
    }
}
