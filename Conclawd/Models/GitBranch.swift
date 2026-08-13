import Foundation

/// Represents a single git branch (local or remote).
struct GitBranch: Identifiable, Hashable {
    var id: String { fullRef }
    let fullRef: String        // e.g. refs/heads/main, refs/remotes/origin/main
    let name: String           // e.g. main, feature/chat-ui
    let isRemote: Bool
    let isCurrent: Bool
    let remoteName: String?    // e.g. origin
    let lastCommitDate: Date?
    let lastCommitMessage: String?
}

/// A single file entry from `git status --porcelain`.
struct GitChangedFile: Identifiable, Hashable {
    var id: String { path }
    let statusCode: String   // "M", "A", "D", "R", "??"
    let path: String
}

/// Snapshot of git repository status for the current working directory.
struct GitStatus {
    let currentBranch: String
    let hasUncommittedChanges: Bool
    let ahead: Int
    let behind: Int
    let isDetachedHead: Bool
}
