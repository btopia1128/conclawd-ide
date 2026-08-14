import AppKit

/// NSTextView subclass that draws line numbers in the left margin
/// (textContainerInset area) during drawBackground.
/// No separate view, no coordinate conversion, no frame sync needed.
class LineNumberTextView: NSTextView {

    var showLineNumbers: Bool = false {
        didSet { needsDisplay = true }
    }

    var lineNumberFont: NSFont = .monospacedSystemFont(ofSize: 11, weight: .regular)
    var lineNumberColor: NSColor = .secondaryLabelColor
    var gutterBackgroundColor: NSColor = .clear

    /// Grayed-out hint text drawn when the document is empty.
    var placeholderText: String? {
        didSet {
            if placeholderText != oldValue { needsDisplay = true }
        }
    }

    /// Invoked on mouseDown so SwiftUI can switch the active split pane before
    /// AppKit takes over first-responder handling.
    var onMouseDown: (() -> Void)?

    /// Tracks the last drawn empty state so didChangeText only invalidates the
    /// full view on empty <-> non-empty transitions.
    private var placeholderWasVisible = false

    override func mouseDown(with event: NSEvent) {
        onMouseDown?()
        super.mouseDown(with: event)
    }

    /// AppKit only redraws the dirty rect around an edit, so line numbers for
    /// lines shifted by an insertion/deletion (e.g. a newline) don't refresh
    /// until the view is fully redrawn. Invalidate the visible gutter column on
    /// every text change so the numbers stay in sync.
    override func didChangeText() {
        super.didChangeText()
        if placeholderText != nil {
            let isEmpty = string.isEmpty
            if isEmpty != placeholderWasVisible {
                placeholderWasVisible = isEmpty
                needsDisplay = true
            }
        }
        guard showLineNumbers else { return }
        let gutterRect = NSRect(
            x: visibleRect.minX,
            y: visibleRect.minY,
            width: textContainerInset.width,
            height: visibleRect.height
        )
        setNeedsDisplay(gutterRect)
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        drawPlaceholderIfNeeded()
        guard showLineNumbers, let layoutManager = layoutManager else { return }

        let insetWidth = textContainerInset.width
        guard insetWidth > 8 else { return }

        // Draw line numbers
        let string = self.string as NSString
        guard string.length > 0, layoutManager.numberOfGlyphs > 0 else { return }

        let originY = textContainerOrigin.y
        let numGlyphs = layoutManager.numberOfGlyphs
        let attrs: [NSAttributedString.Key: Any] = [
            .font: lineNumberFont,
            .foregroundColor: lineNumberColor,
        ]

        var lineNumber = 1
        var charIndex = 0

        while charIndex < string.length {
            let lineRange = string.lineRange(for: NSRange(location: charIndex, length: 0))
            let glyphRange = layoutManager.glyphRange(
                forCharacterRange: lineRange, actualCharacterRange: nil
            )

            if glyphRange.location < numGlyphs {
                let lineRect = layoutManager.lineFragmentRect(
                    forGlyphAt: glyphRange.location, effectiveRange: nil
                )
                let y = lineRect.origin.y + originY

                if y > rect.maxY { break }

                if y + lineRect.height >= rect.minY {
                    let numStr = "\(lineNumber)" as NSString
                    let numSize = numStr.size(withAttributes: attrs)
                    numStr.draw(
                        at: NSPoint(
                            x: insetWidth - numSize.width - 12,
                            y: y + (lineRect.height - numSize.height) / 2
                        ),
                        withAttributes: attrs
                    )
                }
            }

            lineNumber += 1
            let next = NSMaxRange(lineRange)
            if next <= charIndex { break }
            charIndex = next
        }
    }

    private func drawPlaceholderIfNeeded() {
        placeholderWasVisible = string.isEmpty
        guard string.isEmpty, let placeholderText, !placeholderText.isEmpty else { return }

        let attrs: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
            .foregroundColor: NSColor.placeholderTextColor,
        ]
        let padding = textContainer?.lineFragmentPadding ?? 5
        let origin = NSPoint(
            x: textContainerInset.width + padding,
            y: textContainerInset.height
        )
        let maxWidth = max(bounds.width - origin.x - textContainerInset.width, 0)
        guard maxWidth > 0 else { return }
        (placeholderText as NSString).draw(
            in: NSRect(x: origin.x, y: origin.y, width: maxWidth, height: bounds.height - origin.y),
            withAttributes: attrs
        )
    }
}
