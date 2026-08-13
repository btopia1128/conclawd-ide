import SwiftUI
import AppKit

/// Window configuration: transparent titlebar with visual effect hidden,
/// so only the sidebar's ProjectSelectorView provides the visible bar.
struct WindowAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowAccessorView {
        WindowAccessorView()
    }

    func updateNSView(_ nsView: WindowAccessorView, context: Context) {}
}

class WindowAccessorView: NSView {
    private var titleLabel: NSTextField?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window = self.window else { return }

        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.styleMask.insert(.fullSizeContentView)
        window.isMovableByWindowBackground = true
        window.titlebarSeparatorStyle = .none

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
