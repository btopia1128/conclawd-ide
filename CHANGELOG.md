# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
