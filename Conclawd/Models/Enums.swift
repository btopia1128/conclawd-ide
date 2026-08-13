import AppKit
import Foundation
import SwiftUI

// MARK: - Agent Model

enum AgentModel: Codable, CaseIterable, Hashable {
    case inherit
    case haiku
    case sonnet
    case opus
    case custom(String)

    // ── Model ID constants (update here when models change) ──

    /// The model ID passed to the CLI via --model flag.
    static let haikuModelId = "claude-haiku-4-5-20251001"
    static let sonnetModelId = "claude-sonnet-4-6"
    static let opusModelId = "claude-opus-4-6"

    /// The default model used when no model is explicitly set.
    static let defaultModel: AgentModel = .opus

    // ── Computed properties ──

    static var allCases: [AgentModel] {
        [.inherit, .haiku, .sonnet, .opus]
    }

    /// The CLI model ID string (e.g. "claude-opus-4-6").
    var rawValue: String {
        switch self {
        case .inherit: return "inherit"
        case .haiku: return Self.haikuModelId
        case .sonnet: return Self.sonnetModelId
        case .opus: return Self.opusModelId
        case .custom(let value): return value
        }
    }

    /// Short name used in YAML frontmatter (e.g. "opus").
    var shortName: String {
        switch self {
        case .inherit: return "inherit"
        case .haiku: return "haiku"
        case .sonnet: return "sonnet"
        case .opus: return "opus"
        case .custom(let value): return value
        }
    }

    /// Human-readable display name for UI.
    var displayName: String {
        switch self {
        case .inherit: return Self.defaultModel.displayName
        case .haiku: return "Haiku"
        case .sonnet: return "Sonnet"
        case .opus: return "Opus"
        case .custom(let value): return value
        }
    }

    /// Display name appropriate for the given CLI provider.
    func displayName(for provider: CLIProviderType) -> String {
        switch provider {
        case .claude:
            return displayName
        case .codex:
            switch self {
            case .inherit: return Self.codexDefaultModel.displayName(for: .codex)
            case .haiku: return "GPT-5.4 Mini"
            case .sonnet, .opus: return "GPT-5.4"
            case .custom(let value): return value
            }
        }
    }

    /// The cases shown in pickers for each provider.
    static func allCases(for provider: CLIProviderType) -> [AgentModel] {
        switch provider {
        case .claude:
            return allCases
        case .codex:
            // sonnet and opus both map to gpt-5.4, so show only opus to avoid confusion
            return [.inherit, .haiku, .opus]
        }
    }

    /// The default model for the given CLI provider.
    static var codexDefaultModel: AgentModel { .opus }

    // ── Coding ──

    /// Resolve a string (short name or full model ID) to an AgentModel.
    static func from(_ value: String) -> AgentModel {
        for model in [AgentModel.inherit, .haiku, .sonnet, .opus] {
            if value == model.shortName || value == model.rawValue {
                return model
            }
        }
        return .custom(value)
    }

    // ── Codex model ID mapping ──

    static let codexDefaultModelId = "gpt-5.4"
    static let codexLightModelId = "gpt-5.4-mini"

    /// Returns the model ID appropriate for the given CLI provider.
    func cliModelId(for provider: CLIProviderType) -> String {
        switch provider {
        case .claude:
            return rawValue
        case .codex:
            switch self {
            case .inherit: return "inherit"
            case .haiku: return Self.codexLightModelId
            case .sonnet, .opus: return Self.codexDefaultModelId
            case .custom(let value): return value
            }
        }
    }

    // ── Coding ──

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        self = Self.from(value)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

// MARK: - CLI Provider Type

enum CLIProviderType: String, Codable, CaseIterable, Hashable {
    case claude
    case codex

    var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex CLI"
        }
    }

    var binaryName: String { rawValue }
}

// MARK: - Agent Color

enum AgentColor: String, Codable, CaseIterable, Hashable {
    case red
    case orange
    case yellow
    case green
    case blue
    case purple
    case cyan
    case magenta

    var displayName: String {
        rawValue.capitalized
    }

    var swiftUIColor: SwiftUI.Color {
        switch self {
        case .red: return .red
        case .orange: return .orange
        case .yellow: return .yellow
        case .green: return .green
        case .blue: return .blue
        case .purple: return .purple
        case .cyan: return .cyan
        case .magenta: return .pink
        }
    }
}

// MARK: - Permission Mode

enum PermissionMode: String, Codable, CaseIterable, Hashable {
    case `default` = "default"
    case acceptEdits = "acceptEdits"
    case dontAsk = "dontAsk"
    case bypassPermissions = "bypassPermissions"
    case plan = "plan"

    var displayName: String {
        switch self {
        case .default: return "Default"
        case .acceptEdits: return "Accept Edits"
        case .dontAsk: return "Don't Ask"
        case .bypassPermissions: return "Bypass Permissions"
        case .plan: return "Plan"
        }
    }

    /// Returns the CLI arguments for this permission mode for the given provider.
    func cliArgs(for provider: CLIProviderType) -> [String] {
        switch provider {
        case .claude:
            switch self {
            case .acceptEdits, .dontAsk, .plan:
                return ["--permission-mode", rawValue]
            case .bypassPermissions:
                return ["--dangerously-skip-permissions"]
            case .default:
                return []
            }
        case .codex:
            switch self {
            case .default, .acceptEdits:
                return ["--sandbox", "workspace-write", "-a", "on-request"]
            case .dontAsk:
                return ["--full-auto"]
            case .bypassPermissions:
                return ["--yolo"]
            case .plan:
                return ["--sandbox", "read-only"]
            }
        }
    }
}

// MARK: - App Language

enum AppLanguage: String, CaseIterable, Hashable {
    case ja
    case en

    var displayName: String {
        switch self {
        case .ja: return "日本語"
        case .en: return "English"
        }
    }
}

// MARK: - Appearance Mode

enum AppearanceMode: String, CaseIterable, Hashable {
    case dark
    case light
    case claude
    case system

    var displayName: String {
        switch self {
        case .dark: return "Dark"
        case .light: return "Light"
        case .claude: return "Claude"
        case .system: return "System"
        }
    }

    func displayName(_ l10n: L10n) -> String {
        switch self {
        case .dark: return l10n.dark
        case .light: return l10n.light
        case .claude: return "Claude"
        case .system: return l10n.system
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .dark: return .dark
        case .light: return .light
        case .claude: return .light
        case .system: return nil
        }
    }
}

// MARK: - Agent Scope

enum AgentScope: String, Codable, Hashable {
    case project
    case user
    case cloud
}

// MARK: - Skill Effort

enum SkillEffort: String, CaseIterable, Hashable {
    case low
    case medium
    case high
    case max

    var displayName: String {
        rawValue.capitalized
    }
}

// MARK: - Skill Context

enum SkillContext: String, CaseIterable, Hashable {
    case inline
    case fork

    var displayName: String {
        switch self {
        case .inline: return "Inline"
        case .fork: return "Fork (Subagent)"
        }
    }
}

// MARK: - Memory Storage

/// Where agent memory files are stored.
/// - `shared`: next to the agent .md file (in project repo, shared via Git)
/// - `private`: under ~/.claude/agent-memory/ (local only, not shared)
enum MemoryStorage: String, Codable, CaseIterable, Hashable {
    case shared
    case `private`

    var displayName: String {
        switch self {
        case .shared: return "Shared"
        case .private: return "Private"
        }
    }

    var storageDescription: String {
        switch self {
        case .shared: return "Shared via Git with team"
        case .private: return "Local only, not shared"
        }
    }

    /// Value written to the .md frontmatter.
    var yamlValue: String {
        switch self {
        case .shared: return "shared"
        case .private: return "private"
        }
    }
}

// MARK: - Memory Ownership

/// Who owns the memory.
/// - `agent`: belongs to a specific agent
/// - `global`: shared across all agents
enum MemoryOwnership: String, Codable, CaseIterable, Hashable {
    case agent
    case global

    var displayName: String {
        switch self {
        case .agent: return "Agent"
        case .global: return "Global"
        }
    }

    var ownershipDescription: String {
        switch self {
        case .agent: return "Only this agent"
        case .global: return "Shared across all agents"
        }
    }

    var yamlValue: String { rawValue }
}

// MARK: - Terminal Color Scheme

enum TerminalColorScheme: String, CaseIterable, Hashable {
    case `default` = "default"
    case claude = "claude"
    case solarizedDark = "solarized-dark"
    case solarizedLight = "solarized-light"
    case monokai = "monokai"
    case nord = "nord"
    case draculaPro = "dracula-pro"

    var displayName: String {
        switch self {
        case .default: return "Default"
        case .claude: return "Claude"
        case .solarizedDark: return "Solarized Dark"
        case .solarizedLight: return "Solarized Light"
        case .monokai: return "Monokai"
        case .nord: return "Nord"
        case .draculaPro: return "Dracula Pro"
        }
    }

    var theme: TerminalTheme {
        switch self {
        case .default: return TerminalTheme.defaultDark
        case .claude: return TerminalTheme(
            background: NSColor(srgbRed: 0.961, green: 0.937, blue: 0.902, alpha: 1.0), // #F5EFE6
            foreground: NSColor(srgbRed: 0.231, green: 0.196, blue: 0.149, alpha: 1.0)  // #3B3226
        )
        case .solarizedDark: return TerminalTheme(
            background: NSColor(srgbRed: 0.0, green: 0.169, blue: 0.212, alpha: 1.0),
            foreground: NSColor(srgbRed: 0.514, green: 0.580, blue: 0.588, alpha: 1.0)
        )
        case .solarizedLight: return TerminalTheme(
            background: NSColor(srgbRed: 0.992, green: 0.965, blue: 0.890, alpha: 1.0),
            foreground: NSColor(srgbRed: 0.396, green: 0.482, blue: 0.514, alpha: 1.0)
        )
        case .monokai: return TerminalTheme(
            background: NSColor(srgbRed: 0.153, green: 0.157, blue: 0.133, alpha: 1.0),
            foreground: NSColor(srgbRed: 0.973, green: 0.973, blue: 0.949, alpha: 1.0)
        )
        case .nord: return TerminalTheme(
            background: NSColor(srgbRed: 0.180, green: 0.204, blue: 0.251, alpha: 1.0),
            foreground: NSColor(srgbRed: 0.847, green: 0.871, blue: 0.914, alpha: 1.0)
        )
        case .draculaPro: return TerminalTheme(
            background: NSColor(srgbRed: 0.157, green: 0.165, blue: 0.212, alpha: 1.0),
            foreground: NSColor(srgbRed: 0.945, green: 0.945, blue: 0.945, alpha: 1.0)
        )
        }
    }
}

// MARK: - Terminal Cursor Style

enum TerminalCursorStyleSetting: String, CaseIterable, Hashable {
    case block = "block"
    case bar = "bar"
    case underline = "underline"

    var displayName: String {
        switch self {
        case .block: return "Block"
        case .bar: return "Bar"
        case .underline: return "Underline"
        }
    }

    func displayName(_ l10n: L10n) -> String {
        switch self {
        case .block: return l10n.block
        case .bar: return l10n.bar
        case .underline: return l10n.underline
        }
    }
}

// MARK: - Terminal Theme

/// Terminal color theme based on appearance mode.
struct TerminalTheme {
    let background: NSColor
    let foreground: NSColor

    static let defaultDark = TerminalTheme(
        background: NSColor(srgbRed: 0.11, green: 0.11, blue: 0.12, alpha: 1.0),
        foreground: NSColor(srgbRed: 0.91, green: 0.91, blue: 0.91, alpha: 1.0)
    )

    static let defaultLight = TerminalTheme(
        background: NSColor(srgbRed: 0.961, green: 0.969, blue: 0.980, alpha: 1.0), // #F5F7FA — matches unified UI offwhite
        foreground: NSColor(srgbRed: 0.1, green: 0.1, blue: 0.1, alpha: 1.0)
    )

    /// Returns the theme matching the current settings.
    static var current: TerminalTheme {
        // Check for custom color scheme first
        let schemeKey = UserDefaults.standard.string(forKey: "terminalColorScheme") ?? TerminalColorScheme.default.rawValue
        if let scheme = TerminalColorScheme(rawValue: schemeKey), scheme != .default {
            return scheme.theme
        }

        // Fall back to appearance-based theme
        let mode = UserDefaults.standard.string(forKey: "appearanceMode") ?? AppearanceMode.dark.rawValue
        switch AppearanceMode(rawValue: mode) {
        case .claude:
            return TerminalColorScheme.claude.theme
        case .light:
            return .defaultLight
        case .system:
            let isDark = MainActor.assumeIsolated {
                NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            }
            return isDark ? .defaultDark : .defaultLight
        default:
            return .defaultDark
        }
    }
}

// MARK: - Session Display Mode

enum SessionDisplayMode: String {
    case terminal
    case chat
}

// MARK: - Agent Process Status

enum AgentProcessStatus: Equatable {
    case running
    case waitingForInput
    case stopped(exitCode: Int32?)

    var isActive: Bool {
        switch self {
        case .running, .waitingForInput: return true
        case .stopped: return false
        }
    }

    var displayName: String {
        switch self {
        case .running: return "Running"
        case .waitingForInput: return "Waiting"
        case .stopped: return "Stopped"
        }
    }
}
