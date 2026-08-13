import SwiftUI

/// Center pane editor for a cloud trigger's details.
struct CloudTriggerEditorView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.l10n) private var l10n

    @State private var editingName: String = ""
    @State private var editingCron: String = ""
    @State private var editingPrompt: String = ""
    @State private var editingModel: String = "claude-sonnet-4-6"
    @State private var editingEnvironmentId: String = "default"
    @State private var lastSyncedTriggerId: String?
    @State private var isSaving = false
    @State private var isRunning = false
    @State private var errorMessage: String?

    private var trigger: CloudTrigger? {
        appState.editingCloudTrigger
    }

    var body: some View {
        if let trigger {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        headerSection(trigger)
                        detailsSection(trigger)
                        promptSection
                    }
                    .padding(24)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                bottomBar(trigger)
            }
            .themedBackground(Color.appWindowBackground)
            .onChange(of: trigger.id) { _, _ in
                syncEditingState(from: trigger)
            }
            .onAppear {
                syncEditingState(from: trigger)
            }
        }
    }

    // MARK: - Sync

    private func syncEditingState(from trigger: CloudTrigger) {
        guard trigger.id != lastSyncedTriggerId else { return }
        lastSyncedTriggerId = trigger.id
        editingName = trigger.name
        editingCron = trigger.cronExpression
        editingPrompt = trigger.prompt ?? ""
        editingModel = trigger.model ?? "claude-sonnet-4-6"
        editingEnvironmentId = trigger.environmentId
        errorMessage = nil
    }

    // MARK: - Header

    private func headerSection(_ trigger: CloudTrigger) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "cloud.fill")
                .font(.system(size: 20))
                .foregroundStyle(.blue.opacity(0.7))

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(trigger.name)
                        .font(.title2.bold())

                    if trigger.enabled {
                        Label(l10n.enabled, systemImage: "checkmark.circle.fill")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.green)
                    } else {
                        Label(l10n.disabled, systemImage: "pause.circle.fill")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color.appSecondary)
                    }
                }

                Text(trigger.cronDisplayName)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.appSecondary)
            }

            Spacer()

            HStack(spacing: 8) {
                Button {
                    runNow(trigger)
                } label: {
                    if isRunning {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label(l10n.runNow, systemImage: "play.fill")
                    }
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
                .disabled(isRunning)

                Button {
                    toggleEnabled(trigger)
                } label: {
                    Label(
                        trigger.enabled ? l10n.disable : l10n.enable,
                        systemImage: trigger.enabled ? "pause.fill" : "play.fill"
                    )
                }
                .controlSize(.small)
            }
        }
    }

    // MARK: - Details

    private func detailsSection(_ trigger: CloudTrigger) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Details")
                .font(.headline)

            VStack(alignment: .leading, spacing: 12) {
                detailRow(l10n.name) {
                    TextField("", text: $editingName)
                        .font(.system(size: 12))
                        .textFieldStyle(.plain)
                }

                detailRow(l10n.cronExpression) {
                    VStack(alignment: .leading, spacing: 4) {
                        TextField(l10n.cronExpressionPlaceholder, text: $editingCron)
                            .font(.system(size: 12, design: .monospaced))
                            .textFieldStyle(.plain)

                        // Cron preview
                        Text(CronFormatter.describe(editingCron))
                            .font(.system(size: 10))
                            .foregroundStyle(Color.appTertiary)

                        // Preset buttons
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

                Divider()

                detailRow(l10n.model) {
                    Picker("", selection: $editingModel) {
                        Text("Sonnet").tag("claude-sonnet-4-6")
                        Text("Opus").tag("claude-opus-4-6")
                        Text("Haiku").tag("claude-haiku-4-5-20251001")
                    }
                    .labelsHidden()
                    .controlSize(.small)
                }

                detailRow(l10n.environmentId) {
                    TextField("default", text: $editingEnvironmentId)
                        .font(.system(size: 12, design: .monospaced))
                        .textFieldStyle(.plain)
                }

                if let nextRun = trigger.nextRunDate {
                    detailRow(l10n.nextRun) {
                        Text(Self.dateFormatter.string(from: nextRun))
                            .font(.system(size: 12))
                            .foregroundStyle(Color.appSecondary)
                    }
                }

                if let created = trigger.createdDate {
                    detailRow("Created") {
                        Text(Self.dateFormatter.string(from: created))
                            .font(.system(size: 12))
                            .foregroundStyle(Color.appSecondary)
                    }
                }

                if let creator = trigger.creator {
                    detailRow("Creator") {
                        Text(creator.name ?? creator.email ?? "Unknown")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.appSecondary)
                    }
                }
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 8).fill(.fill.quinary))
        }
    }

    private func cronPresetButton(_ label: String, cron: String) -> some View {
        Button(label) {
            editingCron = cron
        }
        .font(.system(size: 10))
        .controlSize(.mini)
        .buttonStyle(.bordered)
        .pointingHandCursor()
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

    private var promptSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(l10n.instructionsPrompt)
                .font(.headline)

            TextEditor(text: $editingPrompt)
                .font(.system(size: 12, design: .monospaced))
                .frame(maxWidth: .infinity, minHeight: 120)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(.fill.quinary))
        }
    }

    // MARK: - Bottom Bar

    private func bottomBar(_ trigger: CloudTrigger) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "cloud.fill")
                .font(.system(size: 10))
                .foregroundStyle(.blue.opacity(0.7))
            Text(trigger.name)
                .font(.system(size: 12, weight: .medium))

            if let error = errorMessage {
                Text(error)
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
                    .lineLimit(1)
            }

            Spacer()

            Button(l10n.revert) {
                syncEditingState(from: trigger)
                lastSyncedTriggerId = nil
                syncEditingState(from: trigger)
            }
            .controlSize(.small)
            .pointingHandCursor()

            Button(l10n.save) {
                saveChanges()
            }
            .controlSize(.small)
            .buttonStyle(.borderedProminent)
            .disabled(isSaving)
            .pointingHandCursor()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .themedBackground(Color.appSurface)
    }

    // MARK: - Actions

    private func saveChanges() {
        guard var updated = appState.editingCloudTrigger else { return }
        isSaving = true
        errorMessage = nil

        updated.name = editingName
        updated.cronExpression = editingCron
        updated.jobConfig.ccr.environmentId = editingEnvironmentId
        updated.jobConfig.ccr.sessionContext?.model = editingModel

        // Update prompt in events
        if updated.jobConfig.ccr.events?.isEmpty == false {
            updated.jobConfig.ccr.events?[0].data?.message?.content = editingPrompt
        }

        Task {
            do {
                try await appState.updateCloudTrigger(updated)
                appState.editingCloudTrigger = appState.cloudTriggerService.triggers.first { $0.id == updated.id }
                isSaving = false
            } catch {
                errorMessage = error.localizedDescription
                isSaving = false
            }
        }
    }

    private func runNow(_ trigger: CloudTrigger) {
        isRunning = true
        errorMessage = nil
        Task {
            do {
                try await appState.runCloudTrigger(id: trigger.id)
                isRunning = false
            } catch {
                errorMessage = error.localizedDescription
                isRunning = false
            }
        }
    }

    private func toggleEnabled(_ trigger: CloudTrigger) {
        errorMessage = nil
        Task {
            do {
                try await appState.toggleCloudTrigger(trigger)
                appState.editingCloudTrigger = appState.cloudTriggerService.triggers.first { $0.id == trigger.id }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: - Formatters

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()
}
