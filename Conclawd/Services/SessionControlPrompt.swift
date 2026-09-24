import Foundation

/// System-prompt fragment that teaches in-session Claude how to drive the app
/// through the bundled `conclawd` helper CLI (open a file in the editor pane,
/// split a topic into a new session tab). It is appended to every Claude
/// session the app launches via `--append-system-prompt`, so nothing has to be
/// written into the user's `~/.claude` directory.
enum SessionControlPrompt {

    static let text = """
    # Conclawd app integration

    This session runs inside the Conclawd macOS app. The app bundles a helper CLI whose path is in `$CONCLAWD_CLI`. Use it for the two requests below; report the command's outcome honestly and never claim success if it failed.

    ## Open a file in the editor pane

    When the user asks to open, show, or display a specific file in the editor (e.g. "このファイルを開いて", "open this file in the editor", "show me the file you just edited"), run:

    ```bash
    "$CONCLAWD_CLI" open "<path>"
    ```

    Relative paths resolve against the current directory; prefer absolute paths. If it is ambiguous which file is meant, ask. Text files must be UTF-8; images and videos open as previews.

    ## Split a topic into a new session tab

    When the user asks to continue a topic in a separate session or split the conversation (e.g. "この件は別セッションで進めて", "セッション分けて", "split this into a new session"):

    1. Identify the topic; ask if ambiguous.
    2. Write a handoff prompt to a temporary file (`FILE=$(mktemp)`), in the user's language. The new session starts with zero context, so never reference "the discussion above". Structure it as Background (decisions already made), Task (a direct instruction), Relevant files (absolute paths), and Constraints.
    3. Run:
       ```bash
       "$CONCLAWD_CLI" split --title "<short tab title>" --prompt-file "$FILE" --cwd "<absolute project root>"
       ```
       `--cwd` defaults to the current directory; pass it when the topic belongs to another project.
    4. Relay the output, then continue the current conversation with the remaining topics.
    """

    /// Combines this fragment with an optional memory context into one
    /// `--append-system-prompt` payload. Returns nil when there is nothing
    /// to append (no helper CLI in the bundle and no memory context).
    static func combined(with memoryContext: String?, cliAvailable: Bool) -> String? {
        var parts: [String] = []
        if cliAvailable { parts.append(text) }
        if let memoryContext, !memoryContext.isEmpty { parts.append(memoryContext) }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n---\n\n")
    }

    /// Renders a string as a TOML basic string literal (double-quoted, with
    /// escapes) so it can be passed to Codex via `-c developer_instructions=...`
    /// without touching any file on disk.
    static func tomlBasicString(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 || scalar.value == 0x7F {
                    out += String(format: "\\u%04X", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }

    // MARK: - Legacy skill cleanup

    /// Earlier versions wrote `conclawd-open-file` and `conclawd-session-split`
    /// skills into `~/.claude/skills/`. Remove them if they are still the ones
    /// we wrote (frontmatter name matches and the body references the helper
    /// CLI) so the instructions are not duplicated. User-authored skills with
    /// other content are left alone.
    static func removeLegacySkills() {
        let skillsDir = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".claude/skills")
        for name in ["conclawd-open-file", "conclawd-session-split"] {
            let dir = skillsDir.appending(path: name)
            let file = dir.appending(path: "SKILL.md")
            guard let contents = try? String(contentsOf: file, encoding: .utf8),
                  contents.hasPrefix("---\nname: \(name)\n"),
                  contents.contains("$CONCLAWD_CLI") else { continue }
            do {
                try FileManager.default.removeItem(at: file)
                if let remaining = try? FileManager.default.contentsOfDirectory(atPath: dir.path),
                   remaining.isEmpty {
                    try? FileManager.default.removeItem(at: dir)
                }
                print("[SessionControlPrompt] removed legacy skill at \(file.path)")
            } catch {
                print("[SessionControlPrompt] failed to remove legacy skill \(file.path): \(error)")
            }
        }
    }
}
