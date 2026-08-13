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

    /// Invoked on mouseDown so SwiftUI can switch the active split pane before
    /// AppKit takes over first-responder handling.
    var onMouseDown: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        onMouseDown?()
        super.mouseDown(with: event)
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
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
}
