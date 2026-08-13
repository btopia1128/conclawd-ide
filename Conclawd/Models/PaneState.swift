import Foundation

/// Identifies one of the (up to two) main view panes.
enum PaneID: String, Codable, Hashable {
    case primary
    case secondary
}

/// Which view category is shown in a single main pane.
/// (Promoted from AppState.CenterPane to a top-level type so PaneState can own it.)
enum CenterPane: String, CaseIterable {
    case terminal
    case orgChart
    case agentEditor
    case skillEditor
    case scheduleEditor
    case fileEditor
    case settings
}

/// State that one main pane needs to render independently.
///
/// The app supports up to two panes (`primary` / `secondary`). Each pane has its
/// own selected session, file, agent, skill, and centerPane category, plus its
/// own set of "open editor tab" flags.
///
/// Sessions and open files themselves live in the global `AppState.activeSessions`
/// / `openFiles` arrays, but each carries a `paneId` so a pane's tab list can be
/// derived by filtering. This guarantees a session can only belong to one pane
/// at a time (matches the SwiftTerm single-NSView constraint).
struct PaneState {
    let id: PaneID

    var centerPane: CenterPane = .terminal
    var selectedSessionId: UUID?
    var selectedFileId: UUID?

    /// Per-pane Inspector target. The active pane's selection drives the right
    /// inspector panel; the inactive pane keeps its own selection so toggling
    /// focus restores the right context.
    var selectedAgentId: UUID?
    var selectedSkillId: UUID?

    // Editor tab open flags (each pane has its own pinned editors).
    var orgChartTabOpen: Bool = false
    var agentEditorTabOpen: Bool = false
    var agentEditorTabName: String?
    var skillEditorTabOpen: Bool = false
    var skillEditorTabName: String?
    var scheduleEditorTabOpen: Bool = false
    var scheduleEditorTabName: String?
    var settingsTabOpen: Bool = false

    /// URL of the bundled file being viewed inside a skill (sub-tab of skillEditor).
    var viewingBundledFileURL: URL?

    /// The schedule / cloud trigger being edited in this pane's schedule editor tab.
    var editingSchedule: AgentSchedule?
    var editingCloudTrigger: CloudTrigger?

    init(id: PaneID) {
        self.id = id
    }
}
