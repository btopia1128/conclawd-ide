# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.2.1] - 2026-09-24

### Changed

- In-session Claude and Codex now learn the `conclawd open` / `conclawd split` commands
  from the launch system prompt instead of skill files in `~/.claude/skills`; the
  previously installed `conclawd-open-file` / session-split skills are removed
- The source repository moved to github.com/btopia1128/conclawd-ide

### Fixed

- `conclawd` CLI requests could be dropped before the app read them
- ⌘S sometimes did nothing because an editor hidden behind another tab took the
  shortcut; File > Save now saves whatever is on screen
- A failed file save no longer looks saved — an error is shown and the file stays
  marked unsaved
- A split pane could go blank right after opening or closing the split
- The last line number was missing in empty files and files ending with a newline

## [0.2.0] - 2026-09-10

### Added

- `conclawd open <path>` helper command that opens a file in the editor pane, plus a
  bundled `conclawd-open-file` skill (auto-installed to `~/.claude/skills`) so
  in-session Claude can use it
- Skill usage statistics sheet (per-skill totals and daily activity, 7 days / 30 days /
  all time), reachable from the sidebar
- Inline audio preview (wav, mp3, m4a, aac, flac, ogg, aiff, ...) in the file editor

### Changed

- New File / New Folder are always available; creation follows the file tree root
  (selected project or home directory)
- Clicking inside a terminal or its tab bar now activates that split pane, so
  pane-scoped actions target the pane you clicked

### Fixed

- Opening multi-megabyte files no longer hangs the editor or balloons memory (lazy
  layout, plain text storage for oversized documents, no per-update string comparison)
- Split view panes bled under the right inspector or left a gap when it opened/closed;
  widths are now resolved in the same layout pass
- Skill usage hook never recorded anything because the script path under
  "Application Support" was unquoted; existing installs are repaired automatically

## [0.1.1] - 2026-08-14

### Fixed

- Crash when opening video files (e.g. mp4) in the file preview. The macOS 26 SDK
  no longer autolinks AVKit for SwiftUI `VideoPlayer`, so `AVPlayerView` was missing
  at runtime; AVKit is now linked explicitly.

## [0.1.0] - 2026-04-07

### Added

- Initial open-source release
- Multi-agent session management with Slack-like interface
- Agent configuration editor with YAML frontmatter support
- Skill editor for Claude Code custom skills
- Session presets for quick-start configurations
- Terminal emulator powered by SwiftTerm
- Organization chart GUI for parent-child agent relationships
- Session history with filtering (type, model, text search)
- Memory extraction from completed agent sessions
- File tree browser and editor with syntax highlighting
- Memory-RAG with on-device ML embeddings (MultilingualE5Small)
- Git branch display and switching
- Markdown preview in file editor
- Schedule editor for recurring agent tasks
