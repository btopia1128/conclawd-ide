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

    /// Flatten the tree so that LazyVStack can lazily render ALL nodes.
    private var flattenedNodes: [FlatFileNode] {
        var result: [FlatFileNode] = []
        func flatten(_ nodes: [FileNode], _ depth: Int) {
            for node in nodes {
                result.append(FlatFileNode(node: node, depth: depth))
                if node.isDirectory && node.isExpanded, let children = node.children {
                    flatten(children, depth + 1)
                }
            }
        }
        flatten(appState.fileTreeRoots, 0)
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
        }
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
        }
    }
}

// MARK: - File Node Row

private struct FileNodeRow: View {
    @Environment(AppState.self) private var appState
    @Environment(\.l10n) private var l10n
    @Bindable var node: FileNode
    let depth: Int

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

            Text(node.name)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.leading, CGFloat(depth) * 16 + 8)
        .padding(.trailing, 8)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(fileBackground)
        .contentShape(Rectangle())
        .onDrag {
            NSItemProvider(object: node.url as NSURL)
        }
        .onTapGesture {
            if node.isDirectory {
                toggleExpand()
            } else {
                appState.openFile(url: node.url)
            }
        }
        .contextMenu {
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(node.url.path(percentEncoded: false), forType: .string)
            } label: {
                Label(l10n.copyPath, systemImage: "doc.on.clipboard")
            }

            if let projectDir = appState.selectedProject?.directoryPath {
                Button {
                    let fullPath = node.url.path(percentEncoded: false)
                    let basePath = projectDir.path(percentEncoded: false)
                    let relative = fullPath.hasPrefix(basePath)
                        ? String(fullPath.dropFirst(basePath.count + 1))
                        : fullPath
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(relative, forType: .string)
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

            Button(role: .destructive) {
                confirmAndDelete()
            } label: {
                Label(l10n.moveToTrash, systemImage: "trash")
            }
        }
    }

    private func confirmAndDelete() {
        let alert = NSAlert()
        alert.messageText = l10n.moveToTrashConfirmTitle
        alert.informativeText = l10n.moveToTrashConfirmMessage(name: node.name)
        alert.alertStyle = .warning
        alert.addButton(withTitle: l10n.moveToTrash)
        alert.addButton(withTitle: l10n.cancel)
        if alert.runModal() == .alertFirstButtonReturn {
            appState.deleteFileNode(node)
        }
    }

    private var fileBackground: Color {
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
