import AppKit
@preconcurrency import SwiftTerm
import UniformTypeIdentifiers

/// A subclass of LocalProcessTerminalView that adds IME (Input Method Editor)
/// composition text overlay, fixing the missing marked text display in SwiftTerm.
class IMETerminalView: LocalProcessTerminalView {

    /// Tell AppKit this view is NOT opaque so the TerminalHostView's layer
    /// background shows through areas that SwiftTerm's draw() doesn't cover
    /// (fractional row gap at the bottom, regions skipped by dirty-rect
    /// optimization during resize or scrolling).
    override var isOpaque: Bool { false }

    /// The overlay text field used to display IME composing text.
    private var imeOverlay: NSTextField?

    /// The current marked (composing) text.
    private var currentMarkedText: NSAttributedString?

    /// Whether we currently have marked text.
    private var _hasMarkedText = false

    /// Called when output data is received from the process (for idle tracking).
    var onDataReceived: (() -> Void)?

    /// Called when the user submits a prompt (presses Enter).
    /// The String parameter contains the prompt text extracted synchronously before Enter is processed.
    var onPromptSubmitted: ((String?) -> Void)?

    /// Called when "--resume" is detected in incoming process output.
    var onResumeLineDetected: (() -> Void)?

    /// Image file extensions supported for drag & drop and paste.
    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "bmp", "tiff", "tif", "svg"]

    // MARK: - Drag & Drop Setup

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        if superview != nil {
            // `.URL` matters too: a drag started by SwiftUI's `.onDrag` doesn't
            // always advertise `public.file-url`, and a view is only offered
            // drags carrying a type it registered for.
            registerForDraggedTypes([.fileURL, .URL])
        }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard hasFileURLs(in: sender) else { return [] }
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard hasFileURLs(in: sender) else { return [] }
        return .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = Self.droppedFileURLs(from: sender)
        guard !urls.isEmpty else { return false }

        sendAsInput(urls.map { Self.escapedPath(for: $0) }.joined(separator: " "))
        return true
    }

    /// Type check only — actual data may still be promised during the drag
    /// (SwiftUI .onDrag item providers deliver data at drop time), so reading
    /// objects here would reject in-app drags from the file tree.
    private func hasFileURLs(in info: NSDraggingInfo) -> Bool {
        if info.draggingPasteboard.availableType(from: [.fileURL, .URL]) != nil { return true }
        return info.draggingSource != nil && FileDragSession.isActive
    }

    /// Resolve the dropped items, preferring the pasteboard (Finder and other
    /// apps) and falling back to the in-flight file tree drag, whose promised
    /// pasteboard data isn't delivered synchronously here. `draggingSource` is
    /// non-nil only for drags started inside this process, which keeps the
    /// fallback from firing on an external drop.
    static func droppedFileURLs(from info: NSDraggingInfo) -> [URL] {
        let urls = fileURLs(from: info.draggingPasteboard)
        if !urls.isEmpty {
            FileDragSession.consume()
            return urls
        }
        guard info.draggingSource != nil else { return [] }
        return FileDragSession.consume()
    }

    static func fileURLs(from pasteboard: NSPasteboard) -> [URL] {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true
        ]) as? [URL], !urls.isEmpty {
            return urls
        }
        // Fallback: raw file-url strings, for providers the object read misses
        return (pasteboard.pasteboardItems ?? []).compactMap { item in
            item.string(forType: .fileURL).flatMap { URL(string: $0) }
        }.filter(\.isFileURL)
    }

    /// Backslash-escape spaces (and existing backslashes) the way Terminal.app
    /// does, so a dropped path stays usable as a single argument.
    static func escapedPath(for url: URL) -> String {
        url.path(percentEncoded: false)
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: " ", with: "\\ ")
    }

    /// Send text to the terminal process using bracketed paste when available,
    /// so that applications like Claude Code properly receive the input.
    func sendAsInput(_ text: String) {
        if terminal.bracketedPasteMode {
            send(data: EscapeSequences.bracketedPasteStart[0...])
            send(txt: text)
            send(data: EscapeSequences.bracketedPasteEnd[0...])
        } else {
            send(txt: text)
        }
    }

    // MARK: - Clipboard Image Paste

    override func paste(_ sender: Any?) {
        let pb = NSPasteboard.general

        // If clipboard has an image (not a file URL), save to temp file and send path
        if pb.types?.contains(.tiff) == true || pb.types?.contains(.png) == true {
            // Skip if it's a file copy (has fileURL), let normal paste handle file paths
            if pb.types?.contains(.fileURL) == true,
               let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
               !urls.isEmpty {
                // It's a file copy — check if it's an image file
                let imageURLs = urls.filter { Self.imageExtensions.contains($0.pathExtension.lowercased()) }
                if !imageURLs.isEmpty {
                    for url in imageURLs {
                        sendAsInput(url.path(percentEncoded: false))
                    }
                    return
                }
                // Non-image file, fall through to default paste
                super.paste(sender as Any)
                return
            }

            // It's a screenshot or copied image data — save to temp file
            if let tempPath = saveClipboardImageToTemp(pb) {
                sendAsInput(tempPath)
                return
            }
        }

        super.paste(sender as Any)
    }

    private func saveClipboardImageToTemp(_ pb: NSPasteboard) -> String? {
        guard let image = NSImage(pasteboard: pb),
              let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            return nil
        }

        let fileName = "clipboard-\(UUID().uuidString.prefix(8)).png"
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("Conclawd", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let filePath = tempDir.appendingPathComponent(fileName)

        do {
            try pngData.write(to: filePath)
            return filePath.path(percentEncoded: false)
        } catch {
            return nil
        }
    }

    // MARK: - Frame Size Preservation

    /// Preserve the user's scrollback position across frame-size changes.
    /// In split view, SwiftUI layout passes can trigger resize during streaming,
    /// and Terminal.resize → Buffer.reflow shifts yDisp without firing the
    /// scrolled delegate. Capture the relative position before the reflow and
    /// restore it after via the public scroll(toPosition:) API.
    override func setFrameSize(_ newSize: NSSize) {
        let savedPosition: Double? = (scrollPosition < 1.0 && canScroll) ? scrollPosition : nil
        super.setFrameSize(newSize)
        if let savedPosition, scrollPosition >= 1.0 || scrollPosition != savedPosition {
            scroll(toPosition: savedPosition)
        }
    }

    // MARK: - Scroll Position Preservation

    /// When non-nil, Terminal.scroll() callbacks restore yDisp to this value
    /// instead of allowing auto-scroll to the bottom.
    private var _preserveYDisp: Int?

    /// TerminalDelegate callback — called from Terminal.scroll() after yDisp = yBase.
    /// By restoring yDisp HERE (inside the feed pipeline), we prevent the auto-scroll
    /// from taking effect before updateScroller/queuePendingDisplay run.
    override func scrolled(source: Terminal, yDisp: Int) {
        if let preserved = _preserveYDisp {
            source.buffer.yDisp = preserved
            super.scrolled(source: source, yDisp: preserved)
        } else {
            super.scrolled(source: source, yDisp: yDisp)
        }
    }

    // MARK: - Data Activity Tracking

    private static let resumeMarker = Array("--resume".utf8)

    override func dataReceived(slice: ArraySlice<UInt8>) {
        // When the user has scrolled back, preserve their position.
        // scrollPosition (public API) returns 1.0 at the bottom.
        let wasAtBottom = scrollPosition >= 1.0 || !canScroll
        let preserved: Int? = wasAtBottom ? nil : terminal.buffer.yDisp
        _preserveYDisp = preserved
        super.dataReceived(slice: slice)
        _preserveYDisp = nil
        // Safety net: Buffer.resize/reflow can shift yDisp without going through
        // the scrolled(source:yDisp:) delegate (Buffer.swift:473, 544, 1003).
        // In split view, layout passes trigger resize more often than in single
        // view, so each streamed chunk can drift yDisp downward by 1.
        // Pin yDisp back to the user's original position after the feed.
        if let preserved, terminal.buffer.yDisp != preserved {
            terminal.buffer.yDisp = preserved
            needsDisplay = true
        }
        onDataReceived?()

        // Quick byte scan: detect "--resume" in incoming data to capture
        // the resume ID as soon as Claude outputs it (before process exits).
        if slice.count >= Self.resumeMarker.count, Self.containsMarker(slice) {
            onResumeLineDetected?()
        }
    }

    private static func containsMarker(_ slice: ArraySlice<UInt8>) -> Bool {
        let marker = resumeMarker
        let end = slice.endIndex - marker.count
        guard end >= slice.startIndex else { return false }
        for i in slice.startIndex...end {
            var match = true
            for j in 0..<marker.count {
                if slice[i + j] != marker[j] {
                    match = false
                    break
                }
            }
            if match { return true }
        }
        return false
    }

    // MARK: - Event Monitoring (Enter Key)

    private var keyMonitor: Any?

    /// Start monitoring for Enter key presses when the view is added to a window.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()

        if window != nil && keyMonitor == nil {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, self.window?.firstResponder === self else { return event }

                // --- Arrow keys fix ---
                // macOS sets .numericPad on ALL arrow key events (even regular arrow keys).
                // SwiftTerm misclassifies them as keypadUp/Down/Left/Right (57417-57420)
                // when Kitty keyboard protocol is active, which Claude Code CLI cannot parse.
                // Intercept here and send correct CSI sequences.
                if !self.terminal.keyboardEnhancementFlags.isEmpty && !self._hasMarkedText {
                    let arrowSuffix: UInt8? = switch Int(event.keyCode) {
                    case 126: UInt8(ascii: "A") // kVK_UpArrow
                    case 125: UInt8(ascii: "B") // kVK_DownArrow
                    case 124: UInt8(ascii: "C") // kVK_RightArrow
                    case 123: UInt8(ascii: "D") // kVK_LeftArrow
                    default: nil
                    }
                    if let suffix = arrowSuffix {
                        var mod = 0
                        if event.modifierFlags.contains(.shift)   { mod += 1 }
                        if event.modifierFlags.contains(.option)  { mod += 2 }
                        if event.modifierFlags.contains(.control) { mod += 4 }
                        if mod > 0 {
                            // ESC [ 1 ; {mod+1} {letter}
                            var seq: [UInt8] = [0x1b, 0x5b, 0x31, 0x3b]
                            seq.append(contentsOf: Array("\(mod + 1)".utf8))
                            seq.append(suffix)
                            self.send(data: seq[0...])
                        } else {
                            // ESC [ {letter}
                            self.send(data: [0x1b, 0x5b, suffix][0...])
                        }
                        return nil
                    }
                }

                // --- Shift+Return fix ---
                // SwiftTerm loses the Shift modifier through interpretKeyEvents → doCommand path.
                // Send ESC[13;2u (CSI u) directly so Claude Code CLI recognizes newline.
                // keyCode 36 = Return, 76 = Numpad Enter
                if (event.keyCode == 36 || event.keyCode == 76) && !self._hasMarkedText {
                    if event.modifierFlags.contains(.shift) {
                        let csiU: [UInt8] = [0x1b, 0x5b, 0x31, 0x33, 0x3b, 0x32, 0x75]
                        self.send(data: csiU[0...])
                        return nil
                    }
                    // Extract prompt text synchronously BEFORE Enter key is processed
                    let promptText = self.extractCurrentPrompt()
                    self.onPromptSubmitted?(promptText)
                }
                return event
            }
        } else if window == nil {
            removeEventMonitors()
        }
    }

    /// Extracts the last user prompt from the visible terminal buffer.
    /// Claude CLI uses ❯ followed by NON-BREAKING SPACE (U+00A0), not regular space.
    private func extractCurrentPrompt() -> String? {
        let terminal = getTerminal()
        let promptPrefixes = ["❯\u{00A0}", "❯ ", "> "]
        var lastPrompt: String?
        for row in 0..<terminal.rows {
            guard let line = terminal.getLine(row: row) else { continue }
            let raw = line.translateToString(trimRight: true)
                .replacingOccurrences(of: "\0", with: "")
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            for prefix in promptPrefixes {
                guard trimmed.hasPrefix(prefix) else { continue }
                let prompt = String(trimmed.dropFirst(prefix.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !prompt.isEmpty && !prompt.allSatisfy({ $0 == "─" || $0 == "-" }) {
                    lastPrompt = String(prompt.prefix(120))
                }
            }
        }
        return lastPrompt
    }

    /// Clean up event monitors. Called when the view is removed from the window.
    private func removeEventMonitors() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
    }

    // MARK: - NSTextInputClient overrides

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)

        let attrString: NSAttributedString
        if let str = string as? NSAttributedString {
            attrString = str
        } else if let str = string as? String {
            attrString = NSAttributedString(string: str)
        } else {
            hideIMEOverlay()
            return
        }

        if attrString.length == 0 {
            hideIMEOverlay()
            return
        }

        _hasMarkedText = true
        currentMarkedText = attrString
        showIMEOverlay(text: attrString)
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        hideIMEOverlay()
        super.insertText(string, replacementRange: replacementRange)
    }

    override func unmarkText() {
        hideIMEOverlay()
    }

    override func hasMarkedText() -> Bool {
        return _hasMarkedText
    }

    override func markedRange() -> NSRange {
        if _hasMarkedText, let text = currentMarkedText {
            return NSRange(location: 0, length: text.length)
        }
        return NSRange(location: NSNotFound, length: 0)
    }

    // MARK: - IME Overlay

    private func showIMEOverlay(text: NSAttributedString) {
        let overlay = getOrCreateOverlay()
        let theme = TerminalTheme.current

        // Keep overlay background in sync with current theme
        overlay.backgroundColor = theme.background.withAlphaComponent(0.95)

        // Style the text with terminal-appropriate appearance
        let styled = NSMutableAttributedString(attributedString: text)
        let fullRange = NSRange(location: 0, length: styled.length)
        let displayFont = self.font ?? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        styled.addAttributes([
            .font: displayFont,
            .foregroundColor: theme.foreground,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .underlineColor: NSColor.systemYellow,
        ], range: fullRange)

        overlay.attributedStringValue = styled

        // Position overlay near the cursor using firstRect (public API)
        let caretRect = firstRect(forCharacterRange: NSRange(location: 0, length: 0), actualRange: nil)

        if caretRect != .zero, let window = self.window {
            // Convert from screen coordinates to view coordinates
            let windowRect = window.convertFromScreen(caretRect)
            let viewPoint = self.convert(windowRect.origin, from: nil)

            let overlaySize = styled.size()
            let overlayHeight = caretRect.height + 4
            // Clamp y so the overlay stays within the view bounds
            let clampedY = max(0, min(viewPoint.y - 2, bounds.height - overlayHeight))
            overlay.frame = NSRect(
                x: viewPoint.x,
                y: clampedY,
                width: max(overlaySize.width + 12, 30),
                height: overlayHeight
            )
        } else {
            // Fallback: position at bottom-left
            overlay.frame = NSRect(x: 10, y: 10, width: styled.size().width + 12, height: 22)
        }

        overlay.isHidden = false
        overlay.needsDisplay = true
    }

    private func hideIMEOverlay() {
        imeOverlay?.isHidden = true
        _hasMarkedText = false
        currentMarkedText = nil
    }

    private func getOrCreateOverlay() -> NSTextField {
        if let existing = imeOverlay {
            return existing
        }

        let tf = NSTextField(labelWithString: "")
        tf.isBezeled = false
        tf.drawsBackground = true
        let bg = TerminalTheme.current.background
        tf.backgroundColor = bg.withAlphaComponent(0.95)
        tf.wantsLayer = true
        tf.layer?.cornerRadius = 3
        tf.isEditable = false
        tf.isSelectable = false
        addSubview(tf)

        imeOverlay = tf
        return tf
    }
}
