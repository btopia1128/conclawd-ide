import SwiftUI
import AppKit

/// Window configuration: transparent titlebar with visual effect hidden,
/// so only the sidebar's ProjectSelectorView provides the visible bar.
struct WindowAccessor: NSViewRepresentable {
    /// Machine-readable window title (read by external tools like time trackers).
    /// The visible titlebar is hidden, so this never appears on screen.
    var title: String

    func makeNSView(context: Context) -> WindowAccessorView {
        WindowAccessorView()
    }

    func updateNSView(_ nsView: WindowAccessorView, context: Context) {
        nsView.applyTitle(title)
    }
}

/// Installs a window-scoped local key monitor for ⌘N / ⌘⇧N so "New File" and
/// "New Folder" work even when the SwiftTerm terminal (an AppKit NSView) holds
/// first-responder status. SwiftUI menu key equivalents don't reliably fire in
/// that case, so the menu commands alone leave the shortcuts dead while the
/// terminal is focused — which is the app's most common state.
struct FileCreationShortcutMonitor: NSViewRepresentable {
    /// Whether a project (or valid target) exists; mirrors the menu's enabled state.
    var canCreate: Bool
    var onNewFile: () -> Void
    var onNewFolder: () -> Void

    func makeNSView(context: Context) -> ShortcutMonitorView {
        let view = ShortcutMonitorView()
        view.canCreate = canCreate
        view.onNewFile = onNewFile
        view.onNewFolder = onNewFolder
        return view
    }

    func updateNSView(_ nsView: ShortcutMonitorView, context: Context) {
        nsView.canCreate = canCreate
        nsView.onNewFile = onNewFile
        nsView.onNewFolder = onNewFolder
    }
}

final class ShortcutMonitorView: NSView {
    var canCreate = false
    var onNewFile: (() -> Void)?
    var onNewFolder: (() -> Void)?

    private var monitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            installMonitor()
        } else {
            removeMonitor()
        }
    }

    private func installMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let window = self.window, event.window === window else { return event }

            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            // Require exactly ⌘ (+ optional ⇧), nothing else, on the "n" key.
            guard flags.contains(.command),
                  !flags.contains(.option),
                  !flags.contains(.control),
                  event.charactersIgnoringModifiers?.lowercased() == "n" else {
                return event
            }
            guard self.canCreate else { return event }

            if flags.contains(.shift) {
                self.onNewFolder?()
            } else {
                self.onNewFile?()
            }
            return nil // consume so it doesn't reach the terminal
        }
    }

    private func removeMonitor() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    deinit {
        removeMonitor()
    }
}

class WindowAccessorView: NSView {
    private var titleLabel: NSTextField?
    private var pendingTitle: String?

    /// Sets the underlying NSWindow.title. Kept separate from the visible label
    /// (which stays branded "Conclawd") so external tools can read the work context.
    func applyTitle(_ title: String) {
        guard !title.isEmpty else { return }
        if let window = self.window {
            if window.title != title { window.title = title }
        } else {
            pendingTitle = title
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window = self.window else { return }

        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.styleMask.insert(.fullSizeContentView)
        window.isMovableByWindowBackground = true
        window.titlebarSeparatorStyle = .none

        if let pendingTitle {
            window.title = pendingTitle
            self.pendingTitle = nil
        }

        DispatchQueue.main.async {
            self.hideTitlebarBackground(in: window)
            self.addTitleLabel(in: window)
        }
    }

    override func layout() {
        super.layout()
        if let window = self.window {
            hideTitlebarBackground(in: window)
            positionTitleLabel(in: window)
        }
    }

    // MARK: - Title Label

    private func addTitleLabel(in window: NSWindow) {
        guard titleLabel == nil,
              let closeButton = window.standardWindowButton(.closeButton),
              let zoomButton = window.standardWindowButton(.zoomButton) else { return }

        let label = NSTextField(labelWithString: "Conclawd")
        label.font = .systemFont(ofSize: 13, weight: .bold)
        label.textColor = .secondaryLabelColor
        label.isEditable = false
        label.isSelectable = false
        label.isBezeled = false
        label.drawsBackground = false
        label.sizeToFit()

        // Add to the same superview as the traffic light buttons
        closeButton.superview?.addSubview(label)
        titleLabel = label

        positionTitleLabel(in: window)
    }

    private func positionTitleLabel(in window: NSWindow) {
        guard let label = titleLabel,
              let zoomButton = window.standardWindowButton(.zoomButton) else { return }

        // Position to the right of the zoom (fullscreen) button
        let gap: CGFloat = 8
        let x = zoomButton.frame.maxX + gap
        let y = zoomButton.frame.midY - label.frame.height / 2
        label.frame.origin = CGPoint(x: x, y: y)
    }

    // MARK: - Titlebar Background

    private func hideTitlebarBackground(in window: NSWindow) {
        guard let contentView = window.contentView,
              let rootView = contentView.superview else { return }

        for child in rootView.subviews where child !== contentView {
            hideVisualEffects(in: child)
        }
    }

    private func hideVisualEffects(in view: NSView) {
        for subview in view.subviews {
            if subview is NSVisualEffectView {
                subview.isHidden = true
            } else if !(subview is NSButton) && subview !== titleLabel {
                hideVisualEffects(in: subview)
            }
        }
    }
}
