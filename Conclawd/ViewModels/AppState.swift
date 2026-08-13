import Foundation
import SwiftUI

/// Central application state managing projects, agents, and processes.
@Observable
@MainActor
final class AppState {

    // MARK: - Project Selection

    enum ProjectSelection: Equatable {
        case home              // ユーザーエージェント/スキルのみ
        case project(Project)  // 特定プロジェクト＋ユーザー
        case all               // 全プロジェクト＋ユーザー

        /// The selected project, if any.
        var project: Project? {
            if case .project(let p) = self { return p }
            return nil
        }

        var displayName: String {
            switch self {
            case .home: return "Home"
            case .project(let p): return p.name
            case .all: return "All Projects"
            }
        }

        var iconName: String {
            switch self {
            case .home: return "person.fill"
            case .project: return "folder.fill"
            case .all: return "tray.2.fill"
            }
        }
    }

    // MARK: - Properties

    var projects: [Project] = []
    var projectSelection: ProjectSelection = .home
    var agents: [Agent] = []
    var skills: [Skill] = []

    /// Convenience accessor for the currently selected project (nil unless `.project`).
    var selectedProject: Project? { projectSelection.project }

    // MARK: - Pane State (split-pane main view)

    /// Primary (left) main pane. Always present.
    var primaryPane = PaneState(id: .primary)
    /// Secondary (right) main pane. nil = not split.
    var secondaryPane: PaneState?
    /// Which pane currently has focus. Drives Inspector and "open in editor" routing.
    var activePaneId: PaneID = .primary
    /// Tracks which pane a tab drag originated from (set by `.onDrag`, cleared on drop).
    var draggingTabSourcePane: PaneID?

    /// When `isReloadingAgents` is true, mutations to selectedAgentId skip the
    /// editingAgent sync side effect so in-flight inspector edits aren't
    /// overwritten by stale disk data.
    private var isReloadingAgents = false

    /// Editing state for agents (inspector). Shared across panes (Phase 1).
    var editingAgent: Agent?

    // MARK: - Pane Helpers

    /// Read-only access to a specific pane's state. Falls back to primary if
    /// `.secondary` is requested while the split is closed.
    func pane(_ id: PaneID) -> PaneState {
        switch id {
        case .primary: return primaryPane
        case .secondary: return secondaryPane ?? primaryPane
        }
    }

    /// The currently focused pane (falls back to primary if secondary is nil).
    var activePane: PaneState {
        pane(activePaneId)
    }

    /// Union of session IDs currently **visible on-screen** across all panes.
    /// A session is only considered visible when its pane is showing the terminal
    /// (not Settings, AgentEditor, etc.). This drives read/unread tracking — when
    /// a session leaves this set, new output is flagged as unread.
    var visibleSessionIds: Set<UUID> {
        var ids = Set<UUID>()
        if primaryPane.centerPane == .terminal,
           let sid = primaryPane.selectedSessionId { ids.insert(sid) }
        if let secondary = secondaryPane,
           secondary.centerPane == .terminal,
           let sid = secondary.selectedSessionId { ids.insert(sid) }
        return ids
    }

    /// Returns the pane ID currently owning the given session (nil if not found).
    func paneOwning(sessionId: UUID) -> PaneID? {
        if let session = activeSessions.first(where: { $0.id == sessionId }) {
            return session.paneId
        }
        return nil
    }

    /// Returns the pane ID currently owning the given open file (nil if not found).
    func paneOwning(fileId: UUID) -> PaneID? {
        if let file = openFiles.first(where: { $0.id == fileId }) {
            return file.paneId
        }
        return nil
    }

    /// Apply a mutation to one pane, tracking visibility changes and active-pane
    /// selection side effects. All pane mutations should go through this helper.
    func updatePane(_ id: PaneID, mutate: (inout PaneState) -> Void) {
        let oldVisible = visibleSessionIds
        let oldAgentId: UUID?
        switch id {
        case .primary:
            oldAgentId = primaryPane.selectedAgentId
            mutate(&primaryPane)
        case .secondary:
            guard var pane = secondaryPane else { return }
            oldAgentId = pane.selectedAgentId
            mutate(&pane)
            secondaryPane = pane
        }
        // Only the active pane drives Inspector editingAgent sync.
        if id == activePaneId, !isReloadingAgents {
            let newAgentId = (id == .primary ? primaryPane : (secondaryPane ?? primaryPane)).selectedAgentId
            if oldAgentId != newAgentId {
                handleSelectedAgentChange(newId: newAgentId)
            }
        }
        applyVisibilityChange(old: oldVisible)
    }

    /// Update processManager's viewingSessionIds set and mark newly-gained
    /// sessions as read. Deferred to avoid AttributeGraph cycles.
    private func applyVisibilityChange(old: Set<UUID>) {
        let new = visibleSessionIds
        guard old != new else { return }
        let gained = new.subtracting(old)
        Task { @MainActor [weak self] in
            guard let self else { return }
            for id in gained { self.processManager.markAsRead(sessionId: id) }
            self.processManager.viewingSessionIds = new
        }
    }

    /// Toggle the secondary main pane on/off. When opening, the new pane
    /// inherits primary's centerPane so it doesn't start blank. When closing,
    /// any sessions / files owned by secondary are merged back into primary.
    func toggleSplitView() {
        if secondaryPane == nil {
            openSecondaryPane()
        } else {
            closeSecondaryPane()
        }
    }

    private func openSecondaryPane() {
        var newPane = PaneState(id: .secondary)
        newPane.centerPane = primaryPane.centerPane
        secondaryPane = newPane
        activePaneId = .secondary
        // Refresh viewing set in case pane creation changed visibility.
        let visible = visibleSessionIds
        Task { @MainActor [weak self] in
            self?.processManager.viewingSessionIds = visible
        }
    }

    /// Move a session to the given pane. If the target pane doesn't exist
    /// (e.g. moving to .secondary while not split), the move is a no-op.
    /// The moved session also becomes selected in its new pane.
    func moveSession(sessionId: UUID, toPane targetPane: PaneID) {
        guard let index = activeSessions.firstIndex(where: { $0.id == sessionId }) else { return }
        if targetPane == .secondary, secondaryPane == nil { return }
        let oldPaneId = activeSessions[index].paneId
        guard oldPaneId != targetPane else { return }

        activeSessions[index].paneId = targetPane

        // Pick a fallback selection in the source pane.
        let remainingInSource = activeSessions.filter { $0.paneId == oldPaneId }
        updatePane(oldPaneId) {
            if $0.selectedSessionId == sessionId {
                $0.selectedSessionId = remainingInSource.last?.id
            }
        }

        // Make the moved session the active selection in its new pane.
        updatePane(targetPane) {
            $0.selectedSessionId = sessionId
            $0.centerPane = .terminal
        }
    }

    /// Move an open file editor tab to another pane.
    func moveOpenFile(fileId: UUID, toPane targetPane: PaneID) {
        guard let index = openFiles.firstIndex(where: { $0.id == fileId }) else { return }
        if targetPane == .secondary, secondaryPane == nil { return }
        let oldPaneId = openFiles[index].paneId
        guard oldPaneId != targetPane else { return }

        openFiles[index].paneId = targetPane

        let remainingInSource = openFiles.filter { $0.paneId == oldPaneId }
        updatePane(oldPaneId) {
            if $0.selectedFileId == fileId {
                $0.selectedFileId = remainingInSource.last?.id
                if remainingInSource.isEmpty && $0.centerPane == .fileEditor {
                    $0.centerPane = .terminal
                }
            }
        }

        updatePane(targetPane) {
            $0.selectedFileId = fileId
            $0.centerPane = .fileEditor
        }
    }

    private func closeSecondaryPane() {
        // Merge secondary's sessions and files back into primary by relabeling.
        for i in activeSessions.indices where activeSessions[i].paneId == .secondary {
            activeSessions[i].paneId = .primary
        }
        for i in openFiles.indices where openFiles[i].paneId == .secondary {
            openFiles[i].paneId = .primary
        }
        secondaryPane = nil
        activePaneId = .primary
        let visible = visibleSessionIds
        Task { @MainActor [weak self] in
            self?.processManager.viewingSessionIds = visible
        }
    }

    /// Sync editingAgent to the newly-selected agent on the active pane.
    private func handleSelectedAgentChange(newId: UUID?) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.autoSaveAgentIfNeeded()
            if let id = newId, let agent = self.agents.first(where: { $0.id == id }) {
                if self.editingAgent?.id != id {
                    self.editingAgent = agent
                }
            } else if newId == nil, self.editingAgent != nil {
                self.editingAgent = nil
            }
        }
    }

    // MARK: - Pane Forwarding Accessors
    // These route reads/writes to the currently active pane. AppState methods
    // that mutate "current selection" / "current center pane" automatically
    // target whichever pane has focus, without needing explicit paneId args.
    // Use `primaryPane` / `secondaryPane` directly if you must bypass the
    // active-pane indirection (e.g. cross-pane cleanup).

    /// Selected session (for terminal tab display). Forwards to primary pane.
    var selectedSessionId: UUID? {
        get { activePane.selectedSessionId }
        set { updatePane(activePaneId) { $0.selectedSessionId = newValue } }
    }

    /// ID of the currently selected open file.
    var selectedFileId: UUID? {
        get { activePane.selectedFileId }
        set { updatePane(activePaneId) { $0.selectedFileId = newValue } }
    }

    /// ID of the currently selected agent in the active pane's inspector.
    var selectedAgentId: UUID? {
        get { activePane.selectedAgentId }
        set { updatePane(activePaneId) { $0.selectedAgentId = newValue } }
    }

    /// ID of the currently selected skill in the active pane's inspector.
    var selectedSkillId: UUID? {
        get { activePane.selectedSkillId }
        set { updatePane(activePaneId) { $0.selectedSkillId = newValue } }
    }

    /// Which view is shown in the center pane.
    var centerPane: CenterPane {
        get { activePane.centerPane }
        set { updatePane(activePaneId) { $0.centerPane = newValue } }
    }

    /// Whether the settings tab is pinned open.
    var settingsTabOpen: Bool {
        get { activePane.settingsTabOpen }
        set { updatePane(activePaneId) { $0.settingsTabOpen = newValue } }
    }

    /// Whether the org chart tab is open.
    var orgChartTabOpen: Bool {
        get { activePane.orgChartTabOpen }
        set { updatePane(activePaneId) { $0.orgChartTabOpen = newValue } }
    }

    /// Whether the agent editor tab is pinned open.
    var agentEditorTabOpen: Bool {
        get { activePane.agentEditorTabOpen }
        set { updatePane(activePaneId) { $0.agentEditorTabOpen = newValue } }
    }

    /// The agent name shown in the pinned agent editor tab.
    var agentEditorTabName: String? {
        get { activePane.agentEditorTabName }
        set { updatePane(activePaneId) { $0.agentEditorTabName = newValue } }
    }

    /// Whether the skill editor tab is pinned open.
    var skillEditorTabOpen: Bool {
        get { activePane.skillEditorTabOpen }
        set { updatePane(activePaneId) { $0.skillEditorTabOpen = newValue } }
    }

    /// The skill name shown in the pinned skill editor tab.
    var skillEditorTabName: String? {
        get { activePane.skillEditorTabName }
        set { updatePane(activePaneId) { $0.skillEditorTabName = newValue } }
    }

    /// Whether the schedule editor tab is pinned open.
    var scheduleEditorTabOpen: Bool {
        get { activePane.scheduleEditorTabOpen }
        set { updatePane(activePaneId) { $0.scheduleEditorTabOpen = newValue } }
    }

    /// The schedule name shown in the pinned schedule editor tab.
    var scheduleEditorTabName: String? {
        get { activePane.scheduleEditorTabName }
        set { updatePane(activePaneId) { $0.scheduleEditorTabName = newValue } }
    }

    /// The schedule being edited in the schedule editor tab.
    var editingSchedule: AgentSchedule? {
        get { activePane.editingSchedule }
        set { updatePane(activePaneId) { $0.editingSchedule = newValue } }
    }

    /// The cloud trigger being edited in the schedule editor tab.
    var editingCloudTrigger: CloudTrigger? {
        get { activePane.editingCloudTrigger }
        set { updatePane(activePaneId) { $0.editingCloudTrigger = newValue } }
    }

    /// URL of the bundled file being viewed in the center pane (within a skill).
    var viewingBundledFileURL: URL? {
        get { activePane.viewingBundledFileURL }
        set { updatePane(activePaneId) { $0.viewingBundledFileURL = newValue } }
    }

    /// Whether the editing agent differs from the saved version (computed, not stored).
    var agentHasChanges: Bool {
        guard let editing = editingAgent,
              let original = agents.first(where: { $0.id == editing.id }) else { return false }
        return !editing.contentEquals(original)
    }

    /// Editing state for skills (shared between center editor and inspector).
    var editingSkill: Skill?

    /// Whether the editing skill differs from the saved version (computed, not stored).
    var skillHasChanges: Bool {
        guard let editing = editingSkill,
              let original = skills.first(where: { $0.id == editing.id }) else { return false }
        return !editing.contentEquals(original)
    }

    /// All active terminal sessions (one agent can have multiple).
    var activeSessions: [AgentSession] = []

    /// Active AI-assisted agent creation session.
    var creationSession: CreationSession?

    /// Whether tab auto-sort by category is enabled.
    var isTabSortEnabled = false

    /// Active sessions sorted by category when auto-sort is enabled.
    /// Order: agent sessions → shell sessions (preserving relative order within each group).
    var sortedActiveSessions: [AgentSession] {
        guard isTabSortEnabled else { return activeSessions }
        let agents = activeSessions.filter { !$0.isShellSession && !$0.isCreationSession }
        let shells = activeSessions.filter { $0.isShellSession }
        let creations = activeSessions.filter { $0.isCreationSession }
        return agents + shells + creations
    }

    /// Which tab is shown in the sidebar.
    var sidebarTab: SidebarTab = .sessions

    enum SidebarTab: String, CaseIterable {
        case sessions = "Sessions"
        case agents = "Agents"
        case skills = "Skills"
        case schedules = "Schedules"
        case files = "Files"
        case shells = "Shells"

        var icon: String {
            switch self {
            case .agents: return "person.2"
            case .sessions: return "bubble.left.and.bubble.right"
            case .skills: return "book.closed"
            case .schedules: return "clock"
            case .files: return "folder"
            case .shells: return "apple.terminal"
            }
        }
    }

    // MARK: - File Browser

    /// File tree roots for the current project.
    var fileTreeRoots: [FileNode] = []
    let fileTreeService = FileTreeService()
    private var loadFileTreeWorkItem: DispatchWorkItem?

    /// Files currently open in file editor tabs.
    var openFiles: [OpenFile] = []
    /// Whether any file editor tab is open.
    var fileEditorTabOpen: Bool { !openFiles.isEmpty }

    /// State for the external file change conflict dialog.
    var fileConflictFileId: UUID?

    /// State for the file/folder creation alert.
    var showingFileCreationAlert = false
    var fileCreationIsDirectory = false
    var fileCreationParentNode: FileNode?
    var fileCreationName = ""

    /// Raw markdown content being edited in the center-pane agent editor.
    var editingAgentContent: String?
    var agentEditorHasChanges: Bool = false

    /// Error message to show to the user.
    var errorMessage: String?

    /// Toast message to show briefly.
    var toastMessage: String?

    /// Session IDs currently undergoing memory extraction.
    var memoryExtractingSessions: Set<UUID> = []

    /// Parse errors from the most recent agent file scan.
    var agentParseErrors: [AgentParseError] = []

    /// Warnings about agent relations (cross-project, broken references, etc.).
    var relationWarnings: [RelationWarning] = []

    /// Preferred external editor bundle identifier (nil = system default).
    var preferredEditorBundleId: String? {
        didSet { UserDefaults.standard.set(preferredEditorBundleId, forKey: "preferredEditorBundleId") }
    }

    /// Whether to show line numbers in the file editor.
    var editorShowLineNumbers: Bool = true {
        didSet { UserDefaults.standard.set(editorShowLineNumbers, forKey: "editorShowLineNumbers") }
    }

    /// Whether to enable word wrap in the file editor.
    var editorWordWrap: Bool = false {
        didSet { UserDefaults.standard.set(editorWordWrap, forKey: "editorWordWrap") }
    }

    /// Shell presets for the current project.
    var shellPresets: [ShellPreset] = []

    /// Session presets (saved standalone Claude configurations).
    var sessionPresets: [SessionPreset] = []

    let processManager = AgentProcessManager()
    let configService = AgentConfigService()
    let skillConfigService = SkillConfigService()
    let relationService: AgentRelationService
    let fileWatcher = FileWatcherService()
    let openFileWatcher = OpenFileWatcherService()
    let memoryService = AgentMemoryService()
    let memoryDatabaseManager = MemoryDatabaseManager()
    let memoryExtractor: MemoryExtractor
    let scheduleManager = ScheduleManager()
    let cloudTriggerService: CloudTriggerService
    let sessionHistoryService = SessionHistoryService()
    let skillUsageService = SkillUsageService()
    let codexSyncService: CodexSyncService
    let gitService = GitService()
    let shellPresetService = ShellPresetService()
    let sessionPresetService = SessionPresetService()

    // MARK: - Git State

    /// Current git repository status (nil if not a git repo or Home mode).
    var gitStatus: GitStatus?
    /// Cached list of branches for the current project.
    var gitBranches: [GitBranch] = []
    /// Whether the current project directory is a git repository.
    var isGitRepository: Bool = false
    /// Changed files for the commit popover.
    var gitChangedFiles: [GitChangedFile] = []
    /// Whether a git operation (commit/push/pull) is in progress.
    var isGitOperationInProgress: Bool = false
    /// Last git operation error message (persists until next successful operation or manual dismiss).
    var lastGitError: String?
    /// Watches .git/HEAD for external branch changes.
    private let gitHeadWatcher = FileWatcherService(debounceInterval: 0.3)

    /// Chat session managers keyed by session ID (for chat-mode sessions).
    var chatManagers: [UUID: ChatSessionManager] = [:]

    /// Polling timer for detecting new skills during AI creation sessions.
    private var skillCreationPollTimer: Timer?

    // MARK: - Init

    init() {
        self.preferredEditorBundleId = UserDefaults.standard.string(forKey: "preferredEditorBundleId")
        if UserDefaults.standard.object(forKey: "editorShowLineNumbers") != nil {
            self.editorShowLineNumbers = UserDefaults.standard.bool(forKey: "editorShowLineNumbers")
        }
        if UserDefaults.standard.object(forKey: "editorWordWrap") != nil {
            self.editorWordWrap = UserDefaults.standard.bool(forKey: "editorWordWrap")
        }
        self.relationService = AgentRelationService(configService: configService)
        self.memoryService.databaseManager = memoryDatabaseManager
        self.memoryExtractor = MemoryExtractor(
            memoryService: memoryService,
            claudePathResolver: processManager.claudePathResolver,
            databaseManager: memoryDatabaseManager
        )
        self.cloudTriggerService = CloudTriggerService(
            claudePathResolver: processManager.claudePathResolver
        )
        self.codexSyncService = CodexSyncService(skillConfigService: skillConfigService)
        loadRecentProjects()

        // Set up memory extraction on session termination
        setupMemoryExtraction()

        // Load session history
        sessionHistoryService.load()

        // Apply initial project from settings (defaults to Home)
        applyInitialProjectSelection()

        reloadAgents()
        reloadSkills()
        syncMemoriesToDatabase()
        reloadShellPresets()
        reloadSessionPresets()
        loadFileTree()
        setupFileWatcher()
        setupOpenFileWatcher()
        setupScheduleManager()
        refreshGitStatus()
        setupGitHeadWatcher()

        // Process memory extraction for sessions that were interrupted by app quit
        processPendingMemoryExtractions()
    }

    // MARK: - Computed

    var selectedAgent: Agent? {
        agents.first { $0.id == selectedAgentId }
    }

    var projectAgents: [Agent] {
        agents.filter { $0.scope == .project }
    }

    var userAgents: [Agent] {
        agents.filter { $0.scope == .user }
    }

    /// Project agents grouped by source project name (for All mode sidebar).
    var agentsByProject: [(projectName: String, agents: [Agent])] {
        var grouped: [String: [Agent]] = [:]
        for agent in agents where agent.scope == .project {
            let key = agent.sourceProjectName ?? "Unknown"
            grouped[key, default: []].append(agent)
        }
        // Sort by project order in recent projects list
        let projectOrder = Dictionary(uniqueKeysWithValues: projects.enumerated().map { ($1.name, $0) })
        return grouped.sorted { (projectOrder[$0.key] ?? Int.max) < (projectOrder[$1.key] ?? Int.max) }
            .map { (projectName: $0.key, agents: $0.value) }
    }

    var selectedSkill: Skill? {
        skills.first { $0.id == selectedSkillId }
    }

    var projectSkills: [Skill] {
        skills.filter { $0.scope == .project }
    }

    var userSkills: [Skill] {
        skills.filter { $0.scope == .user }
    }

    var skillsByProject: [(projectName: String, skills: [Skill])] {
        var grouped: [String: [Skill]] = [:]
        for skill in skills where skill.scope == .project {
            let key = skill.sourceProjectName ?? "Unknown"
            grouped[key, default: []].append(skill)
        }
        let projectOrder = Dictionary(uniqueKeysWithValues: projects.enumerated().map { ($1.name, $0) })
        return grouped.sorted { (projectOrder[$0.key] ?? Int.max) < (projectOrder[$1.key] ?? Int.max) }
            .map { (projectName: $0.key, skills: $0.value) }
    }

    /// Determines what the inspector should show.
    enum InspectorTarget {
        case agent
        case skill
        case none
    }

    var inspectorTarget: InspectorTarget {
        if selectedSkillId != nil { return .skill }
        if selectedAgentId != nil { return .agent }
        return .none
    }

    var relations: [AgentRelation] {
        relationService.extractRelations(agents: agents)
    }

    var hasProject: Bool {
        if case .project = projectSelection { return true }
        return false
    }

    /// The project root URL for the current selection.
    var currentProjectRoot: URL? {
        switch projectSelection {
        case .home, .all: return nil
        case .project(let project): return project.directoryPath
        }
    }

    /// The project path for the current selection (used for history filtering).
    var currentProjectPath: String? {
        switch projectSelection {
        case .home:
            return nil  // home agents have nil projectPath
        case .project(let project):
            return project.directoryPath.path(percentEncoded: false)
        case .all:
            return nil  // show all in .all mode (handled differently in UI)
        }
    }

    // MARK: - Session Queries

    /// Number of active sessions for a given agent.
    func sessionCount(agentId: UUID) -> Int {
        activeSessions.filter { $0.agentId == agentId }.count
    }

    /// Aggregate status across all sessions for an agent (most active wins).
    func bestStatus(agentId: UUID) -> AgentProcessStatus {
        let sessions = activeSessions.filter { $0.agentId == agentId }
        guard !sessions.isEmpty else { return .stopped(exitCode: nil) }
        let statuses = sessions.map { session -> AgentProcessStatus in
            if session.displayMode == .chat {
                return chatManagers[session.id]?.isProcessing == true ? .running : .waitingForInput
            }
            return processManager.status(sessionId: session.id)
        }
        if statuses.contains(.running) { return .running }
        if statuses.contains(.waitingForInput) { return .waitingForInput }
        return .stopped(exitCode: nil)
    }

    /// Whether the agent has any active (running or waiting) sessions.
    func hasActiveSession(agentId: UUID) -> Bool {
        activeSessions.contains { session in
            session.agentId == agentId && processManager.isRunning(sessionId: session.id)
        }
    }

    // MARK: - Project Management

    func loadProject(_ project: Project) {
        if creationSession != nil {
            endCreationSession()
        }

        fileWatcher.stopAll()

        projectSelection = .project(project)

        projects.removeAll { $0.directoryPath == project.directoryPath }
        var updated = project
        updated.lastOpenedAt = Date()
        projects.insert(updated, at: 0)

        if projects.count > 10 {
            projects = Array(projects.prefix(10))
        }
        saveRecentProjects()

        reloadAgents()
        reloadSkills()
        syncMemoriesToDatabase()
        loadFileTree()
        setupFileWatcher()
        refreshGitStatus()
        setupGitHeadWatcher()
        reloadShellPresets()
        reloadSessionPresets()
    }

    func openProject(directory: URL) {
        let name = directory.lastPathComponent
        let project = Project(name: name, directoryPath: directory)
        loadProject(project)
    }

    func selectAll() {
        guard projectSelection != .all else { return }

        fileWatcher.stopAll()
        projectSelection = .all

        reloadAgents()
        reloadSkills()
        syncMemoriesToDatabase()
        loadFileTree()
        setupFileWatcher()
        refreshGitStatus()
        setupGitHeadWatcher()
        reloadShellPresets()
        reloadSessionPresets()
    }

    func selectHome() {
        guard projectSelection != .home else { return }

        fileWatcher.stopAll()
        projectSelection = .home

        reloadAgents()
        reloadSkills()
        syncMemoriesToDatabase()
        loadFileTree()
        setupFileWatcher()
        refreshGitStatus()
        setupGitHeadWatcher()
        reloadShellPresets()
        reloadSessionPresets()
    }

    /// Key used to persist the initial project selection in UserDefaults.
    static let initialProjectKey = "initialProjectSelection"

    /// UserDefaults keys for background-task provider selection.
    /// Values: "claude" (default) or "codex".
    static let memoryExtractionProviderKey = "memoryExtractionProvider"
    static let commitMessageProviderKey = "commitMessageProvider"

    /// Reads the configured provider for memory extraction (default: claude).
    private func memoryExtractionProvider() -> CLIProviderType {
        let raw = UserDefaults.standard.string(forKey: Self.memoryExtractionProviderKey) ?? "claude"
        return raw == "codex" ? .codex : .claude
    }

    /// Reads the configured provider for commit message generation (default: claude).
    private func commitMessageProvider() -> CLIProviderType {
        let raw = UserDefaults.standard.string(forKey: Self.commitMessageProviderKey) ?? "claude"
        return raw == "codex" ? .codex : .claude
    }

    /// Reads UserDefaults and sets `projectSelection` before first reload.
    private func applyInitialProjectSelection() {
        let raw = UserDefaults.standard.string(forKey: Self.initialProjectKey) ?? "all"
        switch raw {
        case "home":
            projectSelection = .home
        case "all":
            projectSelection = .all
        default:
            // Treat as a directory path – find matching recent project
            if let project = projects.first(where: { $0.directoryPath.path(percentEncoded: false) == raw }) {
                projectSelection = .project(project)
            } else {
                projectSelection = .all
            }
        }
    }

    // MARK: - Agent Management

    func reloadAgents() {
        // Preserve selection by filePath (stable across reloads, unlike UUID)
        let selectedFilePath = agents.first { $0.id == selectedAgentId }?.filePath?.path(percentEncoded: false)
        let previousAgentFilePaths = Set(agents.compactMap { $0.filePath?.path(percentEncoded: false) })

        var loaded: [Agent] = []
        var allErrors: [AgentParseError] = []

        switch projectSelection {
        case .home:
            // Home mode: user agents only — no project agents loaded
            break

        case .project(let project):
            // Single project mode
            let fm = FileManager.default
            guard fm.fileExists(atPath: project.directoryPath.path(percentEncoded: false)) else {
                // Project directory no longer exists — skip loading
                agents = []
                agentParseErrors = []
                return
            }
            let result = configService.loadProjectAgentsWithErrors(projectDir: project.directoryPath)
            var projectAgents = result.agents
            for i in projectAgents.indices {
                projectAgents[i].sourceProjectName = project.name
            }
            loaded.append(contentsOf: projectAgents)
            allErrors.append(contentsOf: result.errors)

        case .all:
            // All mode: load from all recent projects
            let fm = FileManager.default
            for project in projects {
                guard fm.fileExists(atPath: project.directoryPath.path(percentEncoded: false)) else { continue }
                let result = configService.loadProjectAgentsWithErrors(projectDir: project.directoryPath)
                var projectAgents = result.agents
                for i in projectAgents.indices {
                    projectAgents[i].sourceProjectName = project.name
                }
                loaded.append(contentsOf: projectAgents)
                allErrors.append(contentsOf: result.errors)
            }
        }

        // Load user agents (coexist with project agents even if names overlap)
        let userResult = configService.loadUserAgentsWithErrors()
        loaded.append(contentsOf: userResult.agents)
        allErrors.append(contentsOf: userResult.errors)
        agentParseErrors = allErrors
        relationWarnings = relationService.findAllWarnings(agents: loaded)

        // Build filePath → new ID mapping to update active sessions
        let newIdByFilePath = Dictionary(uniqueKeysWithValues: loaded.compactMap { agent -> (String, UUID)? in
            guard let path = agent.filePath?.path(percentEncoded: false) else { return nil }
            return (path, agent.id)
        })

        // Update active sessions to reference new agent IDs
        for i in activeSessions.indices {
            let session = activeSessions[i]
            guard !session.isCreationSession, !session.isShellSession else { continue }
            if let filePath = session.agentFilePath,
               let newId = newIdByFilePath[filePath], newId != session.agentId {
                activeSessions[i] = AgentSession(
                    id: session.id,
                    agentId: newId,
                    agentName: session.agentName,
                    customName: session.customName,
                    agentFilePath: session.agentFilePath,
                    isCreationSession: session.isCreationSession,
                    isScheduledSession: session.isScheduledSession,
                    scheduleId: session.scheduleId,
                    workingDirectory: session.workingDirectory,
                    displayMode: session.displayMode,
                    startedAt: session.startedAt,
                    paneId: session.paneId
                )
            }
        }

        // Apply local directory overrides from UserDefaults
        let localDirs = UserDefaults.standard.dictionary(forKey: "agentLocalDirectories") as? [String: String] ?? [:]
        for i in loaded.indices {
            if let filePath = loaded[i].filePath?.path(percentEncoded: false),
               let dirPath = localDirs[filePath] {
                loaded[i].localDirectory = URL(filePath: dirPath)
            }
        }

        agents = loaded.sorted { $0.sortOrder == $1.sortOrder ? $0.name < $1.name : $0.sortOrder < $1.sortOrder }

        // Detect new agents created during AI creation session
        if let session = creationSession, !session.isSkillCreation {
            let currentAgentFilePaths = Set(agents.compactMap { $0.filePath?.path(percentEncoded: false) })
            let addedPaths = currentAgentFilePaths.subtracting(previousAgentFilePaths)

            if let newPath = addedPaths.first,
               let newAgent = agents.first(where: { $0.filePath?.path(percentEncoded: false) == newPath }) {
                // End the creation session and show the new agent in the editor
                endCreationSession()
                toastMessage = "Agent \"\(newAgent.name)\" created"
                sidebarTab = .agents
                showAgentEditor(newAgent)
                return
            }
        }

        // Restore selection — preserve in-flight inspector edits during reload
        if let path = selectedFilePath {
            let newId = agents.first { $0.filePath?.path(percentEncoded: false) == path }?.id
            let hadChanges = agentHasChanges
            let savedEditing = editingAgent
            isReloadingAgents = true
            selectedAgentId = newId
            isReloadingAgents = false
            if hadChanges, var editing = savedEditing, let newId {
                // Keep in-flight edits, just update the id to match reloaded agent
                editing.id = newId
                editingAgent = editing
            } else if let id = newId, let agent = agents.first(where: { $0.id == id }) {
                editingAgent = agent
            }
        }

    }

    /// Sync agent memories to SQLite in the background.
    /// Groups agents by their own projectRootDirectory so that Home/All mode also syncs correctly.
    /// Call only on project load — not from file-watcher reloadAgents() to avoid loops.
    private func syncMemoriesToDatabase() {
        let agentsSnapshot = agents
        Task.detached(priority: .utility) { [memoryDatabaseManager, memoryService] in
            // Separate user-scope agents (→ global DB) from project agents (→ project DB)
            // Note: user-scope agents under ~/.claude/agents/ have projectRootDirectory = ~/
            // which is non-nil, so we must check scope explicitly instead of relying on nil grouping.
            let userAgents = agentsSnapshot.filter { $0.scope == .user }
            let projectAgents = agentsSnapshot.filter { $0.scope != .user }

            // User-scope agents: sync to global DB
            if !userAgents.isEmpty, let db = memoryDatabaseManager.globalDatabase() {
                for agent in userAgents where agent.memoryEnabled {
                    let memories = memoryService.loadMemories(for: agent)
                    let baseName = agent.filePath?.deletingPathExtension().lastPathComponent ?? agent.name
                    let agentName = "~user/\(baseName)"
                    memoryDatabaseManager.syncMemories(memories, agentName: agentName, ownership: .agent, database: db)
                }
                memoryDatabaseManager.generateGlobalEmbeddingsInBackground()
            }

            // Project agents: group by project root
            let grouped = Dictionary(grouping: projectAgents) { $0.projectRootDirectory }
            for (projectRoot, agents) in grouped {
                guard let projectRoot else { continue }
                memoryDatabaseManager.startupSync(
                    agents: agents,
                    memoryService: memoryService,
                    projectRoot: projectRoot
                )
                memoryDatabaseManager.generateEmbeddingsInBackground(for: projectRoot)
            }
        }
    }

    func selectAgent(_ agent: Agent) {
        autoSaveAgentIfNeeded()
        autoSaveSkillIfNeeded()
        selectedAgentId = agent.id
        selectedSkillId = nil
        editingAgent = agent
        // Stay on agent editor / org chart if already showing it, otherwise go to terminal
        if centerPane != .agentEditor && centerPane != .orgChart {
            centerPane = .terminal
        }
    }

    /// Selects a session from the sidebar, switching to the session's owning pane.
    func selectSession(_ sessionId: UUID) {
        guard let session = activeSessions.first(where: { $0.id == sessionId }) else { return }
        let targetPane = session.paneId
        activePaneId = targetPane
        updatePane(targetPane) {
            $0.selectedSessionId = sessionId
            $0.centerPane = .terminal
        }
        if !session.isCreationSession {
            let agent = agents.first(where: { $0.id == session.agentId })
                ?? agents.first(where: {
                    session.agentFilePath != nil && $0.filePath?.path(percentEncoded: false) == session.agentFilePath
                })
            if let agent {
                updatePane(targetPane) { $0.selectedAgentId = agent.id }
                autoSaveAgentIfNeeded()
                editingAgent = agent
            } else {
                updatePane(targetPane) { $0.selectedAgentId = nil }
            }
        }
    }

    func selectSkill(_ skill: Skill) {
        autoSaveAgentIfNeeded()
        autoSaveSkillIfNeeded()
        selectedAgentId = nil
        selectedSkillId = skill.id
        editingSkill = skill
        skillEditorTabOpen = true
        skillEditorTabName = skill.name
        viewingBundledFileURL = nil
        centerPane = .skillEditor
    }

    /// Auto-saves the current editing agent if there are unsaved changes.
    private func autoSaveAgentIfNeeded() {
        guard agentHasChanges, let agent = editingAgent else { return }
        saveAgent(agent)
    }

    func saveEditingAgent() {
        guard let agent = editingAgent else { return }
        saveAgent(agent)
    }

    func revertEditingAgent() {
        editingAgent = selectedAgent
    }

    /// Auto-saves the current editing skill if there are unsaved changes.
    private func autoSaveSkillIfNeeded() {
        guard skillHasChanges, let skill = editingSkill else { return }
        saveSkill(skill)
    }

    func saveEditingSkill() {
        guard let skill = editingSkill else { return }
        saveSkill(skill)
    }

    func revertEditingSkill() {
        editingSkill = selectedSkill
    }

    func createAgent(name: String, description: String, model: AgentModel, scope: AgentScope, projectDirectory: URL? = nil, localDirectory: URL? = nil, customFlags: String? = nil, defaultProvider: CLIProviderType = .claude, rawCommand: String? = nil) {
        let targetDir: URL
        let fm = FileManager.default
        var projectBaseDir: URL?

        switch scope {
        case .project:
            let baseDir: URL
            if let projectDir = projectDirectory {
                baseDir = projectDir
            } else if let project = selectedProject {
                baseDir = project.directoryPath
            } else {
                errorMessage = "No project directory specified."
                return
            }

            // Verify the project directory actually exists on disk
            guard fm.fileExists(atPath: baseDir.path(percentEncoded: false)) else {
                errorMessage = "Project directory does not exist: \(baseDir.path(percentEncoded: false))"
                return
            }

            targetDir = baseDir.appending(path: ".claude/agents")
            projectBaseDir = baseDir

            // Ensure the target project is registered so reloadAgents can find the new agent
            if !projects.contains(where: { $0.directoryPath == baseDir }) {
                let project = Project(name: baseDir.lastPathComponent, directoryPath: baseDir)
                projects.insert(project, at: 0)
                if projects.count > 10 {
                    projects = Array(projects.prefix(10))
                }
                saveRecentProjects()
            }
        case .user:
            targetDir = fm.homeDirectoryForCurrentUser.appending(path: ".claude/agents")
        case .cloud:
            return
        }

        var agent = Agent()
        agent.name = name
        agent.description = description
        agent.model = model
        agent.scope = scope
        agent.memoryEnabled = true
        agent.memoryStorage = scope == .user ? .private : .shared
        agent.filePath = targetDir.appending(path: "\(name).md")
        agent.localDirectory = localDirectory
        if let customFlags, !customFlags.isEmpty {
            agent.customFlags = customFlags
        }
        agent.defaultProvider = defaultProvider
        agent.rawCommand = rawCommand

        do {
            try configService.saveAgent(agent, to: targetDir)
            saveLocalDirectory(for: agent)

            // If the agent was created for a different project than the current selection,
            // switch to that project so it appears in the sidebar (skip for .all mode).
            if scope == .project,
               let baseDir = projectBaseDir,
               selectedProject?.directoryPath != baseDir,
               case .all = projectSelection {
                // .all mode: just reload, the new agent will appear
                reloadAgents()
            } else if scope == .project,
                      let baseDir = projectBaseDir,
                      selectedProject?.directoryPath != baseDir,
                      let targetProject = projects.first(where: { $0.directoryPath == baseDir }) {
                // Home or different project: switch to the target project
                loadProject(targetProject)
            } else {
                reloadAgents()
            }

            let expectedPath = targetDir.appending(path: "\(name).md").path(percentEncoded: false)
            if let created = agents.first(where: { $0.filePath?.path(percentEncoded: false) == expectedPath }) {
                showAgentEditor(created)
            }
        } catch {
            errorMessage = "Failed to create agent: \(error.localizedDescription)"
        }
    }

    func duplicateAgent(_ agent: Agent, to destination: URL? = nil) {
        var copy = agent
        copy.id = UUID()

        var newName = "\(agent.name)-copy"
        var counter = 2
        while agents.contains(where: { $0.name == newName && $0.scope == agent.scope && $0.sourceProjectName == agent.sourceProjectName }) {
            newName = "\(agent.name)-copy-\(counter)"
            counter += 1
        }
        copy.name = newName

        let targetDir: URL
        if let destination {
            targetDir = destination
        } else if agent.scope == .project, let projectDir = selectedProject?.agentsDirectory {
            targetDir = projectDir
        } else {
            targetDir = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude/agents")
        }
        copy.filePath = targetDir.appending(path: "\(newName).md")

        do {
            try configService.saveAgent(copy, to: targetDir)
            reloadAgents()
            let expectedPath = copy.filePath?.path(percentEncoded: false)
            if let newAgent = agents.first(where: { $0.filePath?.path(percentEncoded: false) == expectedPath }) {
                selectAgent(newAgent)
            }
        } catch {
            errorMessage = "Failed to duplicate agent: \(error.localizedDescription)"
        }
    }

    func deleteAgent(_ agent: Agent) {
        // Close all sessions for this agent
        closeAllSessions(agentId: agent.id)

        // Delete file
        if let filePath = agent.filePath {
            try? FileManager.default.removeItem(at: filePath)
        }

        // Remove from list
        agents.removeAll { $0.id == agent.id }

        if selectedAgentId == agent.id {
            selectedAgentId = agents.first?.id
        }
    }

    // MARK: - Reorder (Drag & Drop)

    /// Move an agent from one position to another within the agents array and persist sortOrder.
    func moveAgent(fromId: UUID, toId: UUID) {
        guard let fromIndex = agents.firstIndex(where: { $0.id == fromId }),
              let toIndex = agents.firstIndex(where: { $0.id == toId }),
              fromIndex != toIndex else { return }
        let item = agents.remove(at: fromIndex)
        let insertAt = agents.firstIndex(where: { $0.id == toId }) ?? agents.endIndex
        agents.insert(item, at: insertAt)
        saveAgentSortOrders()
    }

    /// Move a skill from one position to another within the skills array and persist sortOrder.
    func moveSkill(fromId: UUID, toId: UUID) {
        guard let fromIndex = skills.firstIndex(where: { $0.id == fromId }),
              let toIndex = skills.firstIndex(where: { $0.id == toId }),
              fromIndex != toIndex else { return }
        let item = skills.remove(at: fromIndex)
        let insertAt = skills.firstIndex(where: { $0.id == toId }) ?? skills.endIndex
        skills.insert(item, at: insertAt)
        saveSkillSortOrders()
    }

    /// Move a shell preset from one position to another and persist.
    func moveShellPreset(fromId: UUID, toId: UUID) {
        guard let fromIndex = shellPresets.firstIndex(where: { $0.id == fromId }),
              let toIndex = shellPresets.firstIndex(where: { $0.id == toId }),
              fromIndex != toIndex else { return }
        let item = shellPresets.remove(at: fromIndex)
        let insertAt = shellPresets.firstIndex(where: { $0.id == toId }) ?? shellPresets.endIndex
        shellPresets.insert(item, at: insertAt)
        shellPresetService.savePresets(shellPresets)
    }

    /// Update sortOrder for all agents of the same scope and save to disk.
    private func saveAgentSortOrders() {
        // Renumber project agents
        let projectIds = agents.enumerated().filter { $0.element.scope == .project }.map { $0.offset }
        for (order, idx) in projectIds.enumerated() {
            agents[idx].sortOrder = order
            try? configService.saveAgent(agents[idx])
        }
        // Renumber user agents
        let userIds = agents.enumerated().filter { $0.element.scope == .user }.map { $0.offset }
        for (order, idx) in userIds.enumerated() {
            agents[idx].sortOrder = order
            try? configService.saveAgent(agents[idx])
        }
    }

    /// Update sortOrder for all skills of the same scope and save to disk.
    private func saveSkillSortOrders() {
        let projectIds = skills.enumerated().filter { $0.element.scope == .project }.map { $0.offset }
        for (order, idx) in projectIds.enumerated() {
            skills[idx].sortOrder = order
            try? skillConfigService.saveSkill(skills[idx])
        }
        let userIds = skills.enumerated().filter { $0.element.scope == .user }.map { $0.offset }
        for (order, idx) in userIds.enumerated() {
            skills[idx].sortOrder = order
            try? skillConfigService.saveSkill(skills[idx])
        }
    }

    func saveAgent(_ agent: Agent) {
        // Save localDirectory to UserDefaults (not to .md)
        saveLocalDirectory(for: agent)

        // Save the agent .md (currentDirectory is written, localDirectory is not)
        do {
            try configService.saveAgent(agent)
            if let index = agents.firstIndex(where: { $0.id == agent.id }) {
                agents[index] = agent
            }
        } catch {
            errorMessage = "Failed to save agent: \(error.localizedDescription)"
        }
    }

    /// Persist the local directory override for an agent in UserDefaults.
    private func saveLocalDirectory(for agent: Agent) {
        guard let filePath = agent.filePath?.path(percentEncoded: false) else { return }
        var localDirs = UserDefaults.standard.dictionary(forKey: "agentLocalDirectories") as? [String: String] ?? [:]
        if let dir = agent.localDirectory {
            localDirs[filePath] = dir.path(percentEncoded: false)
        } else {
            localDirs.removeValue(forKey: filePath)
        }
        UserDefaults.standard.set(localDirs, forKey: "agentLocalDirectories")
    }

    // MARK: - Agent Editor (Center Pane)

    /// Opens the agent editor in the center pane with the raw .md content.
    func showAgentEditor(_ agent: Agent) {
        autoSaveAgentIfNeeded()
        autoSaveSkillIfNeeded()
        selectedAgentId = agent.id
        selectedSkillId = nil
        editingAgent = agent
        editingAgentContent = agent.systemPrompt
        agentEditorHasChanges = false
        agentEditorTabOpen = true
        agentEditorTabName = agent.name
        centerPane = .agentEditor
    }

    /// Saves the system prompt from the agent editor back to disk.
    func saveAgentEditor() {
        guard let content = editingAgentContent,
              var agent = selectedAgent else { return }

        agent.systemPrompt = content
        saveAgent(agent)
        editingAgent = agent
        agentEditorHasChanges = false
    }

    /// Reverts the agent editor content to the current saved state.
    func revertAgentEditor() {
        guard let agent = selectedAgent else { return }
        editingAgentContent = agent.systemPrompt
        agentEditorHasChanges = false
    }

    /// Closes the agent editor tab (auto-saves if needed).
    func closeAgentEditor() {
        if agentEditorHasChanges {
            saveAgentEditor()
        }
        agentEditorTabOpen = false
        agentEditorTabName = nil
        editingAgentContent = nil
        agentEditorHasChanges = false
        if centerPane == .agentEditor {
            centerPane = .terminal
        }
    }

    /// Closes the skill editor tab (auto-saves if needed).
    func closeSkillEditor() {
        if skillHasChanges {
            saveEditingSkill()
        }
        skillEditorTabOpen = false
        skillEditorTabName = nil
        selectedSkillId = nil
        editingSkill = nil
        viewingBundledFileURL = nil
        if centerPane == .skillEditor {
            centerPane = .terminal
        }
    }

    /// Opens a schedule in the center pane editor tab.
    func showScheduleEditor(_ schedule: AgentSchedule) {
        autoSaveAgentIfNeeded()
        autoSaveSkillIfNeeded()
        selectedSkillId = nil
        // Show the associated agent in the right inspector
        selectedAgentId = agents.first { $0.name == schedule.agentName }?.id
        editingSchedule = schedule
        scheduleEditorTabOpen = true
        scheduleEditorTabName = schedule.agentName
        centerPane = .scheduleEditor
    }

    /// Closes the schedule editor tab.
    func closeScheduleEditor() {
        scheduleEditorTabOpen = false
        scheduleEditorTabName = nil
        editingSchedule = nil
        editingCloudTrigger = nil
        if centerPane == .scheduleEditor {
            centerPane = .terminal
        }
    }

    // MARK: - Cloud Trigger Actions

    /// Opens a cloud trigger in the center pane editor tab.
    func showCloudTriggerEditor(_ trigger: CloudTrigger) {
        autoSaveAgentIfNeeded()
        autoSaveSkillIfNeeded()
        selectedSkillId = nil
        selectedAgentId = nil
        editingSchedule = nil
        editingCloudTrigger = trigger
        scheduleEditorTabOpen = true
        scheduleEditorTabName = trigger.name
        centerPane = .scheduleEditor
    }

    /// Load cloud triggers on demand.
    func loadCloudTriggers() {
        Task {
            await cloudTriggerService.fetchTriggers()
        }
    }

    /// Create a new cloud trigger.
    func createCloudTrigger(_ request: CloudTriggerCreateRequest) async throws -> CloudTrigger {
        try await cloudTriggerService.createTrigger(request)
    }

    /// Update a cloud trigger.
    func updateCloudTrigger(_ trigger: CloudTrigger) async throws {
        try await cloudTriggerService.updateTrigger(trigger)
    }

    /// Run a cloud trigger immediately.
    func runCloudTrigger(id: String) async throws {
        try await cloudTriggerService.runTrigger(id: id)
    }

    /// Toggle enabled state of a cloud trigger.
    func toggleCloudTrigger(_ trigger: CloudTrigger) async throws {
        try await cloudTriggerService.toggleEnabled(trigger)
    }

    // MARK: - File Browser Actions

    /// Load the file tree for the current project, preserving expanded directories.
    /// Debounced to avoid rapid successive reloads blocking the main thread.
    func loadFileTree() {
        loadFileTreeWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.performLoadFileTree()
        }
        loadFileTreeWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    private func performLoadFileTree() {
        let expandedURLs = collectExpandedURLs(from: fileTreeRoots)

        let rootURL: URL
        if let project = selectedProject {
            rootURL = project.directoryPath
        } else {
            rootURL = FileManager.default.homeDirectoryForCurrentUser
        }
        fileTreeRoots = fileTreeService.loadRoots(projectURL: rootURL)

        if !expandedURLs.isEmpty {
            restoreExpandedState(nodes: fileTreeRoots, expandedURLs: expandedURLs)
        }
    }

    /// Collect URLs of all expanded directories in the tree.
    private func collectExpandedURLs(from nodes: [FileNode]) -> Set<URL> {
        var urls = Set<URL>()
        for node in nodes where node.isDirectory && node.isExpanded {
            urls.insert(node.url)
            if let children = node.children {
                urls.formUnion(collectExpandedURLs(from: children))
            }
        }
        return urls
    }

    /// Restore expanded state on newly created nodes by matching URLs.
    private func restoreExpandedState(nodes: [FileNode], expandedURLs: Set<URL>) {
        for node in nodes where node.isDirectory && expandedURLs.contains(node.url) {
            fileTreeService.expandNode(node)
            node.isExpanded = true
            if let children = node.children {
                restoreExpandedState(nodes: children, expandedURLs: expandedURLs)
            }
        }
    }

    /// Show the file creation alert for a new file.
    func promptCreateFile(in node: FileNode? = nil) {
        fileCreationParentNode = node
        fileCreationIsDirectory = false
        fileCreationName = ""
        showingFileCreationAlert = true
    }

    /// Show the file creation alert for a new folder.
    func promptCreateDirectory(in node: FileNode? = nil) {
        fileCreationParentNode = node
        fileCreationIsDirectory = true
        fileCreationName = ""
        showingFileCreationAlert = true
    }

    /// Create the file or directory after the user confirms the alert.
    func confirmFileCreation() {
        let name = fileCreationName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }

        let parentURL: URL
        if let node = fileCreationParentNode {
            parentURL = node.url
        } else if let project = selectedProject {
            parentURL = project.directoryPath
        } else {
            parentURL = FileManager.default.homeDirectoryForCurrentUser
        }

        let newURL = parentURL.appendingPathComponent(name)
        let fm = FileManager.default

        do {
            if fileCreationIsDirectory {
                try fm.createDirectory(at: newURL, withIntermediateDirectories: false)
            } else {
                fm.createFile(atPath: newURL.path, contents: nil)
            }
        } catch {
            return
        }

        // Refresh the parent node or root
        if let node = fileCreationParentNode {
            node.children = fileTreeService.loadChildren(at: node.url)
            node.isExpanded = true
        } else {
            loadFileTree()
        }

        // Open new file in editor
        if !fileCreationIsDirectory {
            openFile(url: newURL)
        }
    }

    /// Open a file in the file editor tab.
    func openFile(url: URL) {
        // If already open, select it in the pane that owns it
        if let existing = openFiles.first(where: { $0.url == url }) {
            updatePane(existing.paneId) {
                $0.selectedFileId = existing.id
                $0.centerPane = .fileEditor
            }
            activePaneId = existing.paneId
            return
        }

        let kind = FileKind.from(extension: url.pathExtension)

        let content: String
        if kind == .text {
            // Read file content as text
            guard let data = try? Data(contentsOf: url),
                  let text = String(data: data, encoding: .utf8) else {
                return
            }
            content = text
        } else {
            // Media files don't need text content
            content = ""
        }

        var file = OpenFile(url: url, kind: kind, content: content)
        file.paneId = activePaneId
        openFiles.append(file)
        selectedFileId = file.id
        centerPane = .fileEditor
        if kind == .text {
            openFileWatcher.watch(id: file.id, url: url)
        }
    }

    /// Save the file with the given ID to disk.
    func saveFile(fileId: UUID) {
        guard let index = openFiles.firstIndex(where: { $0.id == fileId }) else { return }
        let file = openFiles[index]
        try? file.content.write(to: file.url, atomically: true, encoding: .utf8)
        openFiles[index].hasChanges = false
    }

    /// Move a file tree node to the Trash and refresh the tree.
    /// Any matching open file tab is closed first.
    func deleteFileNode(_ node: FileNode) {
        let url = node.url
        for file in openFiles where file.url == url {
            closeFileTab(fileId: file.id)
        }

        var resultingURL: NSURL?
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: &resultingURL)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Failed to move to Trash"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.runModal()
            return
        }

        if let parent = findParentNode(of: node, in: fileTreeRoots) {
            parent.children = fileTreeService.loadChildren(at: parent.url)
        } else {
            loadFileTree()
        }
    }

    /// Walk the tree to find the parent of a given node.
    private func findParentNode(of target: FileNode, in nodes: [FileNode]) -> FileNode? {
        for node in nodes where node.isDirectory {
            if let children = node.children {
                if children.contains(where: { $0.id == target.id }) {
                    return node
                }
                if let found = findParentNode(of: target, in: children) {
                    return found
                }
            }
        }
        return nil
    }

    /// Close a file editor tab. Pane-aware: only the pane that owns the file
    /// has its selection / centerPane affected.
    func closeFileTab(fileId: UUID) {
        openFileWatcher.unwatch(id: fileId)
        let owner = paneOwning(fileId: fileId) ?? activePaneId
        openFiles.removeAll { $0.id == fileId }
        let remainingInPane = openFiles.filter { $0.paneId == owner }
        updatePane(owner) {
            if $0.selectedFileId == fileId {
                $0.selectedFileId = remainingInPane.last?.id
            }
            if remainingInPane.isEmpty && $0.centerPane == .fileEditor {
                $0.centerPane = .terminal
            }
        }
    }

    /// Update the content of an open file (called on text edit).
    func updateFileContent(fileId: UUID, content: String) {
        guard let index = openFiles.firstIndex(where: { $0.id == fileId }) else { return }
        openFiles[index].content = content
        openFiles[index].hasChanges = true
    }

    /// Toggle source/preview view mode on a Markdown file.
    func toggleFileViewMode(fileId: UUID) {
        guard let index = openFiles.firstIndex(where: { $0.id == fileId }),
              openFiles[index].isMarkdown else { return }
        openFiles[index].viewMode = openFiles[index].viewMode == .source ? .preview : .source
    }

    /// Toggle preview on the file currently focused in the active pane. Returns whether a toggle occurred.
    @discardableResult
    func toggleMarkdownPreviewInActivePane() -> Bool {
        guard let fileId = activePane.selectedFileId,
              let file = openFiles.first(where: { $0.id == fileId }),
              file.isMarkdown else { return false }
        toggleFileViewMode(fileId: fileId)
        return true
    }

    /// The currently selected open file.
    var selectedOpenFile: OpenFile? {
        guard let id = selectedFileId else { return nil }
        return openFiles.first { $0.id == id }
    }

    /// Opens a bundled file in the center pane viewer.
    func openBundledFile(_ url: URL) {
        viewingBundledFileURL = url
    }

    /// Closes the bundled file viewer, returning to SKILL.md editor.
    func closeBundledFile() {
        viewingBundledFileURL = nil
    }

    // MARK: - External Editor

    /// Known code editors with their bundle identifiers.
    private static let knownEditors: [(bundleId: String, name: String)] = [
        ("com.microsoft.VSCode", "Visual Studio Code"),
        ("com.todesktop.230313mzl4w4u92", "Cursor"),
        ("dev.zed.Zed", "Zed"),
        ("com.sublimetext.4", "Sublime Text"),
        ("com.sublimetext.3", "Sublime Text 3"),
        ("abnerworks.Typora", "Typora"),
        ("com.apple.dt.Xcode", "Xcode"),
        ("com.apple.TextEdit", "TextEdit"),
    ]

    struct EditorOption: Identifiable {
        let id: String // bundle identifier
        let name: String
        let url: URL
    }

    /// Editors currently installed on this machine.
    var availableEditors: [EditorOption] {
        Self.knownEditors.compactMap { editor in
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: editor.bundleId) else { return nil }
            return EditorOption(id: editor.bundleId, name: editor.name, url: url)
        }
    }

    /// Display name for the currently preferred editor.
    var preferredEditorName: String {
        if let bundleId = preferredEditorBundleId,
           let match = Self.knownEditors.first(where: { $0.bundleId == bundleId }) {
            return match.name
        }
        if let bundleId = preferredEditorBundleId,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
            return url.deletingPathExtension().lastPathComponent
        }
        return "Default"
    }

    /// Opens a file in the preferred external editor (or system default).
    func openInExternalEditor(_ url: URL) {
        if let bundleId = preferredEditorBundleId,
           let editorURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
            Task {
                try? await NSWorkspace.shared.open([url], withApplicationAt: editorURL, configuration: NSWorkspace.OpenConfiguration())
            }
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    /// Shows an open panel to pick a custom editor application.
    func chooseExternalEditor() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Select an external editor"

        if panel.runModal() == .OK, let url = panel.url,
           let bundle = Bundle(url: url), let bundleId = bundle.bundleIdentifier {
            preferredEditorBundleId = bundleId
        }
    }

    // MARK: - AI Creation Session

    func startCreationSession(scope: AgentScope, projectDirectory: URL? = nil) {
        let targetDir: URL

        switch scope {
        case .project:
            if let projectDir = projectDirectory {
                targetDir = projectDir.appending(path: ".claude/agents")
            } else if let projectDir = selectedProject?.agentsDirectory {
                targetDir = projectDir
            } else {
                errorMessage = "No project directory specified."
                return
            }
        case .user:
            targetDir = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude/agents")
        case .cloud:
            return
        }

        try? FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)

        let session = CreationSession(targetScope: scope, targetDirectory: targetDir)
        let systemPrompt = buildCreationPrompt(targetDirectory: targetDir.path(percentEncoded: false))

        do {
            let sessionId = try processManager.startCreationSession(session: session, systemPrompt: systemPrompt)
            creationSession = session
            let agentSession = AgentSession(id: sessionId, agentId: session.id, agentName: "Creating with AI...", isCreationSession: true, paneId: activePaneId)
            activeSessions.append(agentSession)
            selectedSessionId = sessionId
            selectedAgentId = nil
            sidebarTab = .sessions
            centerPane = .terminal
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func endCreationSession() {
        guard let session = creationSession else { return }
        let sessionId = session.id

        stopSkillCreationPolling()

        if processManager.isRunning(sessionId: sessionId) {
            processManager.stop(sessionId: sessionId)
        }
        activeSessions.removeAll { $0.id == sessionId }
        processManager.removeProcess(sessionId: sessionId)
        creationSession = nil

        if selectedSessionId == sessionId {
            selectedSessionId = activeSessions.last?.id
        }
    }

    // MARK: - AI Team Creation Session

    private func buildCreationPrompt(targetDirectory: String) -> String {
        return """
        You are a Claude Code agent creation assistant. Gather requirements from the user and create a .md file in \(targetDirectory).

        Agent definition file format:
        ---
        name: agent-name (English, hyphen-separated)
        description: Description text
        model: opus
        tools: Tool1, Tool2
        permissionMode: default
        ---

        Write the system prompt here.

        Available models: inherit, haiku, sonnet, opus
        Available tools: Read, Edit, Write, Bash, Grep, Glob, WebSearch, WebFetch, Agent(name)
        Permission modes: default, acceptEdits, dontAsk, bypassPermissions, plan

        Ask the user what kind of agent they want to create.
        """
    }

    // MARK: - AI Skill Creation Session

    func startSkillCreationSession(scope: AgentScope, projectDirectory: URL? = nil) {
        let targetDir: URL

        switch scope {
        case .project:
            if let projectDir = projectDirectory {
                targetDir = projectDir.appending(path: ".claude/skills")
            } else if let project = selectedProject {
                targetDir = project.skillsDirectory
            } else {
                errorMessage = "No project directory specified."
                return
            }
        case .user:
            targetDir = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude/skills")
        case .cloud:
            return
        }

        try? FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)

        // Ensure the skills directory is being watched (it may not have existed at setupFileWatcher time)
        fileWatcher.watch(directory: targetDir)

        let session = CreationSession(targetScope: scope, targetDirectory: targetDir, creationType: .skill)
        let systemPrompt = buildSkillCreationPrompt(targetDirectory: targetDir.path(percentEncoded: false))

        do {
            let sessionId = try processManager.startCreationSession(session: session, systemPrompt: systemPrompt)
            creationSession = session
            let agentSession = AgentSession(id: sessionId, agentId: session.id, agentName: "Creating skill...", isCreationSession: true, paneId: activePaneId)
            activeSessions.append(agentSession)
            selectedSessionId = sessionId
            selectedAgentId = nil
            autoSaveSkillIfNeeded()
            selectedSkillId = nil
            editingSkill = nil
            sidebarTab = .sessions
            centerPane = .terminal
            startSkillCreationPolling()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func startSkillCreationPolling() {
        skillCreationPollTimer?.invalidate()
        skillCreationPollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.reloadSkills()
            }
        }
    }

    private func stopSkillCreationPolling() {
        skillCreationPollTimer?.invalidate()
        skillCreationPollTimer = nil
    }

    private func buildSkillCreationPrompt(targetDirectory: String) -> String {
        return """
        You are a Claude Code skill creation assistant. Gather requirements from the user and create a skill directory with a SKILL.md file in \(targetDirectory).

        ## What is a Skill?
        Skills are definitions of specialized knowledge, workflows, and tool integrations that extend Claude Code's capabilities.
        Users invoke skills via `/skill-name` in Claude Code. Skills can also be auto-triggered based on their description.

        ## Directory Structure
        ```
        {skill-name}/
        ├── SKILL.md          # Required: Skill definition file
        └── references/       # Optional: Supplementary documents
            └── guide.md
        ```

        ## SKILL.md Format
        ```yaml
        ---
        name: skill-name
        description: When this skill should be triggered and what it does. Be specific.
        disable-model-invocation: true
        allowed-tools: Read, Grep, Edit
        argument-hint: [arg1] [arg2]
        ---

        # Skill Title

        ## Overview
        Purpose and usage of this skill.

        ## Workflow
        1. Step 1
        2. Step 2

        ## Guidelines
        - Instruction 1
        - Instruction 2
        ```

        ## Frontmatter Fields

        | Field | Required | Description |
        |-------|----------|-------------|
        | name | Yes | Skill name (lowercase, hyphens, max 64 chars) |
        | description | Yes | Trigger matching keywords. Be specific about WHEN to use |
        | disable-model-invocation | No | `true` = manual `/skill-name` only (recommended for side effects). Default: false |
        | user-invocable | No | `false` = Claude-only, hidden from / menu. Default: true |
        | allowed-tools | No | Comma-separated tool list. Example: `Read, Grep, Bash(npm *)` |
        | model | No | Override model: haiku, sonnet, opus |
        | effort | No | Quality level: low, medium, high, max |
        | context | No | `fork` to run in isolated subagent. Default: inline |
        | agent | No | Subagent type when context=fork: Explore, Plan, general-purpose |
        | argument-hint | No | Autocomplete hint: `[feature-name]`, `[file] [format]` |

        ## Variable Substitution
        These placeholders are replaced at invocation time:
        - `$ARGUMENTS` — all arguments passed (e.g. `/skill foo bar` → `foo bar`)
        - `$0`, `$1`, `$2` — individual arguments by index
        - `${CLAUDE_SKILL_DIR}` — absolute path to the skill directory
        - `${CLAUDE_SESSION_ID}` — current session UUID
        - `` !`command` `` — shell command output injected before Claude sees the prompt

        ## Design Guidelines
        - `description` is the most important field. Include concrete trigger phrases
        - Set `disable-model-invocation: true` for skills with side effects (deploy, delete, etc.)
        - Set appropriate `allowed-tools` to minimize permission prompts
        - SKILL.md body should be 500 lines or less. Split into references/ if longer
        - Write instructions in imperative form
        - Including the reasoning behind instructions is effective
        - Use `$ARGUMENTS` for parameterized skills

        ## Creation Steps
        1. Ask the user what kind of skill they want to create
        2. Confirm purpose, trigger conditions, required tools, and output format
        3. Decide: should it be manual-only or auto-triggerable?
        4. Create the SKILL.md file with appropriate frontmatter
        5. Create guide documents in references/ if needed

        Ask the user what kind of skill they want to create.
        """
    }

    // MARK: - Codex AI Creation Sessions

    /// Starts an AI-assisted agent creation session that produces Codex CLI-format agents.
    func startCodexCreationSession(scope: AgentScope, projectDirectory: URL? = nil) {
        let targetDir: URL

        switch scope {
        case .project:
            if let projectDir = projectDirectory {
                targetDir = projectDir.appending(path: ".codex/agents")
            } else if let project = selectedProject {
                targetDir = project.directoryPath.appending(path: ".codex/agents")
            } else {
                errorMessage = "No project directory specified."
                return
            }
        case .user:
            targetDir = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".codex/agents")
        case .cloud:
            return
        }

        try? FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)

        let session = CreationSession(targetScope: scope, targetDirectory: targetDir, creationType: .agent)
        let systemPrompt = buildCodexAgentCreationPrompt(targetDirectory: targetDir.path(percentEncoded: false))

        do {
            let sessionId = try processManager.startCreationSession(session: session, systemPrompt: systemPrompt)
            creationSession = session
            let agentSession = AgentSession(id: sessionId, agentId: session.id, agentName: "Creating Codex agent...", isCreationSession: true, paneId: activePaneId)
            activeSessions.append(agentSession)
            selectedSessionId = sessionId
            selectedAgentId = nil
            sidebarTab = .sessions
            centerPane = .terminal
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Starts an AI-assisted skill creation session that produces Codex CLI-format skills.
    func startCodexSkillCreationSession(scope: AgentScope, projectDirectory: URL? = nil) {
        let targetDir: URL

        switch scope {
        case .project:
            if let projectDir = projectDirectory {
                targetDir = projectDir.appending(path: ".codex/skills")
            } else if let project = selectedProject {
                targetDir = project.directoryPath.appending(path: ".codex/skills")
            } else {
                errorMessage = "No project directory specified."
                return
            }
        case .user:
            targetDir = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".codex/skills")
        case .cloud:
            return
        }

        try? FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)
        fileWatcher.watch(directory: targetDir)

        let session = CreationSession(targetScope: scope, targetDirectory: targetDir, creationType: .skill)
        let systemPrompt = buildCodexSkillCreationPrompt(targetDirectory: targetDir.path(percentEncoded: false))

        do {
            let sessionId = try processManager.startCreationSession(session: session, systemPrompt: systemPrompt)
            creationSession = session
            let agentSession = AgentSession(id: sessionId, agentId: session.id, agentName: "Creating Codex skill...", isCreationSession: true, paneId: activePaneId)
            activeSessions.append(agentSession)
            selectedSessionId = sessionId
            selectedAgentId = nil
            autoSaveSkillIfNeeded()
            selectedSkillId = nil
            editingSkill = nil
            sidebarTab = .sessions
            centerPane = .terminal
            startSkillCreationPolling()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func buildCodexAgentCreationPrompt(targetDirectory: String) -> String {
        return """
        You are a Codex CLI agent creation assistant. Gather requirements from the user and create a .md file in \(targetDirectory).

        Codex agent definition file format:
        ---
        name: agent-name (English, hyphen-separated)
        description: Description text
        model: gpt-5.4
        ---

        Write the system prompt here.

        Available models: gpt-5.4, gpt-5.4-mini, o3, o4-mini
        Sandbox modes: workspace-write (default), read-only, network-only
        Approval modes: on-request (default), auto-approve

        Important Codex CLI differences from Claude Code:
        - Uses `codex` command instead of `claude`
        - Permission model uses --sandbox and --full-auto flags
        - No `tools` frontmatter field (Codex manages tools internally)
        - No `permissionMode` field (use CLI flags instead)

        Ask the user what kind of agent they want to create.
        """
    }

    private func buildCodexSkillCreationPrompt(targetDirectory: String) -> String {
        return """
        You are a Codex CLI skill creation assistant. Gather requirements from the user and create a skill directory with a SKILL.md file in \(targetDirectory).

        ## What is a Skill?
        Skills extend CLI capabilities with specialized knowledge and workflows.
        Users invoke skills via `/skill-name` in the CLI.

        ## Directory Structure
        ```
        {skill-name}/
        ├── SKILL.md              # Required: Skill definition
        ├── agents/
        │   └── openai.yaml       # Optional: OpenAI agent config
        ├── references/           # Optional: Supplementary docs
        └── scripts/              # Optional: Helper scripts
        ```

        ## SKILL.md Format
        ```yaml
        ---
        name: skill-name
        description: When this skill should be triggered and what it does.
        ---

        # Skill Title

        ## Overview
        Purpose and usage.

        ## Workflow
        1. Step 1
        2. Step 2
        ```

        ## Frontmatter Fields

        | Field | Required | Description |
        |-------|----------|-------------|
        | name | Yes | Skill name (lowercase, hyphens) |
        | description | Yes | Trigger keywords. Be specific about WHEN to use |

        ## agents/openai.yaml Format (optional)
        ```yaml
        model: gpt-5.4
        instructions: "Additional instructions for the agent"
        ```

        ## Design Guidelines
        - `description` is the most important field — include trigger phrases
        - SKILL.md body is the main instruction document
        - Use references/ for supplementary documents
        - Use scripts/ for helper shell scripts
        - Keep SKILL.md body under 500 lines

        ## Creation Steps
        1. Ask the user what kind of skill they want to create
        2. Confirm purpose, trigger conditions, and output format
        3. Create the SKILL.md file with appropriate frontmatter
        4. Optionally create agents/openai.yaml for model config
        5. Create guide documents in references/ if needed

        Ask the user what kind of skill they want to create.
        """
    }

    // MARK: - Process Management

    /// Returns available CLI providers (those whose binary can be resolved).
    var availableCLIProviders: [CLIProviderType] {
        CLIProviderType.allCases.filter { processManager.cliPathResolver.resolve(for: $0) != nil }
    }

    /// Starts a standalone Claude session not tied to any agent.
    func startStandaloneSession(
        name: String = "Terminal",
        model: AgentModel = .inherit,
        permissionMode: PermissionMode = .default,
        workingDirectory: URL? = nil,
        systemPrompt: String? = nil,
        customFlags: String? = nil,
        provider: CLIProviderType = .claude
    ) {
        let workingDir: String? = workingDirectory?.path(percentEncoded: false) ?? {
            switch projectSelection {
            case .project(let project):
                return project.directoryPath.path(percentEncoded: false)
            default:
                return nil
            }
        }()

        do {
            let sessionId = try processManager.startStandalone(
                model: model,
                permissionMode: permissionMode,
                workingDirectory: workingDir,
                systemPrompt: systemPrompt,
                customFlags: customFlags,
                provider: provider
            )
            let resolvedDir: URL? = workingDirectory ?? {
                switch projectSelection {
                case .project(let project):
                    return project.directoryPath
                default:
                    return nil
                }
            }()
            let session = AgentSession(
                id: sessionId,
                agentId: sessionId, // sentinel — no real agent
                agentName: name,
                workingDirectory: resolvedDir,
                cliProviderType: provider,
                paneId: activePaneId
            )
            activeSessions.append(session)
            sessionHistoryService.recordSessionStart(session: session)
            selectedSessionId = sessionId
            centerPane = .terminal
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Starts a session using a raw command string (Manual mode).
    func startManualSession(
        name: String = "Terminal",
        rawCommand: String,
        workingDirectory: URL? = nil
    ) {
        let workingDir: String? = workingDirectory?.path(percentEncoded: false) ?? {
            switch projectSelection {
            case .project(let project):
                return project.directoryPath.path(percentEncoded: false)
            default:
                return nil
            }
        }()

        do {
            let sessionId = try processManager.startManual(
                rawCommand: rawCommand,
                workingDirectory: workingDir
            )
            let resolvedDir: URL? = workingDirectory ?? {
                switch projectSelection {
                case .project(let project):
                    return project.directoryPath
                default:
                    return nil
                }
            }()
            let session = AgentSession(
                id: sessionId,
                agentId: sessionId,
                agentName: name,
                workingDirectory: resolvedDir,
                paneId: activePaneId
            )
            activeSessions.append(session)
            sessionHistoryService.recordSessionStart(session: session)
            selectedSessionId = sessionId
            centerPane = .terminal
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Active shell terminal sessions (not running Claude CLI).
    var activeShellSessions: [AgentSession] {
        activeSessions.filter { $0.isShellSession }
    }

    /// Starts a standalone shell terminal (zsh or bash, not running Claude CLI).
    func startShellSession(shell: ShellType, workingDirectory: URL? = nil, command: String? = nil, customName: String? = nil) {
        let workingDir: String? = workingDirectory?.path(percentEncoded: false) ?? {
            switch projectSelection {
            case .project(let project):
                return project.directoryPath.path(percentEncoded: false)
            default:
                return nil
            }
        }()

        let sessionId = processManager.startShellTerminal(
            shell: shell,
            workingDirectory: workingDir,
            command: command
        )
        let resolvedDir: URL? = workingDirectory ?? {
            switch projectSelection {
            case .project(let project):
                return project.directoryPath
            default:
                return nil
            }
        }()
        let session = AgentSession(
            id: sessionId,
            agentId: sessionId, // sentinel — no real agent
            agentName: shell.displayName,
            customName: customName,
            workingDirectory: resolvedDir,
            shellType: shell,
            paneId: activePaneId
        )
        activeSessions.append(session)
        selectedSessionId = sessionId
        centerPane = .terminal
    }

    /// Launches a shell session from a preset.
    func startPresetSession(_ preset: ShellPreset) {
        let dir = preset.directory.isEmpty ? nil : URL(filePath: preset.directory)
        startShellSession(
            shell: preset.shell,
            workingDirectory: dir,
            command: preset.command,
            customName: preset.name
        )
    }

    // MARK: - Shell Presets

    func reloadShellPresets() {
        shellPresets = shellPresetService.loadPresets()
    }

    func saveShellPreset(_ preset: ShellPreset) {
        if let idx = shellPresets.firstIndex(where: { $0.id == preset.id }) {
            shellPresets[idx] = preset
        } else {
            shellPresets.append(preset)
        }
        shellPresetService.savePresets(shellPresets)
    }

    func deleteShellPreset(_ preset: ShellPreset) {
        shellPresets.removeAll { $0.id == preset.id }
        shellPresetService.savePresets(shellPresets)
    }

    // MARK: - Session Presets

    func reloadSessionPresets() {
        sessionPresets = sessionPresetService.loadPresets()
    }

    func saveSessionPreset(_ preset: SessionPreset) {
        if let idx = sessionPresets.firstIndex(where: { $0.id == preset.id }) {
            sessionPresets[idx] = preset
        } else {
            sessionPresets.append(preset)
        }
        sessionPresetService.savePresets(sessionPresets)
    }

    func deleteSessionPreset(_ preset: SessionPreset) {
        sessionPresets.removeAll { $0.id == preset.id }
        sessionPresetService.savePresets(sessionPresets)
    }

    func moveSessionPreset(fromId: UUID, toId: UUID) {
        guard let fromIndex = sessionPresets.firstIndex(where: { $0.id == fromId }),
              let toIndex = sessionPresets.firstIndex(where: { $0.id == toId }),
              fromIndex != toIndex else { return }
        let item = sessionPresets.remove(at: fromIndex)
        let insertAt = sessionPresets.firstIndex(where: { $0.id == toId }) ?? sessionPresets.endIndex
        sessionPresets.insert(item, at: insertAt)
        sessionPresetService.savePresets(sessionPresets)
    }

    /// Launches a standalone Claude session from a saved preset.
    func startSessionPreset(_ preset: SessionPreset) {
        let dir = preset.directory.isEmpty ? nil : URL(filePath: preset.directory)
        if let rawCommand = preset.rawCommand {
            startManualSession(
                name: preset.name,
                rawCommand: rawCommand,
                workingDirectory: dir
            )
        } else {
            startStandaloneSession(
                name: preset.name,
                model: preset.model,
                permissionMode: preset.permissionMode,
                workingDirectory: dir,
                systemPrompt: preset.systemPrompt,
                customFlags: preset.customFlags,
                provider: preset.provider
            )
        }
    }

    /// Starts a new session for the agent. Uses the agent's defaultProvider unless overridden.
    func startAgent(_ agent: Agent, provider: CLIProviderType? = nil) {
        // Manual mode: execute rawCommand as-is
        if let rawCommand = agent.rawCommand, !rawCommand.isEmpty {
            startManualSession(
                name: agent.name,
                rawCommand: rawCommand,
                workingDirectory: agent.effectiveDirectory
            )
            selectedAgentId = agent.id
            return
        }

        let provider = provider ?? agent.defaultProvider
        // Build memory context if enabled
        var memoryContext: String? = nil
        if agent.memoryEnabled {
            memoryContext = memoryService.buildMemoryContext(for: agent)
            if let memoryDir = agent.memoryDirectory {
                try? FileManager.default.createDirectory(at: memoryDir, withIntermediateDirectories: true)
                fileWatcher.watch(directory: memoryDir)
            }
        }

        // Resolve memory DB path for MCP recall_memory
        let memoryDbPath = memoryDatabaseManager.databasePath(for: agent)

        do {
            let sessionId = try processManager.start(agent: agent, memoryContext: memoryContext, memoryDbPath: memoryDbPath, provider: provider)
            let session = AgentSession(id: sessionId, agentId: agent.id, agentName: agent.name, agentFilePath: agent.filePath?.path(percentEncoded: false), workingDirectory: agent.effectiveDirectory, cliProviderType: provider, paneId: activePaneId)
            activeSessions.append(session)
            sessionHistoryService.recordSessionStart(session: session)
            selectedSessionId = sessionId
            selectedAgentId = agent.id
            centerPane = .terminal
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Starts a new chat-mode session for the agent (uses stream-json instead of PTY).
    func startChatSession(_ agent: Agent) {
        guard let claudePath = processManager.claudePathResolver.resolve() else {
            errorMessage = "Could not find the 'claude' CLI binary."
            return
        }

        // Build memory context
        var memoryContext: String? = nil
        if agent.memoryEnabled {
            memoryContext = memoryService.buildMemoryContext(for: agent)
        }

        let workingDir = agent.effectiveDirectory?.path(percentEncoded: false)

        let chatManager = ChatSessionManager(
            claudePath: claudePath,
            agentName: agent.name,
            model: agent.model,
            permissionMode: agent.permissionMode,
            workingDirectory: workingDir,
            memoryContext: memoryContext
        )

        let sessionId = UUID()
        chatManagers[sessionId] = chatManager

        let session = AgentSession(
            id: sessionId,
            agentId: agent.id,
            agentName: agent.name,
            agentFilePath: agent.filePath?.path(percentEncoded: false),
            workingDirectory: agent.effectiveDirectory,
            displayMode: .chat,
            paneId: activePaneId
        )
        activeSessions.append(session)
        selectedSessionId = sessionId
        selectedAgentId = agent.id
        centerPane = .terminal
    }

    func duplicateSession(sessionId: UUID) {
        guard let session = activeSessions.first(where: { $0.id == sessionId }) else { return }

        // Standalone session (agentId == id means no real agent)
        if session.agentId == session.id {
            startStandaloneSession(
                name: session.agentName,
                workingDirectory: session.workingDirectory
            )
            return
        }

        if let agent = agents.first(where: { $0.id == session.agentId })
                ?? agents.first(where: { $0.filePath?.path(percentEncoded: false) == session.agentFilePath }) {
            startAgent(agent)
        } else {
            // Agent not found (e.g. different project selected) — duplicate as standalone
            startStandaloneSession(
                name: session.agentName,
                workingDirectory: session.workingDirectory
            )
        }
    }

    /// Closes all sessions for a given agent.
    func closeAllSessions(agentId: UUID) {
        let sessionIds = activeSessions.filter { $0.agentId == agentId }.map(\.id)
        for sessionId in sessionIds {
            closeTab(sessionId: sessionId)
        }
    }

    func restartAgent(_ agent: Agent) {
        closeAllSessions(agentId: agent.id)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.startAgent(agent)
        }
    }

    /// Resumes a stopped session using the Claude CLI --resume flag.
    func resumeSession(sessionId: UUID) {
        guard let session = activeSessions.first(where: { $0.id == sessionId }) else { return }

        let agent = agents.first(where: { $0.id == session.agentId })
            ?? agents.first(where: { $0.filePath?.path(percentEncoded: false) == session.agentFilePath })

        var memoryContext: String? = nil
        if let agent, agent.memoryEnabled {
            memoryContext = memoryService.buildMemoryContext(for: agent)
        }

        let memoryDbPath = memoryDatabaseManager.databasePath(for: agent, fallbackProjectPath: session.workingDirectory?.path(percentEncoded: false))

        do {
            try processManager.resume(
                sessionId: sessionId,
                agent: agent,
                memoryContext: memoryContext,
                workingDirectory: session.workingDirectory?.path(percentEncoded: false),
                memoryDbPath: memoryDbPath
            )
            // Move session to active pane so it appears in the correct tab bar
            if let idx = activeSessions.firstIndex(where: { $0.id == sessionId }) {
                activeSessions[idx].paneId = activePaneId
            }
            selectedSessionId = sessionId
            selectedAgentId = agent?.id
            centerPane = .terminal
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Whether a session can be resumed (stopped with a resume ID).
    func canResumeSession(sessionId: UUID) -> Bool {
        processManager.processes[sessionId]?.claudeResumeId != nil
    }

    /// Resumes a session from a history record.
    /// Resolve an agent from the loaded agents array, falling back to loading directly from file.
    /// This handles the case where the user is in "home" mode but resumes a session
    /// that belongs to a different project — the project agent isn't in `agents`.
    private func resolveAgentForRecord(_ record: SessionRecord) -> Agent? {
        // 1. Try loaded agents by filePath (most stable)
        if let filePath = record.agentFilePath,
           let found = agents.first(where: { $0.filePath?.path(percentEncoded: false) == filePath }) {
            return found
        }
        // 2. Try loaded agents by name
        if let found = agents.first(where: { $0.name == record.agentName }) {
            return found
        }
        // 3. Load directly from file (e.g. home mode resuming a project agent)
        if let filePath = record.agentFilePath {
            let url = URL(filePath: filePath)
            let isUserAgent = SessionRecord.deriveProjectPath(from: filePath) == nil
            return configService.parseAgentFile(at: url, scope: isUserAgent ? .user : .project)
        }
        return nil
    }

    func resumeFromHistory(record: SessionRecord) {
        guard let resumeId = record.claudeResumeId else {
            errorMessage = "This session cannot be resumed (no resume ID)."
            return
        }

        // Find the agent by filePath, then fall back to name, then load from file.
        // The agent is used for memory context and display only —
        // the working directory always comes from the session record.
        let agent: Agent? = resolveAgentForRecord(record)

        // Build memory context
        var memoryContext: String? = nil
        if let agent, agent.memoryEnabled {
            memoryContext = memoryService.buildMemoryContext(for: agent)
        }

        // Create a new session
        let provider = record.cliProviderType ?? .claude
        let newSessionId = UUID()
        let process = AgentProcess(agentId: agent?.id ?? newSessionId)
        process.claudeResumeId = resumeId
        process.cliProviderType = provider
        processManager.registerProcess(sessionId: newSessionId, process: process)

        // Use the record's project path as working directory —
        // it reflects where the Claude CLI session was actually created.
        // Fall back to home directory so resume never fails due to nil working dir.
        let workingDirectory = record.projectPath
            ?? FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false)
        let memoryDbPath = memoryDatabaseManager.databasePath(for: agent, fallbackProjectPath: record.projectPath)

        do {
            try processManager.resume(
                sessionId: newSessionId,
                agent: agent,
                memoryContext: memoryContext,
                workingDirectory: workingDirectory,
                memoryDbPath: memoryDbPath
            )
            let workingDir: URL? = record.projectPath.flatMap { URL(filePath: $0) } ?? agent?.effectiveDirectory
            let session = AgentSession(
                id: newSessionId,
                agentId: agent?.id ?? newSessionId,
                agentName: agent?.name ?? record.agentName,
                agentFilePath: record.agentFilePath ?? agent?.filePath?.path(percentEncoded: false),
                workingDirectory: workingDir,
                cliProviderType: provider,
                paneId: activePaneId)
            activeSessions.append(session)
            sessionHistoryService.recordSessionStart(session: session)
            selectedSessionId = newSessionId
            if let agent { selectedAgentId = agent.id }
            sidebarTab = .sessions
            centerPane = .terminal

            // Clear resume ID from old record (consumed)
            sessionHistoryService.clearResumeId(sessionId: record.id)
        } catch {
            // Clean up on failure
            processManager.removeProcess(sessionId: newSessionId)
            sessionHistoryService.clearResumeId(sessionId: record.id)
            errorMessage = "Failed to resume session: \(error.localizedDescription)"
        }
    }

    // MARK: - Fork Session

    /// Forks an active session using `--fork-session`, creating an independent branch.
    func forkSession(sessionId: UUID) {
        guard let session = activeSessions.first(where: { $0.id == sessionId }) else { return }

        let agent = agents.first(where: { $0.id == session.agentId })
            ?? agents.first(where: { $0.filePath?.path(percentEncoded: false) == session.agentFilePath })

        var memoryContext: String? = nil
        if let agent, agent.memoryEnabled {
            memoryContext = memoryService.buildMemoryContext(for: agent)
        }

        let memoryDbPath = memoryDatabaseManager.databasePath(for: agent, fallbackProjectPath: session.workingDirectory?.path(percentEncoded: false))

        do {
            let newSessionId = try processManager.forkSession(
                sourceSessionId: sessionId,
                agent: agent,
                memoryContext: memoryContext,
                workingDirectory: session.workingDirectory?.path(percentEncoded: false),
                memoryDbPath: memoryDbPath
            )
            let newSession = AgentSession(
                id: newSessionId,
                agentId: session.agentId,
                agentName: session.agentName,
                agentFilePath: session.agentFilePath,
                workingDirectory: session.workingDirectory,
                cliProviderType: session.cliProviderType,
                paneId: session.paneId
            )
            activeSessions.append(newSession)
            sessionHistoryService.recordSessionStart(session: newSession)
            selectedSessionId = newSessionId
            centerPane = .terminal
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Whether a session can be forked (has a resume ID — running or stopped).
    func canForkSession(sessionId: UUID) -> Bool {
        processManager.processes[sessionId]?.claudeResumeId != nil
    }

    /// Forks a session from a history record, creating an independent branch.
    /// Unlike resumeFromHistory, this does NOT consume the original resume ID.
    func forkFromHistory(record: SessionRecord) {
        guard let resumeId = record.claudeResumeId else {
            errorMessage = "This session cannot be forked (no resume ID)."
            return
        }

        let agent: Agent? = resolveAgentForRecord(record)
        let provider = record.cliProviderType ?? .claude

        var memoryContext: String? = nil
        if let agent, agent.memoryEnabled {
            memoryContext = memoryService.buildMemoryContext(for: agent)
        }

        let workingDirectory = record.projectPath
            ?? FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false)
        let memoryDbPath = memoryDatabaseManager.databasePath(for: agent, fallbackProjectPath: record.projectPath)

        do {
            let newSessionId = try processManager.forkFromHistory(
                resumeId: resumeId,
                agentId: agent?.id ?? UUID(),
                agent: agent,
                memoryContext: memoryContext,
                workingDirectory: workingDirectory,
                memoryDbPath: memoryDbPath,
                provider: provider
            )
            let workingDir: URL? = record.projectPath.flatMap { URL(filePath: $0) } ?? agent?.effectiveDirectory
            let newSession = AgentSession(
                id: newSessionId,
                agentId: agent?.id ?? newSessionId,
                agentName: agent?.name ?? record.agentName,
                agentFilePath: record.agentFilePath ?? agent?.filePath?.path(percentEncoded: false),
                workingDirectory: workingDir,
                cliProviderType: provider,
                paneId: activePaneId
            )
            activeSessions.append(newSession)
            sessionHistoryService.recordSessionStart(session: newSession)
            selectedSessionId = newSessionId
            if let agent { selectedAgentId = agent.id }
            sidebarTab = .sessions
            centerPane = .terminal
            // Do NOT clear the original resume ID — fork preserves the source
        } catch {
            errorMessage = "Failed to fork session: \(error.localizedDescription)"
        }
    }

    /// Select a session by its tab index (0-based). Used for Cmd+1-9 shortcuts.
    func selectSessionByIndex(_ index: Int) {
        guard index >= 0, index < activeSessions.count else { return }
        selectSession(activeSessions[index].id)
    }

    func closeTab(sessionId: UUID) {
        // Handle creation session tab
        if sessionId == creationSession?.id {
            endCreationSession()
            return
        }

        // Pane that owns this session (falls back to active for sessions
        // that pre-date the pane refactor or are missing a paneId).
        let owner = paneOwning(sessionId: sessionId) ?? activePaneId

        // Handle shell terminal session (simple cleanup, no history/memory)
        if let session = activeSessions.first(where: { $0.id == sessionId }),
           session.isShellSession {
            if processManager.isRunning(sessionId: sessionId) {
                processManager.stop(sessionId: sessionId)
            }
            processManager.removeProcess(sessionId: sessionId)
            activeSessions.removeAll { $0.id == sessionId }
            advanceSelectionAfterClose(closedSessionId: sessionId, in: owner)
            return
        }

        // Handle chat-mode session
        if let chatManager = chatManagers[sessionId] {
            chatManager.cancel()
            chatManagers.removeValue(forKey: sessionId)

            // Process memories for chat sessions too
            // Memory extraction is handled by onSessionTerminated
            activeSessions.removeAll { $0.id == sessionId }
            advanceSelectionAfterClose(closedSessionId: sessionId, in: owner)
            return
        }

        if processManager.isRunning(sessionId: sessionId) {
            processManager.stop(sessionId: sessionId)
        }

        // Set endedAt immediately. The resumeId will be filled in later by
        // onResumeIdDetected (経路1) once Claude prints the --resume line.
        sessionHistoryService.finalizeSession(
            sessionId: sessionId,
            exitCode: nil,
            resumeId: nil
        )

        // Clean up scheduled session tracking
        scheduleManager.handleSessionTerminated(sessionId: sessionId)

        // Memory extraction is handled by onSessionTerminated callback
        // (fires after the process actually exits, giving us the claudeResumeId for JSONL lookup)

        activeSessions.removeAll { $0.id == sessionId }

        // Hide the terminal view immediately but keep the process entry alive
        // so the processTerminated delegate can fire and capture the resume ID.
        processManager.detachTerminalView(sessionId: sessionId)

        // Deferred cleanup: remove the process entry after giving the
        // delegate time to fire (SIGTERM → Claude prints resume ID → shell exits).
        Task { @MainActor [weak processManager] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            processManager?.removeProcess(sessionId: sessionId)
        }

        advanceSelectionAfterClose(closedSessionId: sessionId, in: paneOwning(sessionId: sessionId) ?? activePaneId)
    }

    /// After closing a session, pick the next session within the same pane and
    /// sync that pane's selectedAgentId to match.
    private func advanceSelectionAfterClose(closedSessionId: UUID, in paneId: PaneID) {
        let remainingInPane = activeSessions.filter { $0.paneId == paneId }
        updatePane(paneId) {
            if $0.selectedSessionId == closedSessionId || $0.selectedSessionId == nil {
                let next = remainingInPane.last
                $0.selectedSessionId = next?.id
                if let next, !next.isCreationSession {
                    $0.selectedAgentId = next.agentId
                } else if next == nil {
                    $0.selectedAgentId = nil
                }
            }
        }
    }

    func renameSession(sessionId: UUID, name: String) {
        guard let index = activeSessions.firstIndex(where: { $0.id == sessionId }) else { return }
        activeSessions[index].customName = name.isEmpty ? nil : name
    }

    // MARK: - Skill Management

    func reloadSkills() {
        let selectedName = skills.first { $0.id == selectedSkillId }?.name
        let previousSkillNames = Set(skills.map { $0.name })

        var loaded: [Skill] = []

        switch projectSelection {
        case .home:
            // Home mode: user skills only — no project skills loaded
            break

        case .project(let project):
            var projectSkills = skillConfigService.loadProjectSkills(projectDir: project.directoryPath)
            for i in projectSkills.indices {
                projectSkills[i].sourceProjectName = project.name
            }
            loaded.append(contentsOf: projectSkills)

        case .all:
            let fm = FileManager.default
            for project in projects {
                guard fm.fileExists(atPath: project.directoryPath.path(percentEncoded: false)) else { continue }
                var projectSkills = skillConfigService.loadProjectSkills(projectDir: project.directoryPath)
                for i in projectSkills.indices {
                    projectSkills[i].sourceProjectName = project.name
                }
                loaded.append(contentsOf: projectSkills)
            }
        }

        loaded.append(contentsOf: skillConfigService.loadUserSkills())
        skills = loaded.sorted { $0.sortOrder == $1.sortOrder ? $0.name < $1.name : $0.sortOrder < $1.sortOrder }

        // Watch any new skill subdirectories (so edits to SKILL.md inside them are detected)
        for skill in skills {
            if let skillDir = skill.skillDirectory {
                fileWatcher.watch(directory: skillDir)
            }
        }

        // Detect new skills created during AI skill creation session
        if let session = creationSession, session.isSkillCreation {
            let currentSkillNames = Set(skills.map { $0.name })
            let addedNames = currentSkillNames.subtracting(previousSkillNames)
            if let newName = addedNames.first,
               let newSkill = skills.first(where: { $0.name == newName }) {
                endCreationSession()
                toastMessage = "Skill \"\(newSkill.name)\" created"
                selectSkill(newSkill)
                return
            }
        }

        if let name = selectedName {
            selectedSkillId = skills.first { $0.name == name }?.id
        }
    }

    func createSkill(name: String, description: String, scope: AgentScope, projectDirectory: URL? = nil) {
        let targetDir: URL

        switch scope {
        case .project:
            if let projectDir = projectDirectory {
                targetDir = projectDir.appending(path: ".claude/skills")
            } else if let project = selectedProject {
                targetDir = project.skillsDirectory
            } else {
                errorMessage = "No project directory specified."
                return
            }
        case .user:
            targetDir = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude/skills")
        case .cloud:
            return
        }

        var skill = Skill()
        skill.name = name
        skill.description = description
        skill.scope = scope
        skill.filePath = targetDir.appending(path: "\(name)/SKILL.md")

        do {
            try skillConfigService.saveSkill(skill, to: targetDir, syncToCodex: codexSyncService.isEnabled)
            reloadSkills()
            selectedSkillId = skills.first { $0.name == name }?.id
            selectedAgentId = nil
        } catch {
            errorMessage = "Failed to create skill: \(error.localizedDescription)"
        }
    }

    func saveSkill(_ skill: Skill) {
        do {
            try skillConfigService.saveSkill(skill, syncToCodex: codexSyncService.isEnabled)
            if let index = skills.firstIndex(where: { $0.id == skill.id }) {
                skills[index] = skill
            }
        } catch {
            errorMessage = "Failed to save skill: \(error.localizedDescription)"
        }
    }

    func deleteSkill(_ skill: Skill) {
        if let skillDir = skill.skillDirectory {
            try? FileManager.default.removeItem(at: skillDir)
        }
        skills.removeAll { $0.id == skill.id }
        if selectedSkillId == skill.id {
            selectedSkillId = nil
        }
    }

    func duplicateSkill(_ skill: Skill, to destination: URL? = nil) {
        var copy = skill
        copy.id = UUID()

        var newName = "\(skill.name)-copy"
        var counter = 2
        while skills.contains(where: { $0.name == newName }) {
            newName = "\(skill.name)-copy-\(counter)"
            counter += 1
        }
        copy.name = newName

        let targetDir: URL
        if let destination {
            targetDir = destination
        } else if skill.scope == .project, let project = selectedProject {
            targetDir = project.skillsDirectory
        } else {
            targetDir = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude/skills")
        }
        copy.filePath = targetDir.appending(path: "\(newName)/SKILL.md")

        do {
            try skillConfigService.saveSkill(copy, to: targetDir, syncToCodex: codexSyncService.isEnabled)
            // Copy all bundled files and subdirectories (excluding SKILL.md which was already created)
            if let sourceDir = skill.skillDirectory,
               let destDir = copy.skillDirectory {
                let fm = FileManager.default
                let entries = (try? fm.contentsOfDirectory(at: sourceDir, includingPropertiesForKeys: nil)) ?? []
                for entry in entries {
                    if entry.lastPathComponent == "SKILL.md" { continue }
                    try? fm.copyItem(at: entry, to: destDir.appending(path: entry.lastPathComponent))
                }
            }
            reloadSkills()
            if let newSkill = skills.first(where: { $0.name == newName }) {
                selectSkill(newSkill)
            }
        } catch {
            errorMessage = "Failed to duplicate skill: \(error.localizedDescription)"
        }
    }

    // MARK: - Context Sharing

    /// Shares the terminal content from one session to another via a temporary file.
    func shareContext(from sourceSessionId: UUID, to targetSessionId: UUID) {
        guard let sourceText = processManager.getTerminalText(sessionId: sourceSessionId) else {
            errorMessage = "Could not retrieve text from the source session."
            return
        }

        let sourceName = activeSessions.first { $0.id == sourceSessionId }?.agentName ?? "unknown"

        // Write context to a temp file
        let contextId = UUID().uuidString.prefix(8)
        let filePath = FileManager.default.temporaryDirectory
            .appending(path: "agent-context-\(contextId).md")

        let content = """
        # Conversation with \(sourceName)

        \(sourceText)
        """

        do {
            try content.write(to: filePath, atomically: true, encoding: .utf8)
        } catch {
            errorMessage = "Failed to write context file: \(error.localizedDescription)"
            return
        }

        // Send a prompt to the target session
        let prompt = "Sharing conversation context from \(sourceName). Please read \(filePath.path(percentEncoded: false)) and proceed with your work based on the content."
        processManager.sendInput(sessionId: targetSessionId, text: prompt + "\n")

        // Switch to the target session
        selectedSessionId = targetSessionId
        if let targetSession = activeSessions.first(where: { $0.id == targetSessionId }) {
            selectedAgentId = targetSession.agentId
        }
        centerPane = .terminal
    }

    /// Returns active sessions excluding the given session ID.
    func otherActiveSessions(excluding sessionId: UUID) -> [AgentSession] {
        activeSessions.filter { $0.id != sessionId && !$0.isCreationSession }
    }

    // MARK: - Memory

    private func setupMemoryExtraction() {
        processManager.onSessionTerminated = { [weak self] sessionId, terminalText, agentId in
            guard let self else { return }

            // Finalize session history record
            let process = self.processManager.processes[sessionId]
            let exitCode: Int32? = if case .stopped(let code) = process?.status { code } else { nil }
            print("[ResumeID] onSessionTerminated finalize: resumeId=\(process?.claudeResumeId ?? "nil") for \(sessionId)")
            self.sessionHistoryService.finalizeSession(
                sessionId: sessionId,
                exitCode: exitCode,
                resumeId: process?.claudeResumeId,
                terminalText: terminalText
            )

            // Clean up scheduled session tracking
            self.scheduleManager.handleSessionTerminated(sessionId: sessionId)

            // Clean up creation session when the process ends naturally
            if sessionId == self.creationSession?.id {
                let wasSkillCreation = self.creationSession?.isSkillCreation ?? false
                self.stopSkillCreationPolling()
                self.creationSession = nil
                self.reloadAgents()
                self.reloadSkills()

                // Switch to the created agent's editor view
                if !wasSkillCreation, let agent = self.agents.first(where: { $0.id == self.selectedAgentId }) {
                    self.sidebarTab = .agents
                    self.showAgentEditor(agent)
                }
            }

            // Find the agent for this session.
            // Look up by filePath first — agent.id is regenerated on every reloadAgents(),
            // so matching by ID can fail if a file watcher triggered a reload in between.
            // Note: activeSessions may already be cleared by closeTab() before this callback fires,
            // so we also check sessionHistoryService records as a fallback.
            let session = self.activeSessions.first { $0.id == sessionId }
            let agentFilePath = session?.agentFilePath
                ?? self.sessionHistoryService.records.first(where: { $0.id == sessionId })?.agentFilePath
                ?? self.processManager.processes[sessionId].flatMap { proc in
                    self.agents.first(where: { $0.id == proc.agentId })?.filePath?.path(percentEncoded: false)
                }
            let agent: Agent? = if let path = agentFilePath {
                self.agents.first { $0.filePath?.path(percentEncoded: false) == path }
            } else if let agentId {
                self.agents.first { $0.id == agentId }
            } else {
                nil
            }
            guard let agent, agent.memoryEnabled else { return }

            // Ensure memory directory exists
            if let memoryDir = agent.memoryDirectory {
                try? FileManager.default.createDirectory(at: memoryDir, withIntermediateDirectories: true)
            }

            // Extract memories from session transcript
            let claudeSessionId = process?.claudeResumeId
            let workingDir = agent.effectiveDirectory?.path(percentEncoded: false)

            self.memoryExtractingSessions.insert(sessionId)

            Task {
                defer {
                    Task { @MainActor in
                        self.memoryExtractingSessions.remove(sessionId)
                        self.sessionHistoryService.markMemoryExtracted(sessionId: sessionId)
                    }
                }

                let provider = await MainActor.run { self.memoryExtractionProvider() }

                // Primary: use JSONL transcript (structured, complete)
                if let sid = claudeSessionId,
                   let jsonlPath = MemoryExtractor.resolveTranscriptPath(
                       claudeSessionId: sid, workingDirectory: workingDir) {
                    print("[Memory] onSessionTerminated: using JSONL transcript for \(agent.name) (\(jsonlPath.lastPathComponent)) via \(provider.binaryName)")
                    await self.memoryExtractor.extractFromTranscript(
                        jsonlPath: jsonlPath,
                        agentName: agent.name,
                        agent: agent,
                        provider: provider
                    )
                }
                // Fallback: use terminal text (lossy but always available)
                else if let text = terminalText, !text.isEmpty {
                    print("[Memory] onSessionTerminated: JSONL not found, falling back to terminal text for \(agent.name) via \(provider.binaryName)")
                    await self.memoryExtractor.extractFromTerminalText(
                        terminalText: text,
                        agentName: agent.name,
                        agent: agent,
                        provider: provider
                    )
                } else {
                    print("[Memory] onSessionTerminated: no transcript or terminal text for \(agent.name)")
                }
            }
        }

        // Persist resume ID immediately so it survives app crashes
        processManager.onResumeIdDetected = { [weak self] sessionId, resumeId in
            print("[ResumeID] onResumeIdDetected callback: \(resumeId) for \(sessionId)")
            self?.sessionHistoryService.finalizeSession(
                sessionId: sessionId,
                exitCode: nil,
                resumeId: resumeId
            )
        }
    }

    /// Process memory extraction for sessions that ended without extraction
    /// (e.g., app was quit while sessions were running).
    private func processPendingMemoryExtractions() {
        // Only process sessions that ended within the last 24 hours
        // to avoid processing a huge backlog when memory is first enabled.
        let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
        let pending = sessionHistoryService.records.filter { record in
            record.endedAt != nil
                && record.memoryExtracted != true
                && record.claudeResumeId != nil
                && (record.endedAt ?? .distantPast) > cutoff
        }

        guard !pending.isEmpty else { return }
        print("[Memory] Found \(pending.count) session(s) pending memory extraction")

        for record in pending {
            // Find the agent by filePath
            guard let agentFilePath = record.agentFilePath,
                  let agent = agents.first(where: { $0.filePath?.path(percentEncoded: false) == agentFilePath }),
                  agent.memoryEnabled else {
                // Can't find agent or memory disabled — mark as done to avoid retrying
                sessionHistoryService.markMemoryExtracted(sessionId: record.id)
                continue
            }

            guard let resumeId = record.claudeResumeId else { continue }
            let workingDir = agent.effectiveDirectory?.path(percentEncoded: false)

            // Ensure memory directory exists
            if let memoryDir = agent.memoryDirectory {
                try? FileManager.default.createDirectory(at: memoryDir, withIntermediateDirectories: true)
            }

            let provider = memoryExtractionProvider()
            Task {
                if let jsonlPath = MemoryExtractor.resolveTranscriptPath(
                    claudeSessionId: resumeId, workingDirectory: workingDir) {
                    print("[Memory] Pending extraction: \(agent.name) from \(jsonlPath.lastPathComponent) via \(provider.binaryName)")
                    await memoryExtractor.extractFromTranscript(
                        jsonlPath: jsonlPath,
                        agentName: agent.name,
                        agent: agent,
                        provider: provider
                    )
                } else {
                    print("[Memory] Pending extraction: JSONL not found for \(agent.name) (resumeId: \(resumeId))")
                }
                await MainActor.run {
                    sessionHistoryService.markMemoryExtracted(sessionId: record.id)
                }
            }
        }
    }

    /// Load memories for the selected agent (for inspector display).
    func loadMemories(for agent: Agent) -> [AgentMemory] {
        memoryService.loadMemories(for: agent)
    }

    /// Delete a memory and refresh.
    func deleteMemory(_ memory: AgentMemory, for agent: Agent) {
        try? memoryService.deleteMemory(memory, for: agent)
        try? memoryService.rebuildIndex(for: agent)
    }

    /// Update a memory and refresh.
    func updateMemory(_ memory: AgentMemory, for agent: Agent) {
        try? memoryService.updateMemory(memory, for: agent)
        try? memoryService.rebuildIndex(for: agent)
    }

    // MARK: - Scheduling

    private func setupScheduleManager() {
        let projectPaths = projects.map { $0.directoryPath.path(percentEncoded: false) }

        // Wire execute callback: finds agent by filePath (or name as fallback), starts session
        scheduleManager.onExecute = { [weak self] agentName, agentFilePath, prompt, scheduleId in
            guard let self else { return nil }
            let agent: Agent?
            if let agentFilePath {
                agent = self.agents.first(where: { $0.filePath?.path(percentEncoded: false) == agentFilePath })
            } else {
                agent = self.agents.first(where: { $0.name == agentName })
            }
            guard let agent else { return nil }
            guard agent.effectiveDirectory != nil else { return nil }

            var memoryContext: String? = nil
            if agent.memoryEnabled {
                memoryContext = self.memoryService.buildMemoryContext(for: agent)
                if let memoryDir = agent.memoryDirectory {
                    try? FileManager.default.createDirectory(at: memoryDir, withIntermediateDirectories: true)
                    self.fileWatcher.watch(directory: memoryDir)
                }
            }

            // Resolve memory DB path for MCP recall_memory
            let memoryDbPath = self.memoryDatabaseManager.databasePath(for: agent)

            do {
                let sessionId = try self.processManager.start(agent: agent, memoryContext: memoryContext, memoryDbPath: memoryDbPath)
                let agentPath = agent.filePath?.path(percentEncoded: false)
                let session = AgentSession(
                    id: sessionId, agentId: agent.id, agentName: agent.name,
                    agentFilePath: agentPath,
                    isScheduledSession: true, scheduleId: scheduleId,
                    workingDirectory: agent.effectiveDirectory)
                self.activeSessions.append(session)
                self.sessionHistoryService.recordSessionStart(session: session)
                return sessionId
            } catch {
                return nil
            }
        }

        // Wire prompt delivery
        scheduleManager.onSendPrompt = { [weak self] sessionId, prompt in
            self?.processManager.sendInput(sessionId: sessionId, text: prompt)
            self?.processManager.notifyPromptSubmitted(sessionId: sessionId, promptText: prompt)
            self?.sessionHistoryService.setInitialPrompt(sessionId: sessionId, prompt: prompt)
        }

        // Wire idle detection → prompt delivery
        processManager.onStatusChanged = { [weak self] sessionId, status in
            if status == .waitingForInput {
                self?.scheduleManager.handleSessionBecameIdle(sessionId: sessionId)
            }
        }

        scheduleManager.start(projectPaths: projectPaths)

        // Catch-up missed schedules after a brief delay (agents need to load first)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.scheduleManager.executeMissedSchedules()
        }
    }

    // MARK: - Git

    /// Refreshes git status (lightweight: branch name, ahead/behind, dirty flag).
    func refreshGitStatus() {
        guard case .project(let project) = projectSelection else {
            isGitRepository = false
            gitStatus = nil
            gitBranches = []
            return
        }

        let path = project.directoryPath
        let service = gitService

        Task { @MainActor in
            let isRepo = service.isGitRepository(at: path)
            self.isGitRepository = isRepo
            guard isRepo else {
                self.gitStatus = nil
                self.gitBranches = []
                return
            }
            self.gitStatus = await service.getStatus(at: path)
        }
    }

    /// Fetches the full branch list. Called when the branch popover opens.
    func refreshGitBranches() {
        guard case .project(let project) = projectSelection, isGitRepository else { return }
        let path = project.directoryPath
        let service = gitService
        Task { @MainActor in
            self.gitBranches = await service.listBranches(at: path)
        }
    }

    /// Sets up .git/HEAD file watching for the current project.
    /// Detects external branch switches (other terminals, VSCode, etc.).
    func setupGitHeadWatcher() {
        gitHeadWatcher.stopAll()

        guard case .project(let project) = projectSelection else { return }

        let gitHeadPath = project.directoryPath.appending(path: ".git")
        let fm = FileManager.default
        guard fm.fileExists(atPath: gitHeadPath.path(percentEncoded: false)) else { return }

        gitHeadWatcher.onChange = { [weak self] in
            self?.refreshGitStatus()
            // Also reload agents since .claude/agents/*.md may differ per branch
            self?.reloadAgents()
            self?.reloadSkills()
            self?.loadFileTree()
        }
        gitHeadWatcher.watch(directory: gitHeadPath)
    }

    /// Switches to the specified branch and reloads agents/files.
    func switchGitBranch(to branchName: String) async throws {
        guard case .project(let project) = projectSelection else { return }

        try await gitService.switchBranch(to: branchName, at: project.directoryPath)

        // Reload everything since branch content may differ
        reloadAgents()
        reloadSkills()
        loadFileTree()
        refreshGitStatus()
    }

    /// Creates a new branch and switches to it.
    func createGitBranch(name: String) async throws {
        guard case .project(let project) = projectSelection else { return }

        try await gitService.createBranch(name: name, at: project.directoryPath)
        reloadAgents()
        reloadSkills()
        loadFileTree()
        refreshGitStatus()
    }

    /// Checks out a remote branch as a local tracking branch.
    func checkoutRemoteGitBranch(_ remoteBranch: String, localName: String) async throws {
        guard case .project(let project) = projectSelection else { return }

        try await gitService.checkoutRemoteBranch(remoteBranch, localName: localName, at: project.directoryPath)
        reloadAgents()
        reloadSkills()
        loadFileTree()
        refreshGitStatus()
    }

    /// Refreshes the list of changed files for the commit popover.
    func refreshGitChangedFiles() {
        guard case .project(let project) = projectSelection, isGitRepository else {
            gitChangedFiles = []
            return
        }
        let path = project.directoryPath
        let service = gitService
        Task { @MainActor in
            self.gitChangedFiles = service.getChangedFiles(at: path)
        }
    }

    /// Commits all changes with the given message.
    func gitCommitAll(message: String) async throws {
        guard case .project(let project) = projectSelection else { return }
        isGitOperationInProgress = true
        defer { isGitOperationInProgress = false }

        let service = gitService
        let path = project.directoryPath
        try await Task.detached {
            try await service.commitAll(message: message, at: path)
        }.value
        lastGitError = nil
        refreshGitStatus()
        refreshGitChangedFiles()
        loadFileTree()
    }

    /// Pushes the current branch to origin.
    func gitPush() async throws {
        guard case .project(let project) = projectSelection else { return }
        isGitOperationInProgress = true
        defer { isGitOperationInProgress = false }

        let service = gitService
        let path = project.directoryPath
        let branch = gitStatus?.currentBranch
        try await Task.detached {
            try await service.push(at: path, branch: branch)
        }.value
        lastGitError = nil
        refreshGitStatus()
    }

    /// Pulls from remote for the current branch.
    func gitPull() async throws {
        guard case .project(let project) = projectSelection else { return }
        isGitOperationInProgress = true
        defer { isGitOperationInProgress = false }

        let service = gitService
        let path = project.directoryPath
        try await Task.detached {
            try await service.pull(at: path)
        }.value
        lastGitError = nil
        refreshGitStatus()
        reloadAgents()
        reloadSkills()
        loadFileTree()
    }

    /// Generates a commit message using the configured background provider (claude -p or codex exec).
    func generateCommitMessage() async throws -> String {
        guard case .project(let project) = projectSelection else {
            throw AICommitMessageGenerator.GeneratorError.claudeNotFound
        }
        let provider = commitMessageProvider()
        guard let cliPath = processManager.cliPathResolver.resolve(for: provider) else {
            throw AICommitMessageGenerator.GeneratorError.cliNotFound(provider)
        }

        let service = gitService
        let path = project.directoryPath
        let diffSummary = await Task.detached {
            service.getDiffSummary(at: path)
        }.value
        return try await AICommitMessageGenerator.generate(
            cliPath: cliPath,
            provider: provider,
            diffSummary: diffSummary
        )
    }

    // MARK: - Open File Watching

    private func setupOpenFileWatcher() {
        openFileWatcher.onFileChanged = { [weak self] fileId in
            self?.handleOpenFileChanged(fileId: fileId)
        }
    }

    private func handleOpenFileChanged(fileId: UUID) {
        guard let index = openFiles.firstIndex(where: { $0.id == fileId }) else { return }
        let file = openFiles[index]

        guard let data = try? Data(contentsOf: file.url),
              let diskContent = String(data: data, encoding: .utf8) else { return }

        // No actual change in content
        if diskContent == file.content { return }

        if file.hasChanges {
            // User has unsaved edits — ask before overwriting
            fileConflictFileId = fileId
        } else {
            // No local edits — silently reload
            openFiles[index].content = diskContent
        }
    }

    /// Reload an open file from disk, discarding local edits.
    func reloadFileFromDisk(fileId: UUID) {
        guard let index = openFiles.firstIndex(where: { $0.id == fileId }) else { return }
        let file = openFiles[index]
        guard let data = try? Data(contentsOf: file.url),
              let content = String(data: data, encoding: .utf8) else { return }
        openFiles[index].content = content
        openFiles[index].hasChanges = false
    }

    // MARK: - File Watching

    private func setupFileWatcher() {
        fileWatcher.stopAll()

        fileWatcher.onChange = { [weak self] in
            guard let self else { return }
            self.reloadAgents()
            self.reloadSkills()

            // Register watchers for directories that may have been newly created by CLI
            // (e.g., `claude code` creating .claude/agents/ for the first time).
            // FileWatcherService.watch() deduplicates, so already-watched dirs are a no-op.
            self.registerWatchDirectories()
        }

        registerWatchDirectories()
    }

    /// Register file watchers for agent/skill/memory directories.
    /// Safe to call multiple times — `FileWatcherService.watch()` deduplicates by path.
    private func registerWatchDirectories() {
        switch projectSelection {
        case .home:
            // Home mode: only watch user directories (handled below)
            break

        case .project(let project):
            // Watch .claude/ parent so we detect when agents/ or skills/ dirs are first created
            fileWatcher.watch(directory: project.directoryPath.appending(path: ".claude"))
            fileWatcher.watch(directory: project.agentsDirectory)
            fileWatcher.watch(directory: project.skillsDirectory)
            // Codex skills path (.agents/skills/)
            fileWatcher.watch(directory: project.codexSkillsDirectory)

        case .all:
            for project in projects {
                fileWatcher.watch(directory: project.directoryPath.appending(path: ".claude"))
                fileWatcher.watch(directory: project.agentsDirectory)
                fileWatcher.watch(directory: project.skillsDirectory)
                fileWatcher.watch(directory: project.codexSkillsDirectory)
            }
        }

        let home = FileManager.default.homeDirectoryForCurrentUser
        fileWatcher.watch(directory: home.appending(path: ".claude"))
        fileWatcher.watch(directory: home.appending(path: ".claude/agents"))
        fileWatcher.watch(directory: home.appending(path: ".claude/skills"))
        // Codex user-scope skill paths
        fileWatcher.watch(directory: home.appending(path: ".codex/skills"))
        fileWatcher.watch(directory: home.appending(path: ".agents/skills"))

        // Watch individual skill subdirectories (SKILL.md edits won't trigger parent watch)
        for skill in skills {
            if let skillDir = skill.skillDirectory {
                fileWatcher.watch(directory: skillDir)
            }
        }

        // Watch memory directories for inbox changes
        for agent in agents where agent.memoryEnabled {
            if let memoryDir = agent.memoryDirectory {
                let fm = FileManager.default
                if fm.fileExists(atPath: memoryDir.path(percentEncoded: false)) {
                    fileWatcher.watch(directory: memoryDir)
                }
            }
        }
    }

    // MARK: - Persistence

    private var recentProjectsURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = appSupport.appending(path: "Conclawd")
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        return appDir.appending(path: "recent_projects.json")
    }

    private func loadRecentProjects() {
        guard let data = try? Data(contentsOf: recentProjectsURL),
              let loaded = try? JSONDecoder().decode([Project].self, from: data) else {
            return
        }
        projects = loaded
    }

    private func saveRecentProjects() {
        guard let data = try? JSONEncoder().encode(projects) else { return }
        try? data.write(to: recentProjectsURL)
    }
}
