import Foundation

/// Installs the `conclawd-open-file` skill into the user's global Claude
/// skills directory (`~/.claude/skills/`) so in-session Claude knows how to
/// ask the app to open a file in the editor pane via the bundled `conclawd`
/// helper CLI. The skill is a no-op outside Conclawd: it guards on
/// `$CONCLAWD_CLI`.
enum OpenFileSkillInstaller {

    static var skillFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".claude/skills/conclawd-open-file/SKILL.md")
    }

    private static let skillContent = """
    ---
    name: conclawd-open-file
    description: Open a file in the Conclawd app's editor pane. Use when the user asks to open, show, or display a specific file in the editor — e.g. "このファイルを開いて", "AppState.swiftをエディタで見せて", "open this file in the editor", "show me the file you just edited". Only works inside Conclawd (requires the CONCLAWD_CLI environment variable).
    ---

    # Conclawd Open File

    Ask the Conclawd app to open a file in its editor pane, so the user can view or edit it alongside this session.

    ## Precondition

    This only works inside the Conclawd app. If `$CONCLAWD_CLI` is not set, tell the user this feature requires running the session inside Conclawd, and stop.

    ## Steps

    1. Identify which file to open. If the user says "the file you just edited" or similar, use the file from the recent conversation. If ambiguous, ask.
    2. Run:
       ```bash
       "$CONCLAWD_CLI" open "<path>"
       ```
       Relative paths are resolved against the current directory; prefer absolute paths when the file lives outside it.
    3. Relay the outcome to the user. On failure report the error honestly — never claim the file was opened if the command failed. Text files must be UTF-8; images and videos open as previews.
    """

    /// Writes the skill file if missing or outdated. Safe to call on every launch.
    static func installIfNeeded() {
        let fileURL = skillFileURL
        if let existing = try? String(contentsOf: fileURL, encoding: .utf8),
           existing == skillContent {
            return
        }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try skillContent.write(to: fileURL, atomically: true, encoding: .utf8)
            print("[OpenFileSkillInstaller] installed skill at \(fileURL.path)")
        } catch {
            print("[OpenFileSkillInstaller] install failed: \(error)")
        }
    }
}
