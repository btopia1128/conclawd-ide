import SwiftUI
import Highlightr

/// NSViewRepresentable wrapping an editable NSTextView with Highlightr syntax highlighting.
struct SyntaxHighlightTextView: NSViewRepresentable {
    @Binding var text: String
    let language: String?
    var isEditable: Bool = true
    var showLineNumbers: Bool = false
    var wordWrap: Bool = false
    /// When true, highlights skill variable placeholders ($ARGUMENTS, $0, ${VAR}, !`cmd`).
    var highlightSkillVariables: Bool = false
    /// Fired on mouseDown so the caller can switch active split-pane focus.
    var onMouseDown: (() -> Void)?
    /// Triggers updateNSView when appearance mode changes (e.g. Light ↔ Claude).
    @AppStorage("appearanceMode") private var appearanceMode: String = "dark"

    private static let defaultInsetX: CGFloat = 16
    private static let gutterInsetX: CGFloat = 44

    /// Resolves the editor background so it matches the unified app surface
    /// in Claude/Light modes. Dark mode keeps the Highlightr theme bg so the
    /// syntax colors stay legible on the theme they were designed for.
    private static func editorBackgroundColor(for textView: NSView, highlightr: Highlightr) -> NSColor {
        if NSColor.isClaudeTheme {
            return NSColor(srgbRed: 0.961, green: 0.937, blue: 0.902, alpha: 1.0) // #F5EFE6
        }
        let isDark = textView.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        if !isDark {
            return NSColor(srgbRed: 0.961, green: 0.969, blue: 0.980, alpha: 1.0) // #F5F7FA
        }
        return highlightr.theme.themeBackgroundColor ?? .textBackgroundColor
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let highlightr = Highlightr()!
        applyTheme(highlightr)

        let textStorage = CodeAttributedString(highlightr: highlightr)
        textStorage.highlightDelegate = context.coordinator
        textStorage.language = language

        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)

        let textContainer = NSTextContainer()
        textContainer.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textContainer.widthTracksTextView = wordWrap
        layoutManager.addTextContainer(textContainer)

        let insetX = showLineNumbers ? Self.gutterInsetX : Self.defaultInsetX

        // Use LineNumberTextView instead of plain NSTextView
        let textView = LineNumberTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 100), textContainer: textContainer)
        textView.showLineNumbers = showLineNumbers
        textView.isEditable = isEditable
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.textContainerInset = NSSize(width: insetX, height: 16)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.drawsBackground = true
        textView.backgroundColor = Self.editorBackgroundColor(for: textView, highlightr: highlightr)
        textView.insertionPointColor = NSColor.textColor
        textView.delegate = context.coordinator
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = !wordWrap
        textView.autoresizingMask = wordWrap ? [.width] : []
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.minSize = NSSize(width: 0, height: 0)

        // Configure gutter theme
        configureGutterTheme(textView, highlightr: highlightr)

        // Pre-highlight
        if let highlighted = highlightr.highlight(text, as: language) {
            textStorage.beginEditing()
            textStorage.setAttributedString(highlighted)
            textStorage.endEditing()
        } else {
            textView.string = text
        }

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = !wordWrap
        scrollView.drawsBackground = false
        scrollView.autohidesScrollers = true

        context.coordinator.textView = textView
        context.coordinator.highlightr = highlightr
        context.coordinator.codeStorage = textStorage
        textStorage.delegate = context.coordinator

        textView.onMouseDown = onMouseDown

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = context.coordinator.textView as? LineNumberTextView,
              let highlightr = context.coordinator.highlightr else { return }

        textView.onMouseDown = onMouseDown

        // Theme
        let isDark = scrollView.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let expectedTheme = isDark ? "atom-one-dark" : "atom-one-light"
        let isClaude = NSColor.isClaudeTheme
        let themeKey = "\(expectedTheme)-\(isClaude)"
        if context.coordinator.currentTheme != themeKey {
            highlightr.setTheme(to: expectedTheme)
            textView.backgroundColor = Self.editorBackgroundColor(for: textView, highlightr: highlightr)
            context.coordinator.currentTheme = themeKey
            context.coordinator.codeStorage?.language = language
            configureGutterTheme(textView, highlightr: highlightr)
        }

        // Language (only set when changed to avoid redundant background re-highlighting)
        if context.coordinator.codeStorage?.language != language {
            context.coordinator.codeStorage?.language = language
        }

        // Word wrap
        if let tc = textView.textContainer {
            let wrapping = tc.widthTracksTextView
            if wrapping != wordWrap {
                tc.widthTracksTextView = wordWrap
                tc.containerSize = NSSize(
                    width: wordWrap ? scrollView.contentSize.width : CGFloat.greatestFiniteMagnitude,
                    height: CGFloat.greatestFiniteMagnitude
                )
                textView.isHorizontallyResizable = !wordWrap
                textView.autoresizingMask = wordWrap ? [.width] : []
                scrollView.hasHorizontalScroller = !wordWrap
                textView.needsLayout = true
                textView.needsDisplay = true
            }
        }

        // Line numbers toggle
        if textView.showLineNumbers != showLineNumbers {
            textView.showLineNumbers = showLineNumbers
            let insetX = showLineNumbers ? Self.gutterInsetX : Self.defaultInsetX
            textView.textContainerInset = NSSize(width: insetX, height: 16)
            textView.needsDisplay = true
        }

        // Text sync
        if textView.string != text {
            context.coordinator.isUpdating = true
            // Suppress CodeAttributedString's background re-highlighting during manual update
            // to avoid concurrent JSContext access (Highlightr is not thread-safe).
            context.coordinator.suppressCodeHighlighting = true
            if let highlighted = highlightr.highlight(text, as: language),
               let codeStorage = context.coordinator.codeStorage {
                codeStorage.beginEditing()
                codeStorage.setAttributedString(highlighted)
                codeStorage.endEditing()
            } else {
                textView.string = text
            }
            context.coordinator.suppressCodeHighlighting = false
            context.coordinator.isUpdating = false
        }

        // Word wrap container width fix
        if wordWrap, let tc = textView.textContainer {
            let contentWidth = scrollView.contentSize.width - textView.textContainerInset.width * 2
            if contentWidth > 0 {
                tc.containerSize = NSSize(width: contentWidth, height: CGFloat.greatestFiniteMagnitude)
            }
        }

        textView.isEditable = isEditable
    }

    private func applyTheme(_ highlightr: Highlightr) {
        let isDark = MainActor.assumeIsolated {
            NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        }
        highlightr.setTheme(to: isDark ? "atom-one-dark" : "atom-one-light")
    }

    private func configureGutterTheme(_ textView: LineNumberTextView, highlightr: Highlightr) {
        let bgColor = Self.editorBackgroundColor(for: textView, highlightr: highlightr)
        textView.gutterBackgroundColor = bgColor.blended(withFraction: 0.05, of: .gray) ?? bgColor
        textView.lineNumberColor = .secondaryLabelColor
    }

    class Coordinator: NSObject, NSTextViewDelegate, @unchecked Sendable {
        var parent: SyntaxHighlightTextView
        var textView: NSTextView?
        var highlightr: Highlightr?
        var codeStorage: CodeAttributedString?
        var isUpdating = false
        var currentTheme: String = ""
        /// When true, suppresses CodeAttributedString's background re-highlighting.
        /// Prevents concurrent JSContext access (Highlightr is not thread-safe).
        var suppressCodeHighlighting = false

        /// Regex patterns for skill variable highlighting.
        private static let skillVariablePatterns: [(pattern: NSRegularExpression, color: NSColor)] = {
            let defs: [(String, NSColor)] = [
                (#"\$ARGUMENTS(\[\d+\])?"#, .systemOrange),
                (#"\$\d+"#, .systemOrange),
                (#"\$\{[A-Z_]+\}"#, .systemCyan),
                (#"!\`.+?\`"#, .systemGreen),
            ]
            return defs.compactMap { (pattern, color) in
                guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
                return (regex, color)
            }
        }()

        init(_ parent: SyntaxHighlightTextView) {
            self.parent = parent
        }

        // MARK: - HighlightDelegate

        // MARK: - NSTextViewDelegate

        func textDidChange(_ notification: Notification) {
            guard !isUpdating, let textView = textView else { return }
            parent.text = textView.string
        }

        /// Apply skill variable highlights using layout manager temporary attributes
        /// (won't interfere with Highlightr's text storage attributes).
        func applySkillVariableHighlights(to layoutManager: NSLayoutManager, in text: String) {
            let fullRange = NSRange(location: 0, length: (text as NSString).length)
            // Ensure range doesn't exceed layout manager's character count
            let charCount = layoutManager.textStorage?.length ?? 0
            guard fullRange.length <= charCount else { return }
            // Clear previous temporary highlights
            layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: fullRange)
            for (regex, color) in Self.skillVariablePatterns {
                let matches = regex.matches(in: text, range: fullRange)
                for match in matches {
                    layoutManager.addTemporaryAttribute(.foregroundColor, value: color, forCharacterRange: match.range)
                }
            }
        }
    }

    static func language(for fileExtension: String, fileName: String? = nil) -> String? {
        // Handle special filenames first (e.g. .env.local, .env.production, Dockerfile, Makefile)
        if let name = fileName?.lowercased() {
            if name == ".env" || name.hasPrefix(".env.") { return "ini" }
            if name == "dockerfile" { return "dockerfile" }
            if name == "makefile" { return "makefile" }
        }

        switch fileExtension.lowercased() {
        case "py": return "python"
        case "js", "mjs", "cjs": return "javascript"
        case "ts", "mts": return "typescript"
        case "tsx": return "typescript"
        case "jsx": return "javascript"
        case "swift": return "swift"
        case "sh", "bash", "zsh": return "bash"
        case "rb": return "ruby"
        case "go": return "go"
        case "rs": return "rust"
        case "java": return "java"
        case "kt", "kts": return "kotlin"
        case "c", "h": return "c"
        case "cpp", "cc", "cxx", "hpp": return "cpp"
        case "cs": return "csharp"
        case "html", "htm": return "xml"
        case "css": return "css"
        case "json": return "json"
        case "yaml", "yml": return "yaml"
        case "xml", "plist": return "xml"
        case "md", "markdown": return "markdown"
        case "sql": return "sql"
        case "r": return "r"
        case "php": return "php"
        case "toml": return "ini"
        case "env": return "ini"
        case "lua": return "lua"
        case "dockerfile": return "dockerfile"
        case "makefile": return "makefile"
        default: return nil
        }
    }
}

// MARK: - Coordinator Protocol Conformances (concurrency-safe)

extension SyntaxHighlightTextView.Coordinator: HighlightDelegate {
    func shouldHighlight(_ range: NSRange) -> Bool {
        !suppressCodeHighlighting
    }
}

extension SyntaxHighlightTextView.Coordinator: NSTextStorageDelegate {
    func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions, range editedRange: NSRange, changeInLength delta: Int) {
        guard parent.highlightSkillVariables,
              let layoutManager = textView?.layoutManager else { return }
        let text = textStorage.string
        DispatchQueue.main.async { [weak self] in
            self?.applySkillVariableHighlights(to: layoutManager, in: text)
        }
    }
}
