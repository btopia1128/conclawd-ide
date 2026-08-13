import Foundation

/// Loads directory trees from the file system with exclusion patterns.
struct FileTreeService {

    /// Directories and files excluded from the tree by default.
    /// Only exclude OS metadata files that are never useful to see.
    private static let excludedNames: Set<String> = [
        ".DS_Store", "Thumbs.db",
    ]

    /// Load the top-level children of a project directory.
    func loadRoots(projectURL: URL) -> [FileNode] {
        loadChildren(at: projectURL)
    }

    /// Load direct children of a directory, creating FileNode instances.
    func loadChildren(at url: URL) -> [FileNode] {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .isHiddenKey],
            options: [.skipsPackageDescendants]
        ) else {
            return []
        }

        var nodes: [FileNode] = []

        for itemURL in contents {
            let name = itemURL.lastPathComponent

            if shouldExclude(name: name) { continue }

            let isDir = (try? itemURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            let node = FileNode(name: name, url: itemURL, isDirectory: isDir)
            nodes.append(node)
        }

        return nodes.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory {
                return lhs.isDirectory
            }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    /// Expand a directory node by loading its children.
    func expandNode(_ node: FileNode) {
        guard node.isDirectory, !node.isLoaded else { return }
        node.children = loadChildren(at: node.url)
    }

    private func shouldExclude(name: String) -> Bool {
        Self.excludedNames.contains(name)
    }
}
