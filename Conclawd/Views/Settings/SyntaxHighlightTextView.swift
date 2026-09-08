import SwiftUI
import Highlightr

/// NSViewRepresentable wrapping an editable NSTextView with Highlightr syntax highlighting.
struct SyntaxHighlightTextView: NSViewRepresentable {
    @Binding var text: String
    let language: String?
    var isEditable: Bool = true
    var showLineNumbers: Bool = false
    var wordWrap: Bool = false
    var relativeScrollPosition: Double = 0
    /// When true, highlights skill variable placeholders ($ARGUMENTS, $0, ${VAR}, !`cmd`).
    var highlightSkillVariables: Bool = false
    /// Grayed-out hint text shown while the document is empty.
    var placeholder: String? = nil
    /// Reports the editor scroll position as a 0...1 ratio.
    var onRelativeScrollPositionChange: ((Double) -> Void)?
    /// Fired on mouseDown so the caller can switch active split-pane focus.
    var onMouseDown: (() -> Void)?
    /// Triggers updateNSView when appearance mode changes (e.g. Light ↔ Claude).
    @AppStorage("appearanceMode") private var appearanceMode: String = "dark"

    /// Past any of these limits the document is shown as plain text.
    ///
    /// Highlighting a large document blocks the main thread: Highlightr builds one
    /// attributed string for the whole file, `ensureAttributesAreFixedInRange:` then
    /// walks it on every layout pass, and a single very long line makes
    /// NSLayoutManager's glyph layout pathological. A 17MB JSON with a 52k-character
    /// line pegged the main thread and grew the process to a 50GB footprint.
    ///
    /// The line-length limit is the one that matters most: minified JSON stays under
    /// modest line counts while packing a whole document onto one line, so a check on
    /// size alone would let it through.
    static let highlightByteLimit = 1_000_000
    static let highlightLineLimit = 20_000
    static let highlightLineLengthLimit = 5_000

    /// Whether `text` is small enough to highlight without hanging the main thread.
    ///
    /// Lengths are counted in UTF-8 bytes — the limits are guard rails, not exact
    /// character counts. The byte check runs first so the scan below only ever walks
    /// a document already known to be under `highlightByteLimit`.
    static func isHighlightable(_ text: String) -> Bool {
        guard text.utf8.count <= highlightByteLimit else { return false }
        var lines = 1
        var lineLength = 0
        for byte in text.utf8 {
            if byte == UInt8(ascii: "\n") {
                lines += 1
                if lines > highlightLineLimit { return false }
                lineLength = 0
            } else {
                lineLength += 1
                if lineLength > highlightLineLengthLimit { return false }
            }
        }
        return true
    }

    /// False once the document trips `isHighlightable`, which drops the view to plain
    /// text: no Highlightr pass, and `CodeAttributedString` gets a nil language so it
    /// stops re-highlighting in the background.
    private var isHighlightingEnabled: Bool { Self.isHighlightable(text) }

    /// The language actually handed to Highlightr. Nil both for genuinely unknown file
    /// types (where Highlightr auto-detects) and for oversized documents — the call
    /// sites gate on `isHighlightingEnabled` so the oversized case skips highlighting
    /// entirely rather than paying for auto-detection.
    private var effectiveLanguage: String? { isHighlightingEnabled ? language : nil }

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

        // Oversized documents get a plain NSTextStorage rather than Highlightr's
        // CodeAttributedString. Disabling highlighting alone is not enough: every
        // `-[NSTextStorage string]` the typesetter makes lands on
        // CodeAttributedString's `var string: String` override, which bridges the
        // whole NSString to a Swift String and back. On an 11MB document AppKit
        // makes that call thousands of times per layout pass, which is what pegged
        // the main thread even with highlighting off.
        let codeStorage: CodeAttributedString? = isHighlightingEnabled
            ? CodeAttributedString(highlightr: highlightr)
            : nil
        let textStorage: NSTextStorage = codeStorage ?? NSTextStorage()
        codeStorage?.highlightDelegate = context.coordinator
        codeStorage?.language = effectiveLanguage

        let layoutManager = NSLayoutManager()
        // NSTextView leaves background layout on, so after an oversized document is
        // displayed NSLayoutManager keeps typesetting the rest of it during run loop
        // idle — minutes of main-thread work for a file the user is only scanning.
        // Layout on demand instead; only the visible range gets typeset.
        layoutManager.backgroundLayoutEnabled = isHighlightingEnabled
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
        textView.placeholderText = placeholder
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

        // The scroll view has to adopt the text view BEFORE the text goes in.
        // Assigning `documentView` a text view that already holds the document
        // makes AppKit lay the whole thing out synchronously to size the document
        // view; filling an already-installed text view instead lets layout stay
        // lazy. Measured on an 11MB JSON: 64ms this way, 28,356ms the other way
        // round — the single assignment was the whole hang.
        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = !wordWrap
        scrollView.drawsBackground = false
        scrollView.autohidesScrollers = true

        // Pre-highlight (skipped entirely for oversized documents)
        if isHighlightingEnabled, let highlighted = highlightr.highlight(text, as: language) {
            textStorage.beginEditing()
            textStorage.setAttributedString(highlighted)
            textStorage.endEditing()
        } else {
            textView.string = text
        }
        context.coordinator.appliedText = text

        context.coordinator.attach(to: scrollView)
        context.coordinator.textView = textView
        context.coordinator.highlightr = highlightr
        context.coordinator.codeStorage = codeStorage
        textStorage.delegate = context.coordinator

        textView.onMouseDown = onMouseDown
        context.coordinator.restoreRelativeScrollPosition(relativeScrollPosition, in: scrollView)

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = context.coordinator.textView as? LineNumberTextView,
              let highlightr = context.coordinator.highlightr else { return }

        context.coordinator.parent = self
        textView.onMouseDown = onMouseDown
        textView.placeholderText = placeholder

        // Theme
        let isDark = scrollView.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let expectedTheme = isDark ? "atom-one-dark" : "atom-one-light"
        let isClaude = NSColor.isClaudeTheme
        let themeKey = "\(expectedTheme)-\(isClaude)"
        if context.coordinator.currentTheme != themeKey {
            highlightr.setTheme(to: expectedTheme)
            textView.backgroundColor = Self.editorBackgroundColor(for: textView, highlightr: highlightr)
            context.coordinator.currentTheme = themeKey
            context.coordinator.codeStorage?.language = effectiveLanguage
            configureGutterTheme(textView, highlightr: highlightr)
        }

        // Language (only set when changed to avoid redundant background re-highlighting)
        if context.coordinator.codeStorage?.language != effectiveLanguage {
            context.coordinator.codeStorage?.language = effectiveLanguage
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
        if context.coordinator.appliedText != text {
            context.coordinator.isUpdating = true
            // Suppress CodeAttributedString's background re-highlighting during manual update
            // to avoid concurrent JSContext access (Highlightr is not thread-safe).
            context.coordinator.suppressCodeHighlighting = true
            if isHighlightingEnabled,
               let highlighted = highlightr.highlight(text, as: language),
               let codeStorage = context.coordinator.codeStorage {
                codeStorage.beginEditing()
                codeStorage.setAttributedString(highlighted)
                codeStorage.endEditing()
            } else {
                textView.string = text
            }
            context.coordinator.appliedText = text
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

        context.coordinator.restoreRelativeScrollPosition(relativeScrollPosition, in: scrollView)
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
        /// The text last written into the view, so `updateNSView` can skip the
        /// round trip through `textView.string` — reading that bridges the whole
        /// NSString to a Swift String, and comparing it costs another full pass.
        /// SwiftUI hands back the same String instance when nothing changed, so
        /// this comparison usually settles on a pointer check.
        var appliedText: String?
        var currentTheme: String = ""
        weak var scrollView: NSScrollView?
        private var scrollObserver: NSObjectProtocol?
        private var lastKnownRelativeScrollPosition: Double?
        private var isRestoringScrollPosition = false
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

        deinit {
            if let scrollObserver {
                NotificationCenter.default.removeObserver(scrollObserver)
            }
        }

        // MARK: - HighlightDelegate

        // MARK: - NSTextViewDelegate

        func textDidChange(_ notification: Notification) {
            guard !isUpdating, let textView = textView else { return }
            let updated = textView.string
            // Record what the view now holds before publishing it. Without this the
            // next updateNSView would see `appliedText` still on the pre-edit value,
            // rewrite the whole document, and throw away the selection.
            appliedText = updated
            parent.text = updated
        }

        func attach(to scrollView: NSScrollView) {
            self.scrollView = scrollView
            scrollView.contentView.postsBoundsChangedNotifications = true
            if let scrollObserver {
                NotificationCenter.default.removeObserver(scrollObserver)
            }
            scrollObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scrollView.contentView,
                queue: .main
            ) { [weak self] _ in
                self?.reportRelativeScrollPosition()
            }
        }

        func restoreRelativeScrollPosition(_ relativeScrollPosition: Double, in scrollView: NSScrollView) {
            let clamped = min(max(relativeScrollPosition, 0), 1)
            if let lastKnownRelativeScrollPosition,
               abs(lastKnownRelativeScrollPosition - clamped) < 0.001 {
                return
            }

            let maxOffset = max(scrollView.documentViewHeight - scrollView.contentSize.height, 0)
            guard maxOffset > 0 else {
                lastKnownRelativeScrollPosition = 0
                return
            }

            isRestoringScrollPosition = true
            let targetY = maxOffset * clamped
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: targetY))
            scrollView.reflectScrolledClipView(scrollView.contentView)
            isRestoringScrollPosition = false
            lastKnownRelativeScrollPosition = clamped
        }

        private func reportRelativeScrollPosition() {
            guard !isRestoringScrollPosition, let scrollView else { return }

            let maxOffset = max(scrollView.documentViewHeight - scrollView.contentSize.height, 0)
            let relative: Double
            if maxOffset > 0 {
                relative = min(max(Double(scrollView.contentView.bounds.origin.y / maxOffset), 0), 1)
            } else {
                relative = 0
            }

            lastKnownRelativeScrollPosition = relative
            parent.onRelativeScrollPositionChange?(relative)
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

private extension NSScrollView {
    var documentViewHeight: CGFloat {
        documentView?.bounds.height ?? 0
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
