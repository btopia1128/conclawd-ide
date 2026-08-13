import Foundation

/// Manages automatic synchronization of Claude Code skills to Codex CLI.
/// When enabled, creates symlinks from ~/.claude/skills/ to ~/.codex/skills/
/// and installs a Claude Code hook that syncs after each session.
@Observable
@MainActor
final class CodexSyncService {

    private let skillConfigService: SkillConfigService
    private let settingsService = ClaudeSettingsService.shared

    init(skillConfigService: SkillConfigService) {
        self.skillConfigService = skillConfigService
    }

    // MARK: - Paths

    private var appDir: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appending(path: "Conclawd")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private var hookScriptURL: URL {
        let dir = appDir.appending(path: "hooks")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appending(path: "sync-skills-to-codex.sh")
    }

    // MARK: - State

    var isEnabled: Bool {
        settingsService.hasCodexSyncHook()
    }

    // MARK: - Enable / Disable

    /// Enables Codex sync: syncs all existing skills and installs the hook.
    func enable() {
        // Sync all existing skills immediately
        skillConfigService.syncAllSkillsToCodex()

        // Write the sync script
        installSyncScript()

        // Install the hook in settings.json
        settingsService.setCodexSyncHook(
            enabled: true,
            scriptPath: hookScriptURL.path(percentEncoded: false)
        )
    }

    /// Disables Codex sync: removes the hook and cleans up symlinks.
    func disable() {
        settingsService.setCodexSyncHook(enabled: false, scriptPath: "")
        try? FileManager.default.removeItem(at: hookScriptURL)
        skillConfigService.unsyncAllSkillsFromCodex()
    }

    // MARK: - Sync Script

    private func installSyncScript() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false)

        let script = """
        #!/bin/bash
        # Syncs Claude Code skills to Codex CLI via symlinks.
        # Installed by Conclawd. Do not edit manually.

        CLAUDE_SKILLS="\(home).claude/skills"
        CODEX_SKILLS="\(home).codex/skills"

        [ ! -d "$CLAUDE_SKILLS" ] && exit 0
        mkdir -p "$CODEX_SKILLS"

        for skill_dir in "$CLAUDE_SKILLS"/*/; do
            [ ! -d "$skill_dir" ] && continue
            [ ! -f "$skill_dir/SKILL.md" ] && continue
            skill_name="$(basename "$skill_dir")"
            target="$CODEX_SKILLS/$skill_name"
            [ -e "$target" ] && continue
            ln -s "$skill_dir" "$target"
        done
        """

        try? script.write(to: hookScriptURL, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: hookScriptURL.path(percentEncoded: false)
        )
    }
}
