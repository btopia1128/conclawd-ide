import SwiftUI
import SwiftTerm

/// A single NSView container that manages showing one terminal view at a time.
/// Terminal views are swapped in/out by sessionId, avoiding SwiftUI NSView re-parenting issues.
class TerminalHostView: NSView {
    private var currentSessionId: UUID?
    /// Track the actual displayed terminal view instance (not looked up from dict).
    /// This ensures we hide the correct view even if the dict entry was replaced (e.g. during resume).
    private weak var currentTerminalView: IMETerminalView?
    private weak var processManager: AgentProcessManager?

    func configure(processManager: AgentProcessManager) {
        self.processManager = processManager
    }

    /// Update the layer background to match the current terminal theme (e.g. on appearance change).
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        layer?.backgroundColor = TerminalTheme.current.background.cgColor
    }

    // MARK: - Drag & Drop (forwarding to active terminal)

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        if superview != nil {
            registerForDraggedTypes([.fileURL])
        }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard currentTerminalView != nil, hasFileURLs(in: sender) else { return [] }
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard currentTerminalView != nil, hasFileURLs(in: sender) else { return [] }
        return .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let terminal = currentTerminalView else { return false }
        return terminal.performDragOperation(sender)
    }

    private func hasFileURLs(in info: NSDraggingInfo) -> Bool {
        guard let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true
        ]) as? [URL] else { return false }
        return !urls.isEmpty
    }

    func showTerminal(for sessionId: UUID?) {
        let terminalView = sessionId.flatMap { processManager?.terminalViews[$0] }

        // Skip if same session AND same view instance (nothing changed)
        if sessionId == currentSessionId,
           terminalView != nil,
           terminalView === currentTerminalView,
           terminalView?.superview === self,
           terminalView?.isHidden == false {
            return
        }

        // Hide the currently displayed terminal view (using tracked reference, not dict lookup).
        // Only touch the view if it's still our subview — when SwiftUI updates two
        // panes in opposite order during a session move, the weak ref can outlive
        // the actual ownership and we'd hide a view now visible in the other pane.
        if let cur = currentTerminalView, cur.superview === self {
            cur.isHidden = true
        }

        currentSessionId = sessionId

        guard let terminalView else {
            currentTerminalView = nil
            return
        }

        // Add to hierarchy if needed
        if terminalView.superview !== self {
            terminalView.removeFromSuperview()
            terminalView.translatesAutoresizingMaskIntoConstraints = false
            addSubview(terminalView)
            let horizontalPadding: CGFloat = 4
            let verticalPadding: CGFloat = 2
            NSLayoutConstraint.activate([
                terminalView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: horizontalPadding),
                terminalView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -horizontalPadding),
                terminalView.topAnchor.constraint(equalTo: topAnchor, constant: verticalPadding),
                terminalView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -verticalPadding),
            ])
        }

        terminalView.isHidden = false
        currentTerminalView = terminalView

        DispatchQueue.main.async {
            // Don't steal focus if a sheet is presented
            guard self.window?.attachedSheet == nil else { return }
            self.window?.makeFirstResponder(terminalView)
        }
    }
}

/// SwiftUI wrapper for the terminal host. Shows the terminal for the selected session.
struct TerminalHostRepresentable: NSViewRepresentable {
    let selectedSessionId: UUID?
    let processManager: AgentProcessManager
    @Environment(\.colorScheme) private var colorScheme

    func makeNSView(context: Context) -> TerminalHostView {
        let host = TerminalHostView()
        host.wantsLayer = true
        host.layer?.backgroundColor = TerminalTheme.current.background.cgColor
        host.configure(processManager: processManager)
        host.showTerminal(for: selectedSessionId)
        return host
    }

    func updateNSView(_ host: TerminalHostView, context: Context) {
        host.layer?.backgroundColor = TerminalTheme.current.background.cgColor
        host.configure(processManager: processManager)
        host.showTerminal(for: selectedSessionId)
    }
}
