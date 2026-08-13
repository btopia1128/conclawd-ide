import SwiftUI

/// A row displaying a session history record, shared between sidebar and full history view.
struct SessionHistoryRowView: View {
    let record: SessionRecord
    let onResume: (() -> Void)?
    var isExtractingMemory: Bool = false
    var body: some View {
        HStack(spacing: 8) {
            // Status icon
            if isExtractingMemory {
                ProgressView()
                    .controlSize(.mini)
                    .frame(width: 12, height: 12)
            } else {
                Image(systemName: iconName)
                    .font(.system(size: 12))
                    .foregroundStyle(iconColor)
            }

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 3) {
                    if record.isScheduledSession {
                        Image(systemName: "clock.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(.orange)
                    }
                    Text(record.agentName)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                }

                if let prompt = record.initialPrompt {
                    Text(prompt)
                        .font(.system(size: 10))
                        .foregroundStyle(Color.appSecondary)
                        .lineLimit(3)
                        .truncationMode(.tail)
                }

                HStack(spacing: 4) {
                    if isExtractingMemory {
                        Text("Saving memories...")
                            .font(.system(size: 9))
                            .foregroundStyle(.purple)
                    } else {
                        Text(statusText)
                            .font(.system(size: 9))
                            .foregroundStyle(statusColor)
                    }

                    Text(record.endedAt ?? record.startedAt, format: .dateTime.month().day().hour().minute())
                        .font(.system(size: 9))
                        .foregroundStyle(Color.appTertiary)
                }
            }

            Spacer()

            if record.isResumable {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(.clear)
        )
        .contentShape(RoundedRectangle(cornerRadius: 6))
        .opacity(record.isResumable ? 1.0 : 0.6)
        .pointingHandCursor(record.isResumable)
        .onTapGesture {
            guard record.isResumable, let onResume else { return }
            onResume()
        }
    }

    // MARK: - Display Logic

    private var iconName: String {
        if record.isAbnormalTermination {
            return "exclamationmark.triangle.fill"
        }
        if record.isResumable {
            return "arrow.clockwise.circle"
        }
        return "stop.circle"
    }

    private var iconColor: Color {
        if record.isAbnormalTermination {
            return .orange
        }
        if record.isResumable {
            return .orange
        }
        return .appIconMuted
    }

    private var statusText: String {
        if record.isAbnormalTermination {
            return "Crashed"
        }
        if record.isResumable {
            return "Resumable"
        }
        return "Ended"
    }

    private var statusColor: Color {
        if record.isAbnormalTermination {
            return .orange
        }
        if record.isResumable {
            return .orange
        }
        return .appSecondary
    }
}
