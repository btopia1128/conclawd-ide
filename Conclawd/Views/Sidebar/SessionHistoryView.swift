import SwiftUI

/// Full session history sheet with filtering and resume actions.
struct SessionHistoryView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.l10n) private var l10n
    @Environment(\.dismiss) private var dismiss
    @State private var filterText = ""
    @State private var resumableOnly = false
    @State private var showingClearAllConfirm = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text(l10n.sessionHistory)
                    .font(.system(size: 14, weight: .semibold))

                Spacer()

                Button(l10n.clearAll) {
                    showingClearAllConfirm = true
                }
                .foregroundStyle(.red)
                .disabled(appState.sessionHistoryService.records.isEmpty)

                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            // Filters
            HStack(spacing: 12) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.appSecondary)
                    TextField(l10n.filterByAgentName, text: $filterText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(.fill.tertiary)
                )

                Toggle(l10n.resumableOnly, isOn: $resumableOnly)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11))
                    .controlSize(.small)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            Divider()

            // List
            let filteredRecords = filteredHistoryRecords
            if filteredRecords.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 24))
                        .foregroundStyle(Color.appTertiary)
                    Text(l10n.noHistory)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.appSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(SessionTimeGroup.group(filteredRecords, l10n: l10n), id: \.label) { group in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(group.label)
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(Color.appSecondary)
                                    .padding(.horizontal, 4)

                                VStack(spacing: 2) {
                                    ForEach(group.records) { record in
                                        SessionHistoryRowView(
                                            record: record,
                                            onResume: record.isResumable ? {
                                                appState.resumeFromHistory(record: record)
                                                dismiss()
                                            } : nil,
                                            isExtractingMemory: appState.memoryExtractingSessions.contains(record.id)
                                        )
                                            .contextMenu {
                                                if record.isResumable {
                                                    Button(l10n.resume) {
                                                        appState.resumeFromHistory(record: record)
                                                        dismiss()
                                                    }
                                                    Button(l10n.fork) {
                                                        appState.forkFromHistory(record: record)
                                                        dismiss()
                                                    }
                                                }

                                                Divider()

                                                Button(l10n.delete, role: .destructive) {
                                                    appState.sessionHistoryService.deleteRecord(id: record.id)
                                                }
                                            }
                                    }
                                }
                            }
                        }
                    }
                    .padding(12)
                }
            }
        }
        .alert(l10n.clearAllHistory, isPresented: $showingClearAllConfirm) {
            Button(l10n.cancel, role: .cancel) {}
            Button(l10n.clearAll, role: .destructive) {
                appState.sessionHistoryService.deleteAllRecords()
            }
        } message: {
            Text(l10n.clearAllHistoryConfirm)
        }
        .frame(width: 480, height: 500)
    }

    // MARK: - Filtering

    private var filteredHistoryRecords: [SessionRecord] {
        let activeIds = Set(appState.activeSessions.map(\.id))
        let projectPath: String? = {
            switch appState.projectSelection {
            case .home:
                return nil
            case .project(let project):
                return project.directoryPath.path(percentEncoded: false)
            case .all:
                return nil // show all
            }
        }()

        if case .all = appState.projectSelection {
            return appState.sessionHistoryService.allRecords(
                agentName: filterText.isEmpty ? nil : filterText,
                resumableOnly: resumableOnly,
                excludingIds: activeIds
            )
        }

        return appState.sessionHistoryService.allRecords(
            projectPath: projectPath,
            agentName: filterText.isEmpty ? nil : filterText,
            resumableOnly: resumableOnly,
            excludingIds: activeIds
        )
    }
}
