import Foundation

/// A node in the file tree representing a file or directory.
@Observable
final class FileNode: Identifiable {
    let id = UUID()
    let name: String
    let url: URL
    let isDirectory: Bool
    var children: [FileNode]?
    var isExpanded: Bool = false

    init(name: String, url: URL, isDirectory: Bool) {
        self.name = name
        self.url = url
        self.isDirectory = isDirectory
    }

    /// Whether children have been loaded from disk.
    var isLoaded: Bool { children != nil }
}
