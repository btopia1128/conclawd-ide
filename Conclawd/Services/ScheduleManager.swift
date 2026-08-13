import Foundation

/// Manages scheduled agent executions: persistence, timer-driven checks, and prompt delivery.
@Observable
@MainActor
final class ScheduleManager {

    // MARK: - Properties

    /// All loaded schedules (both project and user scoped).
    private(set) var schedules: [AgentSchedule] = []

    /// Execution history (most recent first, capped at 100).
    private(set) var executionHistory: [ScheduleExecution] = []

    /// Session IDs spawned by schedules. Maps scheduleId -> set of active sessionIds.
    private(set) var scheduledSessionIds: [UUID: Set<UUID>] = [:]

    /// Sessions waiting for their first waitingForInput to send the prompt.
    /// Maps sessionId -> (prompt, scheduleId).
    private(set) var pendingPrompts: [UUID: (prompt: String, scheduleId: UUID)] = [:]

    /// 60-second timer to check if any schedule is due.
    private var checkTimer: Timer?

    // MARK: - Callbacks (wired by AppState)

    /// Called to start an agent session. Returns sessionId on success.
    /// Parameters: (agentName, agentFilePath, prompt, scheduleId) -> sessionId?
    var onExecute: ((_ agentName: String, _ agentFilePath: String?, _ prompt: String, _ scheduleId: UUID) -> UUID?)?

    /// Called to send a prompt to a session.
    /// Parameters: (sessionId, prompt)
    var onSendPrompt: ((UUID, String) -> Void)?

    // MARK: - Persistence Paths

    private var userSchedulesURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".claude/schedules.json")
    }

    private func projectSchedulesURL(for projectPath: String) -> URL {
        URL(filePath: projectPath).appending(path: ".claude/schedules.json")
    }

    private var historyURL: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = appSupport.appending(path: "Conclawd")
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        return appDir.appending(path: "schedule_history.json")
    }

    // MARK: - Lifecycle

    /// Load schedules and start the check timer.
    func start(projectPaths: [String]) {
        loadSchedules(projectPaths: projectPaths)
        loadHistory()
        startCheckTimer()
    }

    func stop() {
        checkTimer?.invalidate()
        checkTimer = nil
    }

    // MARK: - CRUD

    func addSchedule(_ schedule: AgentSchedule) {
        schedules.append(schedule)
        saveToDisk(schedule)
    }

    func updateSchedule(_ schedule: AgentSchedule) {
        guard let index = schedules.firstIndex(where: { $0.id == schedule.id }) else { return }
        let old = schedules[index]
        // If scope/project changed, remove from old file
        if old.scope != schedule.scope || old.projectPath != schedule.projectPath {
            removeFromDisk(old)
        }
        schedules[index] = schedule
        saveToDisk(schedule)
    }

    func deleteSchedule(_ schedule: AgentSchedule) {
        schedules.removeAll { $0.id == schedule.id }
        scheduledSessionIds.removeValue(forKey: schedule.id)
        removeFromDisk(schedule)
    }

    /// Move a schedule from one position to another within the array and persist.
    func moveSchedule(fromId: UUID, toId: UUID) {
        guard let fromIndex = schedules.firstIndex(where: { $0.id == fromId }),
              let toIndex = schedules.firstIndex(where: { $0.id == toId }),
              fromIndex != toIndex else { return }
        let item = schedules.remove(at: fromIndex)
        let insertAt = schedules.firstIndex(where: { $0.id == toId }) ?? schedules.endIndex
        schedules.insert(item, at: insertAt)
        saveAllToDisk()
    }

    func schedulesForAgent(name: String) -> [AgentSchedule] {
        schedules.filter { $0.agentName == name }
    }

    /// Manually trigger a schedule immediately.
    func runNow(_ schedule: AgentSchedule) {
        guard let index = schedules.firstIndex(where: { $0.id == schedule.id }) else { return }
        executeSchedule(&schedules[index], now: Date(), isCatchUp: false)
    }

    // MARK: - Timer

    private func startCheckTimer() {
        guard checkTimer == nil else { return }
        checkTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkSchedules()
            }
        }
        // Immediate check
        checkSchedules()
    }

    /// Called every 60 seconds. Checks each enabled schedule to see if it's due.
    private func checkSchedules() {
        let now = Date()
        for i in schedules.indices where schedules[i].isEnabled {
            if shouldExecute(schedule: schedules[i], now: now) {
                executeSchedule(&schedules[i], now: now, isCatchUp: false)
            }
        }
    }

    /// Determines if a schedule is due to fire.
    func shouldExecute(schedule: AgentSchedule, now: Date) -> Bool {
        let calendar = Calendar.current

        switch schedule.scheduleType {
        case .interval(let minutes):
            guard let lastExec = schedule.lastExecutedAt else { return true }
            return now.timeIntervalSince(lastExec) >= Double(minutes * 60)

        case .daily(let hour, let minute):
            guard let scheduledToday = calendar.date(
                bySettingHour: hour, minute: minute, second: 0, of: now) else { return false }
            guard let lastExec = schedule.lastExecutedAt else {
                return now >= scheduledToday
            }
            return now >= scheduledToday
                && !calendar.isDate(lastExec, inSameDayAs: now)

        case .weekly(let weekday, let hour, let minute):
            let currentWeekday = calendar.component(.weekday, from: now)
            guard currentWeekday == weekday else { return false }
            guard let scheduledToday = calendar.date(
                bySettingHour: hour, minute: minute, second: 0, of: now) else { return false }
            guard let lastExec = schedule.lastExecutedAt else {
                return now >= scheduledToday
            }
            return now >= scheduledToday
                && !calendar.isDate(lastExec, inSameDayAs: now)
        }
    }

    /// Execute a schedule: start a session and register it for prompt delivery.
    private func executeSchedule(_ schedule: inout AgentSchedule, now: Date, isCatchUp: Bool) {
        // Check concurrency limit
        let activeCount = scheduledSessionIds[schedule.id]?.count ?? 0
        if activeCount >= schedule.maxConcurrentSessions {
            recordExecution(
                scheduleId: schedule.id, agentName: schedule.agentName,
                status: .skipped, error: "Concurrency limit reached", isCatchUp: isCatchUp)
            return
        }

        // Ask AppState to start the session
        guard let sessionId = onExecute?(schedule.agentName, schedule.agentFilePath, schedule.prompt, schedule.id) else {
            schedule.lastError = "Failed to start session"
            recordExecution(
                scheduleId: schedule.id, agentName: schedule.agentName,
                status: .failed, error: schedule.lastError, isCatchUp: isCatchUp)
            saveToDisk(schedule)
            return
        }

        // Register the session for prompt delivery
        pendingPrompts[sessionId] = (prompt: schedule.prompt, scheduleId: schedule.id)
        scheduledSessionIds[schedule.id, default: []].insert(sessionId)

        schedule.lastExecutedAt = now
        schedule.lastError = nil
        saveToDisk(schedule)

        recordExecution(
            scheduleId: schedule.id, agentName: schedule.agentName,
            status: .success, sessionId: sessionId, isCatchUp: isCatchUp)
    }

    // MARK: - Prompt Delivery

    /// Called when a session transitions to waitingForInput.
    /// If this is a scheduled session's first idle, sends the prompt.
    func handleSessionBecameIdle(sessionId: UUID) {
        guard let pending = pendingPrompts.removeValue(forKey: sessionId) else { return }
        // Use \r (carriage return) instead of \n — Claude CLI runs in raw terminal mode,
        // so it expects \r (what the Enter key physically sends) to submit input.
        onSendPrompt?(sessionId, pending.prompt + "\r")
    }

    /// Called when a session terminates. Cleans up tracking.
    func handleSessionTerminated(sessionId: UUID) {
        pendingPrompts.removeValue(forKey: sessionId)
        for scheduleId in scheduledSessionIds.keys {
            scheduledSessionIds[scheduleId]?.remove(sessionId)
        }
    }

    // MARK: - Catch-Up

    /// Called at app launch to execute missed schedules (once each).
    func executeMissedSchedules() {
        let now = Date()
        for i in schedules.indices where schedules[i].isEnabled {
            if shouldExecute(schedule: schedules[i], now: now) {
                executeSchedule(&schedules[i], now: now, isCatchUp: true)
            }
        }
    }

    // MARK: - Persistence

    private func loadSchedules(projectPaths: [String]) {
        var loaded: [AgentSchedule] = []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        // Load user schedules
        if let data = try? Data(contentsOf: userSchedulesURL),
           let items = try? decoder.decode([AgentSchedule].self, from: data) {
            loaded.append(contentsOf: items)
        }

        // Load project schedules
        for path in projectPaths {
            let url = projectSchedulesURL(for: path)
            if let data = try? Data(contentsOf: url),
               let items = try? decoder.decode([AgentSchedule].self, from: data) {
                loaded.append(contentsOf: items)
            }
        }

        schedules = loaded
    }

    private func saveToDisk(_ schedule: AgentSchedule) {
        let url: URL
        switch schedule.scope {
        case .user:
            url = userSchedulesURL
        case .project:
            guard let projectPath = schedule.projectPath else { return }
            url = projectSchedulesURL(for: projectPath)
        case .cloud:
            return // Cloud schedules are persisted via API, not locally
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        var existing: [AgentSchedule] = []
        if let data = try? Data(contentsOf: url),
           let items = try? decoder.decode([AgentSchedule].self, from: data) {
            existing = items
        }

        if let index = existing.firstIndex(where: { $0.id == schedule.id }) {
            existing[index] = schedule
        } else {
            existing.append(schedule)
        }

        if let data = try? encoder.encode(existing) {
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url)
        }
    }

    private func removeFromDisk(_ schedule: AgentSchedule) {
        let url: URL
        switch schedule.scope {
        case .user:
            url = userSchedulesURL
        case .project:
            guard let projectPath = schedule.projectPath else { return }
            url = projectSchedulesURL(for: projectPath)
        case .cloud:
            return // Cloud schedules are managed via API
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        guard let data = try? Data(contentsOf: url),
              var existing = try? decoder.decode([AgentSchedule].self, from: data) else { return }
        existing.removeAll { $0.id == schedule.id }
        if let newData = try? encoder.encode(existing) {
            try? newData.write(to: url)
        }
    }

    /// Save all schedules to their respective disk files (used after reordering).
    private func saveAllToDisk() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        // Group by destination file
        var userSchedules: [AgentSchedule] = []
        var projectSchedules: [String: [AgentSchedule]] = [:]

        for schedule in schedules {
            switch schedule.scope {
            case .user:
                userSchedules.append(schedule)
            case .project:
                if let path = schedule.projectPath {
                    projectSchedules[path, default: []].append(schedule)
                }
            case .cloud:
                break // Cloud schedules are managed via API
            }
        }

        // Save user schedules
        if let data = try? encoder.encode(userSchedules) {
            try? FileManager.default.createDirectory(
                at: userSchedulesURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: userSchedulesURL)
        }

        // Save project schedules
        for (path, items) in projectSchedules {
            let url = projectSchedulesURL(for: path)
            if let data = try? encoder.encode(items) {
                try? FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: url)
            }
        }
    }

    // MARK: - History

    private func recordExecution(
        scheduleId: UUID, agentName: String,
        status: ScheduleExecution.ExecutionStatus,
        sessionId: UUID? = nil, error: String? = nil, isCatchUp: Bool
    ) {
        let exec = ScheduleExecution(
            scheduleId: scheduleId, agentName: agentName,
            executedAt: Date(), sessionId: sessionId,
            status: status, errorMessage: error, isCatchUp: isCatchUp)
        executionHistory.insert(exec, at: 0)
        if executionHistory.count > 100 {
            executionHistory = Array(executionHistory.prefix(100))
        }
        saveHistory()
    }

    private func loadHistory() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: historyURL),
              let items = try? decoder.decode([ScheduleExecution].self, from: data) else { return }
        executionHistory = items
    }

    private func saveHistory() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(executionHistory) {
            try? data.write(to: historyURL)
        }
    }
}
