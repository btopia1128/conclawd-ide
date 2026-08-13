import SwiftUI

/// A single row in the schedule list.
struct ScheduleRowView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.l10n) private var l10n
    let schedule: AgentSchedule
    let isSelected: Bool

    private var agent: Agent? {
        appState.agents.first { $0.name == schedule.agentName }
    }

    private var activeSessionCount: Int {
        appState.scheduleManager.scheduledSessionIds[schedule.id]?.count ?? 0
    }

    var body: some View {
        HStack(spacing: 8) {
            // Enabled indicator
            Circle()
                .fill(schedule.isEnabled ? .green : .statusStopped)
                .frame(width: 6, height: 6)

            // Agent color bar
            RoundedRectangle(cornerRadius: 1.5)
                .fill(agent?.color.swiftUIColor ?? .gray)
                .frame(width: 3, height: 20)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Image(systemName: schedule.scheduleType.icon)
                        .font(.system(size: 9))
                        .foregroundStyle(Color.appSecondary)
                    Text(schedule.agentName)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                }

                Text(schedule.scheduleType.displayName)
                    .font(.system(size: 10))
                    .foregroundStyle(Color.appSecondary)
                    .lineLimit(1)
            }

            Spacer()

            // Active session count badge
            if activeSessionCount > 0 {
                Text("\(activeSessionCount)")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 16, height: 16)
                    .background(Color.orange)
                    .clipShape(Circle())
            }

            if !schedule.isEnabled {
                Text(l10n.disabled)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Color.appSecondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(.fill.tertiary)
                    .cornerRadius(3)
            }

        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.accentColor.opacity(0.15) : .clear)
        )
        .contentShape(RoundedRectangle(cornerRadius: 6))
        .pointingHandCursor()
    }
}
