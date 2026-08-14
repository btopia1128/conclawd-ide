import Foundation

/// Installs the `conclawd-session-split` skill into the user's global Claude
/// skills directory (`~/.claude/skills/`) so in-session Claude knows how to
/// ask the app for a session split via the bundled `conclawd` helper CLI.
/// The skill is a no-op outside Conclawd: it guards on `$CONCLAWD_CLI`.
enum SessionSplitSkillInstaller {

    static var skillFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".claude/skills/conclawd-session-split/SKILL.md")
    }

    private static let skillContent = """
    ---
    name: conclawd-session-split
    description: Split a topic from the current conversation into a new session tab in the Conclawd app. Use when the user asks to continue a topic in a separate session, split the conversation, or hand an agenda off to a new tab — e.g. "この件は別セッションで進めて", "セッション分けて", "新しいタブでやって", "split this into a new session". Only works inside Conclawd (requires the CONCLAWD_CLI environment variable).
    ---

    # Conclawd Session Split

    Ask the Conclawd app to open a new session tab pre-loaded with a handoff prompt, so one topic from this conversation continues independently while the current session keeps going.

    ## Precondition

    This only works inside the Conclawd app. If `$CONCLAWD_CLI` is not set, tell the user this feature requires running the session inside Conclawd, and stop.

    ## Steps

    1. Identify which topic to split off. If the user's request leaves it ambiguous, ask before splitting.
    2. Write a handoff prompt to a temporary file (e.g. `FILE=$(mktemp)`). The new session starts with zero context, so never reference "the discussion above" or assume shared knowledge. Write it in the language the user speaks, structured as:
       - **Background** — the context the new session needs, including decisions already made (a few sentences).
       - **Task** — what the new session should do, stated as a direct instruction.
       - **Relevant files** — absolute paths of files/directories related to the topic, if any.
       - **Constraints** — anything agreed in this conversation that the new session must respect.
    3. Run (tab title: a few words, in the user's language):
       ```bash
       "$CONCLAWD_CLI" split --title "<short tab title>" --prompt-file "$FILE" --cwd "<absolute project root for the topic>"
       ```
       `--cwd` defaults to the current directory; pass it explicitly when the topic belongs to a different project.
    4. Relay the command's output to the user. On failure report the error honestly — never claim the split happened if the command failed.
    5. Continue the current conversation with the topics that remain here.
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
            print("[SessionSplitSkillInstaller] installed skill at \(fileURL.path)")
        } catch {
            print("[SessionSplitSkillInstaller] install failed: \(error)")
        }
    }
}
