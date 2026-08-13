import SwiftUI

/// A single row in the cloud triggers list.
struct CloudTriggerRowView: View {
    @Environment(\.l10n) private var l10n
    let trigger: CloudTrigger
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            // Enabled indicator
            Circle()
                .fill(trigger.enabled ? .green : .statusStopped)
                .frame(width: 6, height: 6)

            // Cloud icon
            Image(systemName: "cloud.fill")
                .font(.system(size: 10))
                .foregroundStyle(.blue.opacity(0.7))
                .frame(width: 14)

            VStack(alignment: .leading, spacing: 1) {
                Text(trigger.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)

                HStack(spacing: 4) {
                    Text(trigger.cronDisplayName)
                        .font(.system(size: 10))
                        .foregroundStyle(Color.appSecondary)
                        .lineLimit(1)

                    if let model = trigger.model {
                        Text(modelShortName(model))
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(Color.appSecondary)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(RoundedRectangle(cornerRadius: 3).fill(.fill.tertiary))
                    }
                }
            }

            Spacer()

            if !trigger.enabled {
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

    private func modelShortName(_ model: String) -> String {
        if model.contains("opus") { return "Opus" }
        if model.contains("sonnet") { return "Sonnet" }
        if model.contains("haiku") { return "Haiku" }
        return model.components(separatedBy: "-").first ?? model
    }
}
