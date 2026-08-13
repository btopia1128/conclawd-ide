import SwiftUI

/// Sheet for creating or editing a schedule.
struct NewScheduleSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.l10n) private var l10n
    @Environment(\.dismiss) private var dismiss

    /// If non-nil, we are editing an existing schedule.
    var editingSchedule: AgentSchedule?

    /// Pre-selected agent name (when opened from agent inspector).
    var preselectedAgentName: String?

    @State private var selectedAgentName: String = ""
    @State private var prompt: String = ""
    @State private var scheduleKind: ScheduleKind = .interval
    @State private var intervalMinutes: Int = 30
    @State private var dailyHour: Int = 9
    @State private var dailyMinute: Int = 0
    @State private var weeklyWeekday: Int = 2 // Monday
    @State private var weeklyHour: Int = 9
    @State private var weeklyMinute: Int = 0
    @State private var maxConcurrent: Int = 3
    @State private var isCloud: Bool = false
    @State private var scope: AgentScope = .user
    @State private var projectDirectory: URL?
    @State private var isEnabled: Bool = true

    // Cloud-specific state
    @State private var cloudName: String = ""
    @State private var cloudCron: String = "0 9 * * 1-5"
    @State private var cloudModel: String = "claude-sonnet-4-6"
    @State private var cloudEnvironmentId: String = "default"
    @State private var isCreatingCloud: Bool = false
    @State private var cloudError: String?

    enum ScheduleKind: String, CaseIterable {
        case interval = "Interval"
        case daily = "Daily"
        case weekly = "Weekly"
    }

    private var resolvedScheduleType: ScheduleType {
        switch scheduleKind {
        case .interval: return .interval(minutes: intervalMinutes)
        case .daily: return .daily(hour: dailyHour, minute: dailyMinute)
        case .weekly: return .weekly(weekday: weeklyWeekday, hour: weeklyHour, minute: weeklyMinute)
        }
    }

    private var canSave: Bool {
        if isCloud {
            return !cloudName.trimmingCharacters(in: .whitespaces).isEmpty
                && !prompt.trimmingCharacters(in: .whitespaces).isEmpty
                && !cloudCron.trimmingCharacters(in: .whitespaces).isEmpty
        }
        return !selectedAgentName.isEmpty && !prompt.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var resolvedProjectPath: String? {
        if scope == .project {
            return (projectDirectory ?? appState.selectedProject?.directoryPath)?
                .path(percentEncoded: false)
        }
        return nil
    }

    var body: some View {
        VStack(spacing: 20) {
            Text(editingSchedule != nil ? l10n.editSchedule : l10n.newSchedule)
                .font(.headline)

            Form {
                // Local / Cloud picker (new schedules only)
                if editingSchedule == nil {
                    Section {
                        Picker("", selection: $isCloud) {
                            Text(l10n.localBranches).tag(false)
                            Text(l10n.cloud).tag(true)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }
                }

                if isCloud {
                    cloudFormSections
                } else {
                    localFormSections
                }
            }
            .formStyle(.grouped)

            if let error = cloudError {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .lineLimit(3)
            }

            HStack {
                Button(l10n.cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)

                Spacer()

                if isCloud {
                    Button(l10n.create) {
                        createCloudSchedule()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSave || isCreatingCloud)
                    .keyboardShortcut(.defaultAction)
                } else {
                    Button(editingSchedule != nil ? l10n.save : l10n.create) {
                        saveSchedule()
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSave)
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding()
        .frame(width: 480)
        .onAppear {
            if let schedule = editingSchedule {
                selectedAgentName = schedule.agentName
                prompt = schedule.prompt
                maxConcurrent = schedule.maxConcurrentSessions
                scope = schedule.scope
                isEnabled = schedule.isEnabled
                if let path = schedule.projectPath {
                    projectDirectory = URL(filePath: path)
                }
                switch schedule.scheduleType {
                case .interval(let minutes):
                    scheduleKind = .interval
                    intervalMinutes = minutes
                case .daily(let hour, let minute):
                    scheduleKind = .daily
                    dailyHour = hour
                    dailyMinute = minute
                case .weekly(let weekday, let hour, let minute):
                    scheduleKind = .weekly
                    weeklyWeekday = weekday
                    weeklyHour = hour
                    weeklyMinute = minute
                }
            } else if let preselected = preselectedAgentName {
                selectedAgentName = preselected
            } else if let firstAgent = appState.agents.first {
                selectedAgentName = firstAgent.name
            }
        }
    }

    // MARK: - Local Schedule Form

    @ViewBuilder
    private var localFormSections: some View {
        Section {
            Picker(l10n.agent, selection: $selectedAgentName) {
                Text(l10n.selectAnAgentPicker).tag("")
                ForEach(appState.agents, id: \.name) { agent in
                    Text(agent.name).tag(agent.name)
                }
            }

            if editingSchedule == nil {
                if scope == .project {
                    LabeledContent(l10n.project) {
                        HStack(spacing: 4) {
                            Text(projectDirectory?.path(percentEncoded: false)
                                 ?? appState.selectedProject?.directoryPath.path(percentEncoded: false)
                                 ?? l10n.notSelected)
                                .font(.system(size: 11))
                                .foregroundStyle(Color.appSecondary)
                                .lineLimit(1)
                                .truncationMode(.head)

                            Button(l10n.browseShort) { pickProjectDirectory() }
                                .controlSize(.small)
                        }
                    }
                }
            }
        }

        Section(l10n.schedule) {
            Picker(l10n.type, selection: $scheduleKind) {
                ForEach(ScheduleKind.allCases, id: \.self) { kind in
                    Text(scheduleKindName(kind)).tag(kind)
                }
            }

            switch scheduleKind {
            case .interval:
                Picker(l10n.interval, selection: $intervalMinutes) {
                    Text(l10n.min1).tag(1)
                    Text(l10n.min5).tag(5)
                    Text(l10n.min10).tag(10)
                    Text(l10n.min15).tag(15)
                    Text(l10n.min30).tag(30)
                    Text(l10n.hour1).tag(60)
                    Text(l10n.hours2).tag(120)
                    Text(l10n.hours4).tag(240)
                    Text(l10n.hours8).tag(480)
                    Text(l10n.hours12).tag(720)
                    Text(l10n.hours24).tag(1440)
                }

            case .daily:
                HStack {
                    Picker("Hour", selection: $dailyHour) {
                        ForEach(0..<24, id: \.self) { h in
                            Text(String(format: "%02d", h)).tag(h)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 60)

                    Text(":")

                    Picker("Min", selection: $dailyMinute) {
                        ForEach([0, 15, 30, 45], id: \.self) { m in
                            Text(String(format: "%02d", m)).tag(m)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 60)
                }

            case .weekly:
                Picker("Day", selection: $weeklyWeekday) {
                    Text(l10n.sunday).tag(1)
                    Text(l10n.monday).tag(2)
                    Text(l10n.tuesday).tag(3)
                    Text(l10n.wednesday).tag(4)
                    Text(l10n.thursday).tag(5)
                    Text(l10n.friday).tag(6)
                    Text(l10n.saturday).tag(7)
                }

                HStack {
                    Picker("Hour", selection: $weeklyHour) {
                        ForEach(0..<24, id: \.self) { h in
                            Text(String(format: "%02d", h)).tag(h)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 60)

                    Text(":")

                    Picker("Min", selection: $weeklyMinute) {
                        ForEach([0, 15, 30, 45], id: \.self) { m in
                            Text(String(format: "%02d", m)).tag(m)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 60)
                }
            }
        }

        Section(l10n.executionSettings) {
            VStack(alignment: .leading, spacing: 4) {
                Text(l10n.instructionsPrompt)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.appSecondary)
                TextEditor(text: $prompt)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(minHeight: 80)
                    .scrollContentBackground(.hidden)
                    .padding(4)
                    .background(RoundedRectangle(cornerRadius: 4).fill(.fill.quinary))
            }

            Stepper("\(l10n.maxConcurrent): \(maxConcurrent)", value: $maxConcurrent, in: 1...10)

            Toggle(l10n.enabled, isOn: $isEnabled)
        }
    }

    // MARK: - Cloud Schedule Form

    @ViewBuilder
    private var cloudFormSections: some View {
        Section {
            TextField(l10n.name, text: $cloudName)

            Picker(l10n.model, selection: $cloudModel) {
                Text("Sonnet").tag("claude-sonnet-4-6")
                Text("Opus").tag("claude-opus-4-6")
                Text("Haiku").tag("claude-haiku-4-5-20251001")
            }

            TextField(l10n.environmentId, text: $cloudEnvironmentId)
                .font(.system(size: 12, design: .monospaced))
        }

        Section(l10n.schedule) {
            VStack(alignment: .leading, spacing: 6) {
                TextField(l10n.cronExpressionPlaceholder, text: $cloudCron)
                    .font(.system(size: 12, design: .monospaced))

                Text(CronFormatter.describe(cloudCron))
                    .font(.system(size: 10))
                    .foregroundStyle(Color.appTertiary)

                HStack(spacing: 4) {
                    cronPresetButton(l10n.cronPresetHourly, cron: "0 * * * *")
                    cronPresetButton(l10n.cronPresetDaily9am, cron: "0 9 * * *")
                    cronPresetButton(l10n.cronPresetWeekdays9am, cron: "0 9 * * 1-5")
                    cronPresetButton(l10n.cronPresetWeekly, cron: "0 9 * * 1")
                }

                Text(l10n.cloudScheduleMinInterval)
                    .font(.system(size: 9))
                    .foregroundStyle(Color.appTertiary)
            }
        }

        Section(l10n.instructionsPrompt) {
            TextEditor(text: $prompt)
                .font(.system(size: 12, design: .monospaced))
                .frame(minHeight: 80)
                .scrollContentBackground(.hidden)
                .padding(4)
                .background(RoundedRectangle(cornerRadius: 4).fill(.fill.quinary))

            Toggle(l10n.enabled, isOn: $isEnabled)
        }
    }

    private func cronPresetButton(_ label: String, cron: String) -> some View {
        Button(label) {
            cloudCron = cron
        }
        .font(.system(size: 10))
        .controlSize(.mini)
        .buttonStyle(.bordered)
    }

    private func createCloudSchedule() {
        isCreatingCloud = true
        cloudError = nil

        let request = CloudTriggerCreateRequest.build(
            name: cloudName.trimmingCharacters(in: .whitespaces),
            cronExpression: cloudCron.trimmingCharacters(in: .whitespaces),
            enabled: isEnabled,
            prompt: prompt.trimmingCharacters(in: .whitespaces),
            model: cloudModel,
            environmentId: cloudEnvironmentId.trimmingCharacters(in: .whitespaces)
        )

        Task {
            do {
                _ = try await appState.createCloudTrigger(request)
                dismiss()
            } catch {
                cloudError = error.localizedDescription
                isCreatingCloud = false
            }
        }
    }

    private func saveSchedule() {
        if var existing = editingSchedule {
            existing.agentName = selectedAgentName
            existing.prompt = prompt
            existing.scheduleType = resolvedScheduleType
            existing.maxConcurrentSessions = maxConcurrent
            existing.scope = scope
            existing.projectPath = resolvedProjectPath
            existing.isEnabled = isEnabled
            appState.scheduleManager.updateSchedule(existing)
        } else {
            let schedule = AgentSchedule(
                agentName: selectedAgentName,
                prompt: prompt,
                scheduleType: resolvedScheduleType,
                isEnabled: isEnabled,
                maxConcurrentSessions: maxConcurrent,
                scope: scope,
                projectPath: resolvedProjectPath
            )
            appState.scheduleManager.addSchedule(schedule)
        }
    }

    private func scheduleKindName(_ kind: ScheduleKind) -> String {
        switch kind {
        case .interval: return l10n.interval
        case .daily: return l10n.daily
        case .weekly: return l10n.weekly
        }
    }

    private func pickProjectDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = l10n.selectProjectDirectory
        if panel.runModal() == .OK, let url = panel.url {
            projectDirectory = url
        }
    }
}
