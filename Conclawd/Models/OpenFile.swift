import Foundation
import UniformTypeIdentifiers

/// The kind of file content for display purposes.
enum FileKind: Equatable {
    case text
    case image
    case video

    /// Extensions that UTType misidentifies as media (e.g. `.ts` → MPEG-2 Transport Stream).
    private static let codeExtensions: Set<String> = [
        "ts", "tsx", "mts", "cts",  // TypeScript
        "m", "mm",                   // Objective-C (UTType may match other types)
    ]

    /// Determine the file kind from a file extension.
    static func from(extension ext: String) -> FileKind {
        let lower = ext.lowercased()
        // Guard: known code extensions that UTType misidentifies as media
        if codeExtensions.contains(lower) {
            return .text
        }
        if let utType = UTType(filenameExtension: lower) {
            if utType.conforms(to: .image) || utType.conforms(to: .svg) {
                return .image
            }
            if utType.conforms(to: .movie) || utType.conforms(to: .video) {
                return .video
            }
        }
        // Fallback for common extensions UTType may not cover
        switch lower {
        case "png", "jpg", "jpeg", "gif", "webp", "bmp", "tiff", "tif", "ico", "svg", "heic", "heif":
            return .image
        case "mp4", "mov", "m4v", "webm", "avi", "mkv":
            return .video
        default:
            return .text
        }
    }
}

/// Editor display mode for text files. Only meaningful for renderable formats (currently Markdown).
enum FileViewMode: Equatable {
    case source
    case preview
}

/// Represents a file opened in the center pane editor.
struct OpenFile: Identifiable, Equatable {
    let id: UUID = UUID()
    let url: URL
    let kind: FileKind
    var content: String
    var hasChanges: Bool = false
    /// Which main pane currently owns this open file tab.
    var paneId: PaneID = .primary
    /// Source vs rendered preview. Currently only applies to Markdown files.
    var viewMode: FileViewMode = .source

    var fileName: String { url.lastPathComponent }

    var fileExtension: String { url.pathExtension }

    /// Whether this file can be rendered as a preview (i.e. is Markdown).
    var isMarkdown: Bool {
        switch fileExtension.lowercased() {
        case "md", "markdown": return true
        default: return false
        }
    }

    /// Relative path from the project root (for breadcrumb display).
    func relativePath(from projectRoot: URL) -> String {
        let filePath = url.path(percentEncoded: false)
        let rootPath = projectRoot.path(percentEncoded: false)
        if filePath.hasPrefix(rootPath) {
            return String(filePath.dropFirst(rootPath.count + 1))
        }
        return fileName
    }

    static func == (lhs: OpenFile, rhs: OpenFile) -> Bool {
        lhs.id == rhs.id
    }
}
