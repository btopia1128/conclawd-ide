# Conclawd IDE

A macOS desktop application for managing and running [Claude Code](https://docs.anthropic.com/en/docs/claude-code) CLI agents.

Manage multiple Claude Code agents in a Slack-like interface with an organizational chart GUI for configuring parent-child (sub-agent) relationships.

## Features

- **Multi-Agent Sessions** -- Run multiple Claude Code agent sessions simultaneously in a tabbed terminal interface
- **Agent Editor** -- Configure agents with YAML frontmatter (model, permissions, tools, memory, system prompts)
- **Skill Editor** -- Create and manage custom Claude Code skills
- **Organization Chart** -- Visual GUI for parent-child agent hierarchies
- **Session Presets** -- Quick-start templates for common agent configurations
- **Session History** -- Browse past sessions with filtering by type, model, and text search
- **Memory Extraction** -- Automatically extract and store learnings from completed agent sessions
- **File Browser & Editor** -- Built-in file tree with syntax highlighting and Markdown preview
- **Memory-RAG** -- On-device semantic search over agent memories using CoreML embeddings
- **Git Integration** -- Branch display and switching from the status bar
- **Schedule Editor** -- Set up recurring agent tasks

## Installation

### Download (Recommended)

**[Download Conclawd.dmg](https://pub-3d16ad835aab4ec7804bf72e28fa2452.r2.dev/Conclawd.dmg)** — signed and notarized by Apple.

Open the DMG and drag Conclawd into your Applications folder.

Requirements:

- macOS 14.0+ (Apple Silicon)
- [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code) installed and configured

## Building from Source

Requirements:

- macOS 14.0+
- Xcode 15+
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)
- [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code) installed and configured

### 1. Clone and generate project

```bash
git clone https://github.com/rinte-ringoteto/conclawd-ide.git
cd conclawd-ide
xcodegen generate
```

### 2. Download ML Models (Optional)

The ML models for Memory-RAG are not included in the repository due to their size. The app works without them, but semantic search over agent memories will be unavailable.

**MultilingualE5Small** (~224MB):

1. Download from [Hugging Face: intfloat/multilingual-e5-small](https://huggingface.co/intfloat/multilingual-e5-small)
2. Convert to CoreML format using [coremltools](https://github.com/apple/coremltools):
   ```python
   # See Apple's coremltools documentation for ONNX-to-CoreML conversion
   ```
3. Place the model files in `Conclawd/Resources/`:
   ```
   Conclawd/Resources/
   ├── MultilingualE5Small.mlpackage/
   ├── MultilingualE5Small.mlmodelc/
   └── e5_tokenizer/
   ```

### 3. Build and Run

```bash
open Conclawd.xcodeproj
```

Build and run with Cmd+R in Xcode.

## Architecture

```
Conclawd/
├── App/          -- App entry point and lifecycle
├── Models/       -- Data models (Agent, Skill, Session, Project, etc.)
├── Views/        -- SwiftUI views
│   ├── Sidebar/      -- Session list, history, presets
│   ├── Terminal/     -- Terminal emulator tabs
│   ├── Settings/     -- Agent/skill editors, preferences
│   └── OrgChart/     -- Agent hierarchy visualization
├── ViewModels/   -- Application state (AppState)
├── Services/     -- Business logic
│   ├── AgentConfigService    -- Agent/skill YAML loading and saving
│   ├── AgentProcessManager   -- Terminal process lifecycle (PTY)
│   ├── MemoryExtractor       -- Post-session memory extraction
│   ├── EmbeddingService      -- CoreML embedding generation
│   └── MemoryDatabaseService -- SQLite + FTS5 memory search
├── Vendor/       -- Vendored dependencies (Tokenizers)
└── Resources/    -- Assets, ML models (not in repo)
```

## App Sandbox

Conclawd runs without the macOS App Sandbox (`ENABLE_APP_SANDBOX: NO`). This is required because the app needs:

- Direct PTY (pseudo-terminal) access to run Claude Code CLI as a subprocess
- Filesystem access to read/write agent configurations and project files
- Process spawning for terminal sessions

## Dependencies

| Package | Purpose | License |
|---------|---------|---------|
| [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) | Terminal emulator | MIT |
| [Yams](https://github.com/jpsim/Yams) | YAML parser | MIT |
| [Highlightr](https://github.com/raspu/Highlightr) | Syntax highlighting | MIT |
| [GRDB](https://github.com/groue/GRDB.swift) | SQLite database | MIT |

Vendored code from [swift-transformers](https://github.com/huggingface/swift-transformers) (Apache 2.0) is used for tokenization. See [THIRD_PARTY_LICENSES](THIRD_PARTY_LICENSES) for details.

## Contributing

- **Issues are welcome.** Bug reports, feature requests, and feedback via [GitHub Issues](https://github.com/rinte-ringoteto/conclawd-ide/issues) are appreciated.
- **Pull requests are not accepted.** PRs will not be reviewed or merged. This project is maintained solo, and the source is published for transparency rather than co-development.
- **Want to change something?** Fork the repository. The MIT license lets you modify and redistribute your own version freely.

See [CONTRIBUTING.md](CONTRIBUTING.md) for details.

## License

[MIT](LICENSE)
