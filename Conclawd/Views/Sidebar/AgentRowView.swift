import SwiftUI

/// A single row in the sidebar representing an agent.
struct AgentRowView: View {
    let agent: Agent
    @Environment(AppState.self) private var appState
    @Environment(\.l10n) private var l10n

    private var processStatus: AgentProcessStatus {
        appState.bestStatus(agentId: agent.id)
    }

    var body: some View {
        HStack(spacing: 8) {
            // Status indicator with animation
            statusIndicator

            // Agent color indicator
            Circle()
                .fill(agentColor)
                .frame(width: 6, height: 6)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(agent.name)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)

                    if processStatus == .running {
                        // Thinking indicator
                        ProgressView()
                            .controlSize(.mini)
                            .scaleEffect(0.6)
                    }
                }

                if processStatus.isActive {
                    Text(statusLabel)
                        .font(.system(size: 10))
                        .foregroundStyle(statusLabelColor)
                        .lineLimit(1)
                } else if !agent.description.isEmpty {
                    Text(agent.description)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.appSecondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            // Model badge
            if agent.model != .inherit {
                Text(agent.model.rawValue)
                    .font(.system(size: 9, weight: .medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary)
                    .cornerRadius(4)
            }
        }
        .padding(.vertical, 2)
        .pointingHandCursor()
        .onTapGesture(count: 2) {
            appState.startAgent(agent)
        }
    }

    // MARK: - Status Indicator

    @ViewBuilder
    private var statusIndicator: some View {
        switch processStatus {
        case .running:
            // Pulsing green dot for "thinking"
            Circle()
                .fill(Color.statusRunning)
                .frame(width: 8, height: 8)
                .overlay(
                    Circle()
                        .stroke(Color.statusRunning.opacity(0.5), lineWidth: 2)
                        .frame(width: 12, height: 12)
                )
        case .waitingForInput:
            // Solid yellow dot for "ready for input"
            Circle()
                .fill(Color.statusReady)
                .frame(width: 8, height: 8)
        case .stopped:
            // Gray dot for "stopped"
            Circle()
                .fill(Color.statusStopped)
                .frame(width: 8, height: 8)
        }
    }

    private var statusLabel: String {
        switch processStatus {
        case .running: return l10n.thinking
        case .waitingForInput: return l10n.ready
        case .stopped: return ""
        }
    }

    private var statusLabelColor: Color {
        switch processStatus {
        case .running: return .statusRunning
        case .waitingForInput: return .statusReady
        case .stopped: return .statusStopped
        }
    }

    private var agentColor: Color {
        switch agent.color {
        case .red: return .red
        case .orange: return .orange
        case .yellow: return .yellow
        case .green: return .green
        case .blue: return .blue
        case .purple: return .purple
        case .cyan: return .cyan
        case .magenta: return .pink
        }
    }
}
