import SwiftUI
import Charts

/// Sheet showing skill usage as charts: total invocations per skill and
/// a daily activity histogram, filterable by period.
struct SkillUsageStatsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.l10n) private var l10n
    @Environment(\.dismiss) private var dismiss

    private enum Period: Hashable, CaseIterable {
        case week, month, all

        var days: Int? {
            switch self {
            case .week: 7
            case .month: 30
            case .all: nil
            }
        }
    }

    @State private var period: Period = .month

    private var periodStart: Date? {
        guard let days = period.days else { return nil }
        return Calendar.current.startOfDay(
            for: Calendar.current.date(byAdding: .day, value: -(days - 1), to: Date()) ?? Date())
    }

    private var entries: [SkillUsageEntry] {
        appState.skillUsageService.entries(since: periodStart)
    }

    private var skillTotals: [(skill: String, count: Int)] {
        var counts: [String: Int] = [:]
        for entry in entries {
            counts[entry.skill, default: 0] += 1
        }
        return counts
            .map { (skill: $0.key, count: $0.value) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.skill < $1.skill }
    }

    private var dailyTotals: [(day: Date, count: Int)] {
        let calendar = Calendar.current
        var counts: [Date: Int] = [:]
        for entry in entries {
            counts[calendar.startOfDay(for: entry.date), default: 0] += 1
        }
        return counts
            .map { (day: $0.key, count: $0.value) }
            .sorted { $0.day < $1.day }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text(l10n.skillUsageStats)
                    .font(.system(size: 14, weight: .semibold))

                Spacer()

                Picker("", selection: $period) {
                    Text(l10n.last7Days).tag(Period.week)
                    Text(l10n.last30Days).tag(Period.month)
                    Text(l10n.allTime).tag(Period.all)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()

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

            if entries.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        chartSection(l10n.usageBySkill) { bySkillChart }
                        chartSection(l10n.dailyActivity) { dailyChart }
                    }
                    .padding(16)
                }
            }
        }
        .frame(width: 560, height: 520)
        .onAppear {
            appState.skillUsageService.loadUsageCounts()
        }
    }

    // MARK: - Sections

    private func chartSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.appSecondary)
                .textCase(.uppercase)

            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(.fill.quaternary)
        )
    }

    private var bySkillChart: some View {
        Chart(skillTotals, id: \.skill) { item in
            BarMark(
                x: .value("Count", item.count),
                y: .value("Skill", item.skill)
            )
            .cornerRadius(3)
            .foregroundStyle(Color.accentColor.gradient)
            .annotation(position: .trailing, spacing: 6) {
                Text("\(item.count)")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.appSecondary)
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine()
                AxisValueLabel()
                    .font(.system(size: 9))
            }
        }
        .chartYAxis {
            AxisMarks { _ in
                AxisValueLabel()
                    .font(.system(size: 11))
            }
        }
        // Fixed row height so many skills grow the sheet's scroll content
        // instead of squeezing the bars.
        .frame(height: max(80, CGFloat(skillTotals.count) * 28 + 24))
    }

    private var dailyChart: some View {
        Chart(dailyTotals, id: \.day) { item in
            BarMark(
                x: .value("Day", item.day, unit: .day),
                y: .value("Count", item.count)
            )
            .cornerRadius(2)
            .foregroundStyle(Color.accentColor.gradient)
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 6)) { _ in
                AxisGridLine()
                AxisValueLabel(format: .dateTime.month(.defaultDigits).day())
                    .font(.system(size: 9))
            }
        }
        .chartYAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine()
                AxisValueLabel()
                    .font(.system(size: 9))
            }
        }
        .frame(height: 140)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 28))
                .foregroundStyle(Color.appTertiary)
            Text(l10n.noUsageData)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.appSecondary)
            if !appState.skillUsageService.isHookInstalled {
                Text(l10n.usageTrackingDisabledHint)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.appTertiary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
