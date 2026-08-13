import AppKit
import SwiftUI

// MARK: - AppColors

/// Adaptive color palette with guaranteed readability in both light and dark modes.
/// Light mode values are chosen for WCAG AA contrast (≥ 4.5:1) against white backgrounds.
extension Color {

    // MARK: - Text Hierarchy

    /// Secondary text color – replaces `.secondary` / `.foregroundStyle(.secondary)`.
    /// Light: #636366 (≈5.5:1 on white), Dark: system secondaryLabel.
    static let appSecondary = Color(nsColor: .appSecondary)

    /// Tertiary text color – replaces `.tertiary` / `.foregroundStyle(.tertiary)`.
    /// Light: #757578 (≈4.6:1 on white), Dark: system tertiaryLabel.
    static let appTertiary = Color(nsColor: .appTertiary)

    // MARK: - Muted / Empty-State

    /// Muted heading – replaces `.gray` for empty-state headings.
    /// Light: #6B6B70 (≈5.0:1), Dark: #8E8E93.
    static let appMuted = Color(nsColor: .appMuted)

    /// Subtle text – replaces `.gray.opacity(0.5)` for descriptions / subtitles.
    /// Light: #848489 (≈3.9:1, acceptable for supplementary text), Dark: #636366.
    static let appSubtle = Color(nsColor: .appSubtle)

    // MARK: - Status

    /// "Ready" / "Waiting for input" status.
    /// Light: #9A6700 (warm amber, ≈5.0:1), Dark: #FFD60A (bright yellow).
    static let statusReady = Color(nsColor: .statusReady)

    /// "Running" / "Thinking" status.
    /// Light: #1A7F37 (vivid green, ≈4.5:1), Dark: #30D158.
    static let statusRunning = Color(nsColor: .statusRunning)

    /// "Stopped" status.
    /// Light: #8E8E93 (≈3.5:1), Dark: #636366.
    static let statusStopped = Color(nsColor: .statusStopped)

    // MARK: - UI Elements

    /// Light border / stroke – replaces `.gray.opacity(0.4)`.
    /// Light: #C8C8CD (soft separator), Dark: rgba(255,255,255,0.15).
    static let appBorder = Color(nsColor: .appBorder)

    /// Muted icon fill – replaces `.gray.opacity(0.5)` on icons / indicators.
    /// Light: #929297, Dark: rgba(255,255,255,0.3).
    static let appIconMuted = Color(nsColor: .appIconMuted)

    // MARK: - Shadows

    /// Subtle card shadow – adaptive per appearance.
    /// Light: black 7%, Dark: black 25%.
    static let appShadow = Color(nsColor: .appShadow)

    /// Elevated / floating element shadow.
    /// Light: black 12%, Dark: black 40%.
    static let appShadowStrong = Color(nsColor: .appShadowStrong)

    // MARK: - Theme-Aware Surfaces
    //
    // All surfaces return the SAME color per theme so every pane (sidebar,
    // editor, terminal chrome, settings, chat, toolbars) shares a single
    // background — mirroring the Claude theme's uniform look.
    //
    // - Claude → #F5EFE6 (sand beige)
    // - Light  → #F5F7FA (cool offwhite, easier on the eyes than pure white)
    // - Dark   → system windowBackgroundColor (unchanged)

    /// Primary surface color for sidebars, toolbars, editors.
    static var appSurface: Color {
        if NSColor.isClaudeTheme {
            return Color(red: 0.961, green: 0.937, blue: 0.902) // #F5EFE6
        }
        return Color(nsColor: .appUnifiedSurface)
    }

    /// Alias for appSurface — kept for source compatibility. All surfaces
    /// now share the same value.
    static var appSurfaceSecondary: Color { appSurface }

    /// Window / panel background.
    static var appWindowBackground: Color { appSurface }
}

// MARK: - Themed Background Modifier

/// Applies a themed background that re-evaluates when appearance mode changes.
private struct ThemedBackgroundModifier: ViewModifier {
    @AppStorage("appearanceMode") private var appearanceMode: String = "dark"
    let colorProvider: () -> Color

    func body(content: Content) -> some View {
        let _ = appearanceMode
        content.background(colorProvider())
    }
}

extension View {
    /// Background that automatically updates when switching between appearance modes (e.g. Light ↔ Claude).
    func themedBackground(_ color: @autoclosure @escaping () -> Color) -> some View {
        modifier(ThemedBackgroundModifier(colorProvider: color))
    }
}

// MARK: - NSColor Definitions

extension NSColor {

    // MARK: Text

    static let appSecondary = NSColor(name: nil) { appearance in
        if appearance.isDarkMode {
            return .secondaryLabelColor
        }
        return NSColor(srgbRed: 0.388, green: 0.388, blue: 0.400, alpha: 1.0) // #636366
    }

    static let appTertiary = NSColor(name: nil) { appearance in
        if appearance.isDarkMode {
            return .tertiaryLabelColor
        }
        return NSColor(srgbRed: 0.459, green: 0.459, blue: 0.471, alpha: 1.0) // #757578
    }

    // MARK: Muted / Empty-State

    static let appMuted = NSColor(name: nil) { appearance in
        if appearance.isDarkMode {
            return NSColor(srgbRed: 0.557, green: 0.557, blue: 0.576, alpha: 1.0) // #8E8E93
        }
        return NSColor(srgbRed: 0.420, green: 0.420, blue: 0.439, alpha: 1.0) // #6B6B70
    }

    static let appSubtle = NSColor(name: nil) { appearance in
        if appearance.isDarkMode {
            return NSColor(srgbRed: 0.388, green: 0.388, blue: 0.400, alpha: 1.0) // #636366
        }
        return NSColor(srgbRed: 0.518, green: 0.518, blue: 0.537, alpha: 1.0) // #848489
    }

    // MARK: Status

    static let statusReady = NSColor(name: nil) { appearance in
        if appearance.isDarkMode {
            return NSColor(srgbRed: 1.0, green: 0.839, blue: 0.039, alpha: 1.0) // #FFD60A
        }
        return NSColor(srgbRed: 0.604, green: 0.404, blue: 0.0, alpha: 1.0) // #9A6700
    }

    static let statusRunning = NSColor(name: nil) { appearance in
        if appearance.isDarkMode {
            return NSColor(srgbRed: 0.188, green: 0.820, blue: 0.345, alpha: 1.0) // #30D158
        }
        return NSColor(srgbRed: 0.102, green: 0.498, blue: 0.216, alpha: 1.0) // #1A7F37
    }

    static let statusStopped = NSColor(name: nil) { appearance in
        if appearance.isDarkMode {
            return NSColor(srgbRed: 0.388, green: 0.388, blue: 0.400, alpha: 1.0) // #636366
        }
        return NSColor(srgbRed: 0.557, green: 0.557, blue: 0.576, alpha: 1.0) // #8E8E93
    }

    // MARK: UI Elements

    static let appBorder = NSColor(name: nil) { appearance in
        if appearance.isDarkMode {
            return NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 0.15)
        }
        return NSColor(srgbRed: 0.784, green: 0.784, blue: 0.804, alpha: 1.0) // #C8C8CD
    }

    static let appIconMuted = NSColor(name: nil) { appearance in
        if appearance.isDarkMode {
            return NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 0.30)
        }
        return NSColor(srgbRed: 0.573, green: 0.573, blue: 0.592, alpha: 1.0) // #929297
    }

    // MARK: Shadows

    static let appShadow = NSColor(name: nil) { appearance in
        if appearance.isDarkMode {
            return NSColor(srgbRed: 0.0, green: 0.0, blue: 0.0, alpha: 0.25)
        }
        return NSColor(srgbRed: 0.0, green: 0.0, blue: 0.0, alpha: 0.07)
    }

    static let appShadowStrong = NSColor(name: nil) { appearance in
        if appearance.isDarkMode {
            return NSColor(srgbRed: 0.0, green: 0.0, blue: 0.0, alpha: 0.40)
        }
        return NSColor(srgbRed: 0.0, green: 0.0, blue: 0.0, alpha: 0.12)
    }

    // MARK: Unified Surface

    /// Single offwhite surface used for every major pane in light mode.
    /// Dark mode keeps the system window background unchanged.
    static let appUnifiedSurface = NSColor(name: nil) { appearance in
        if appearance.isDarkMode {
            return .windowBackgroundColor
        }
        return NSColor(srgbRed: 0.961, green: 0.969, blue: 0.980, alpha: 1.0) // #F5F7FA
    }

    // MARK: Theme Detection

    /// Whether the current appearance or terminal color scheme is Claude beige.
    static var isClaudeTheme: Bool {
        let appearance = UserDefaults.standard.string(forKey: "appearanceMode") ?? ""
        if appearance == AppearanceMode.claude.rawValue { return true }
        let scheme = UserDefaults.standard.string(forKey: "terminalColorScheme") ?? ""
        return scheme == TerminalColorScheme.claude.rawValue
    }

}

// MARK: - NSAppearance Helper

extension NSAppearance {
    fileprivate var isDarkMode: Bool {
        bestMatch(from: [NSAppearance.Name.darkAqua, NSAppearance.Name.aqua]) == .darkAqua
    }
}
