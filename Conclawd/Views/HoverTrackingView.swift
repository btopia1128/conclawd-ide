import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Hover Tracking

/// An invisible NSView that detects mouse hover without blocking click events.
/// Uses NSTrackingArea for hover detection and returns nil from hitTest to pass through all clicks.
struct HoverTrackingView: NSViewRepresentable {
    var onHoverChanged: (Bool) -> Void

    func makeNSView(context: Context) -> HoverNSView {
        let view = HoverNSView()
        view.onHoverChanged = onHoverChanged
        return view
    }

    func updateNSView(_ nsView: HoverNSView, context: Context) {
        nsView.onHoverChanged = onHoverChanged
    }
}

class HoverNSView: NSView {
    var onHoverChanged: ((Bool) -> Void)?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        onHoverChanged?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHoverChanged?(false)
    }

    /// Pass through all click events to views below.
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

// MARK: - Pointing Hand Cursor

extension View {
    /// Adds a pointing-hand cursor when hovering over this view.
    func pointingHandCursor(_ isActive: Bool = true) -> some View {
        onHover { hovering in
            if isActive {
                if hovering {
                    NSCursor.pointingHand.push()
                } else {
                    NSCursor.pop()
                }
            }
        }
    }

    /// Accepts file URL drops and inserts the file path into the bound text.
    /// Inserts a space separator if the text doesn't end with whitespace.
    func filePathDrop(text: Binding<String>) -> some View {
        onDrop(of: [.fileURL], isTargeted: nil) { providers in
            guard !providers.isEmpty else { return false }
            for provider in providers {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                    guard let data = data as? Data,
                          let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                    DispatchQueue.main.async {
                        let path = url.path(percentEncoded: false)
                        if !text.wrappedValue.isEmpty
                            && !text.wrappedValue.hasSuffix("\n")
                            && !text.wrappedValue.hasSuffix(" ") {
                            text.wrappedValue += " "
                        }
                        text.wrappedValue += path
                    }
                }
            }
            return true
        }
    }
}
