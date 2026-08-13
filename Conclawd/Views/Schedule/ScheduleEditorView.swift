import SwiftUI

/// Center pane editor for the selected schedule's details.
struct ScheduleEditorView: View {
    @Environment(AppState.self) private var appState

    // Editable state for details
    @State private var editingMaxConcurrent: Int = 3
    @State private var editingScheduleKind: NewScheduleSheet.ScheduleKind = .interval
    @State private var editingIntervalMinutes: Int = 30
    @State private var editingDailyHour: Int = 9
    @State private var editingDailyMinute: Int = 0
    @State private var editingWeeklyWeekday: Int = 2
    @State private var editingWeeklyHour: Int = 9
    @State private var editingWeeklyMinute: Int = 0

    // Editable state for prompt
    @State private var editingPrompt: String = ""
    @State private var lastSyncedScheduleId: UUID?
    @State private var isSaving = false

    private var schedule: AgentSchedule? {
        appState.editingSchedule
    }

    private var agent: Agent? {
        guard let schedule else { return nil }
        return appState.agents.first { $0.name == schedule.agentName }
    }

    private var activeSessionCount: Int {
        guard let schedule else { return 0 }
        return appState.scheduleManager.scheduledSessionIds[schedule.id]?.count ?? 0
    }

    private var executionHistory: [ScheduleExecution] {
        guard let schedule else { return [] }
        return appState.scheduleManager.executionHistory.filter { $0.scheduleId == schedule.id }
    }

    private var resolvedScheduleType: ScheduleType {
        switch editingScheduleKind {
        case .interval: return .interval(minutes: editingIntervalMinutes)
        case .daily: return .daily(hour: editingDailyHour, minute: editingDailyMinute)
        case .weekly: return .weekly(weekday: editingWeeklyWeekday, hour: editingWeeklyHour, minute: editingWeeklyMinute)
        }
    }

    var body: some View {
        if appState.editingCloudTrigger != nil {
            CloudTriggerEditorView()
        } else if let schedule {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        headerSection(schedule)
                        detailsSection(schedule)
                        promptSection(schedule)
                        historySection
                    }
                    .padding(24)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                bottomBar
            }
            .themedBackground(Color.appWindowBackground)
            .onChange(of: schedule.id) { _, newId in
                syncEditingState(from: schedule)
            }
            .onAppear {
                syncEditingState(from: schedule)
            }
        } else {
            emptyState
        }
    }

    /// Sync local editing state from the schedule model.
    private func syncEditingState(from schedule: AgentSchedule) {
        guard schedule.id != lastSyncedScheduleId else { return }
        lastSyncedScheduleId = schedule.id
        editingPrompt = schedule.prompt
        editingMaxConcurrent = schedule.maxConcurrentSessions
        switch schedule.scheduleType {
        case .interval(let minutes):
            editingScheduleKind = .interval
            editingIntervalMinutes = minutes
        case .daily(let hour, let minute):
            editingScheduleKind = .daily
            editingDailyHour = hour
            editingDailyMinute = minute
        case .weekly(let weekday, let hour, let minute):
            editingScheduleKind = .weekly
            editingWeeklyWeekday = weekday
            editingWeeklyHour = hour
            editingWeeklyMinute = minute
        }
    }

    /// Persist current editing state back to the schedule.
    private func saveChanges() {
        guard !isSaving else { return }
        guard var updated = appState.editingSchedule else { return }
        updated.prompt = editingPrompt
        updated.maxConcurrentSessions = editingMaxConcurrent
        updated.scheduleType = resolvedScheduleType
        isSaving = true
        appState.scheduleManager.updateSchedule(updated)
        appState.editingSchedule = updated
        isSaving = false
    }

    // MARK: - Header

    private func headerSection(_ schedule: AgentSchedule) -> some View {
        HStack(spacing: 12) {
            // Agent color bar
            RoundedRectangle(cornerRadius: 3)
                .fill(agent?.color.swiftUIColor ?? .gray)
                .frame(width: 4, height: 40)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(schedule.agentName)
                        .font(.title2.bold())

                    if schedule.isEnabled {
                        Label("Enabled", systemImage: "checkmark.circle.fill")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.green)
                    } else {
                        Label("Disabled", systemImage: "pause.circle.fill")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color.appSecondary)
                    }

                    if activeSessionCount > 0 {
                        Label("\(activeSessionCount) active", systemImage: "bolt.fill")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.orange)
                    }
                }

                HStack(spacing: 6) {
                    Image(systemName: schedule.scheduleType.icon)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.appSecondary)
                    Text(schedule.scheduleType.displayName)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.appSecondary)
                }
            }

            Spacer()

            HStack(spacing: 8) {
                Button {
                    appState.scheduleManager.runNow(schedule)
                } label: {
                    Label("Run Now", systemImage: "play.fill")
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)

                Button {
                    guard var updated = appState.editingSchedule else { return }
                    updated.isEnabled.toggle()
                    appState.scheduleManager.updateSchedule(updated)
                    appState.editingSchedule = updated
                } label: {
                    Label(
                        schedule.isEnabled ? "Disable" : "Enable",
                        systemImage: schedule.isEnabled ? "pause.fill" : "play.fill"
                    )
                }
                .controlSize(.small)
            }
        }
    }

    // MARK: - Details

    private func detailsSection(_ schedule: AgentSchedule) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Details")
                .font(.headline)

            VStack(alignment: .leading, spacing: 12) {
                // Schedule Type (editable)
                detailRow("Schedule Type") {
                    Picker("", selection: $editingScheduleKind) {
                        ForEach(NewScheduleSheet.ScheduleKind.allCases, id: \.self) { kind in
                            Text(kind.rawValue).tag(kind)
                        }
                    }
                    .labelsHidden()
                    .controlSize(.small)
                    .onChange(of: editingScheduleKind) { _, _ in saveChanges() }
                }

                // Schedule parameters
                switch editingScheduleKind {
                case .interval:
                    detailRow("Interval") {
                        Picker("", selection: $editingIntervalMinutes) {
                            Text("1 min").tag(1)
                            Text("5 min").tag(5)
                            Text("10 min").tag(10)
                            Text("15 min").tag(15)
                            Text("30 min").tag(30)
                            Text("1 hour").tag(60)
                            Text("2 hours").tag(120)
                            Text("4 hours").tag(240)
                            Text("8 hours").tag(480)
                            Text("12 hours").tag(720)
                            Text("24 hours").tag(1440)
                        }
                        .labelsHidden()
                        .controlSize(.small)
                        .onChange(of: editingIntervalMinutes) { _, _ in saveChanges() }
                    }

                case .daily:
                    detailRow("Time") {
                        HStack(spacing: 4) {
                            Picker("", selection: $editingDailyHour) {
                                ForEach(0..<24, id: \.self) { h in
                                    Text(String(format: "%02d", h)).tag(h)
                                }
                            }
                            .labelsHidden()
                            .controlSize(.small)
                            .frame(width: 60)

                            Text(":")

                            Picker("", selection: $editingDailyMinute) {
                                ForEach([0, 15, 30, 45], id: \.self) { m in
                                    Text(String(format: "%02d", m)).tag(m)
                                }
                            }
                            .labelsHidden()
                            .controlSize(.small)
                            .frame(width: 60)
                        }
                        .onChange(of: editingDailyHour) { _, _ in saveChanges() }
                        .onChange(of: editingDailyMinute) { _, _ in saveChanges() }
                    }

                case .weekly:
                    detailRow("Day") {
                        Picker("", selection: $editingWeeklyWeekday) {
                            Text("Sunday").tag(1)
                            Text("Monday").tag(2)
                            Text("Tuesday").tag(3)
                            Text("Wednesday").tag(4)
                            Text("Thursday").tag(5)
                            Text("Friday").tag(6)
                            Text("Saturday").tag(7)
                        }
                        .labelsHidden()
                        .controlSize(.small)
                        .onChange(of: editingWeeklyWeekday) { _, _ in saveChanges() }
                    }

                    detailRow("Time") {
                        HStack(spacing: 4) {
                            Picker("", selection: $editingWeeklyHour) {
                                ForEach(0..<24, id: \.self) { h in
                                    Text(String(format: "%02d", h)).tag(h)
                                }
                            }
                            .labelsHidden()
                            .controlSize(.small)
                            .frame(width: 60)

                            Text(":")

                            Picker("", selection: $editingWeeklyMinute) {
                                ForEach([0, 15, 30, 45], id: \.self) { m in
                                    Text(String(format: "%02d", m)).tag(m)
                                }
                            }
                            .labelsHidden()
                            .controlSize(.small)
                            .frame(width: 60)
                        }
                        .onChange(of: editingWeeklyHour) { _, _ in saveChanges() }
                        .onChange(of: editingWeeklyMinute) { _, _ in saveChanges() }
                    }
                }

                Divider()

                // Scope (editable)
                detailRow("Scope") {
                    Picker("", selection: Binding(
                        get: { schedule.scope },
                        set: { newScope in
                            guard var updated = appState.editingSchedule else { return }
                            updated.scope = newScope
                            if newScope == .user {
                                updated.projectPath = nil
                            } else if updated.projectPath == nil {
                                updated.projectPath = appState.selectedProject?.directoryPath.path(percentEncoded: false)
                            }
                            appState.scheduleManager.updateSchedule(updated)
                            appState.editingSchedule = updated
                        }
                    )) {
                        Text("User (Global)").tag(AgentScope.user)
                        Text("Project").tag(AgentScope.project)
                    }
                    .labelsHidden()
                    .controlSize(.small)
                }

                if let projectPath = schedule.projectPath {
                    detailRow("Project Path") {
                        Text(projectPath)
                            .font(.system(size: 11, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                }

                // Max Concurrent (editable)
                detailRow("Max Concurrent") {
                    Stepper("\(editingMaxConcurrent)", value: $editingMaxConcurrent, in: 1...10)
                        .font(.system(size: 12))
                        .onChange(of: editingMaxConcurrent) { _, _ in saveChanges() }
                }

                if let lastExec = schedule.lastExecutedAt {
                    detailRow("Last Executed") {
                        Text(Self.lastExecutedFormatter.string(from: lastExec))
                            .font(.system(size: 12))
                            .foregroundStyle(Color.appSecondary)
                    }
                }

                if let lastError = schedule.lastError {
                    detailRow("Last Error") {
                        Text(lastError)
                            .font(.system(size: 12))
                            .foregroundStyle(.red)
                    }
                }
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 8).fill(.fill.quinary))
    }

    private func detailRow<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .center, spacing: 0) {
            Text(label)
                .foregroundStyle(Color.appSecondary)
                .font(.system(size: 12))
                .frame(width: 140, alignment: .leading)
            content()
        }
    }

    // MARK: - Prompt

    private func promptSection(_ schedule: AgentSchedule) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Instructions")
                .font(.headline)

            TextEditor(text: $editingPrompt)
                .font(.system(size: 12, design: .monospaced))
                .frame(maxWidth: .infinity, minHeight: 80)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(.fill.quinary))
                .filePathDrop(text: $editingPrompt)
                .onChange(of: editingPrompt) { _, _ in
                    saveChanges()
                }
        }
    }

    // MARK: - Execution History

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Execution History")
                .font(.headline)

            if executionHistory.isEmpty {
                Text("No executions yet")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.appTertiary)
                    .padding(12)
            } else {
                VStack(spacing: 0) {
                    ForEach(executionHistory.prefix(20)) { execution in
                        executionRow(execution)
                        if execution.id != executionHistory.prefix(20).last?.id {
                            Divider()
                        }
                    }
                }
                .background(RoundedRectangle(cornerRadius: 8).fill(.fill.quinary))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private static let lastExecutedFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    private static let executionDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    private func executionRow(_ execution: ScheduleExecution) -> some View {
        HStack(spacing: 8) {
            Image(systemName: executionStatusIcon(execution.status))
                .font(.system(size: 10))
                .foregroundStyle(executionStatusColor(execution.status))
                .frame(width: 16)

            Text(Self.executionDateFormatter.string(from: execution.executedAt))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color.appSecondary)

            if execution.isCatchUp {
                Text("catch-up")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Color.appSecondary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 3).fill(.fill.tertiary))
            }

            Spacer()

            if let error = execution.errorMessage {
                Text(error)
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
                    .lineLimit(1)
            }

            Text(execution.status.rawValue)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(executionStatusColor(execution.status))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func executionStatusIcon(_ status: ScheduleExecution.ExecutionStatus) -> String {
        switch status {
        case .success: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .skipped: return "forward.fill"
        }
    }

    private func executionStatusColor(_ status: ScheduleExecution.ExecutionStatus) -> Color {
        switch status {
        case .success: return .green
        case .failed: return .red
        case .skipped: return .orange
        }
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        HStack(spacing: 12) {
            if let agent {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(agent.color.swiftUIColor)
                    .frame(width: 3, height: 16)

                Text(agent.name)
                    .font(.system(size: 12, weight: .medium))
            }

            Spacer()

            Button("Revert") {
                appState.editingSchedule = nil
            }
            .controlSize(.small)
            .pointingHandCursor()

            Button("Save") {
                saveChanges()
            }
            .controlSize(.small)
            .buttonStyle(.borderedProminent)
            .pointingHandCursor()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .themedBackground(Color.appSurface)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "clock")
                .font(.system(size: 48))
                .foregroundStyle(Color.appIconMuted)
            Text("No schedule selected")
                .font(.headline)
                .foregroundStyle(Color.appMuted)
            Text("Select a schedule from the sidebar to view details")
                .font(.subheadline)
                .foregroundStyle(Color.appSubtle)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .themedBackground(Color.appWindowBackground)
    }
}
