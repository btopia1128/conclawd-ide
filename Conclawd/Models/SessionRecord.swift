import Foundation

/// A persistent record of a completed or interrupted agent session.
struct SessionRecord: Identifiable, Codable, Equatable {
    let id: UUID
    let agentName: String
    let agentFilePath: String?
    /// Derived from agentFilePath — the project root (nil for home/user agents).
    let projectPath: String?
    let startedAt: Date
    var endedAt: Date?
    var claudeResumeId: String?
    var exitCode: Int32?
    /// The CLI provider used for this session. Nil for legacy records (treated as .claude).
    var cliProviderType: CLIProviderType?
    var isScheduledSession: Bool
    /// The first user prompt extracted from terminal output, used to identify the session.
    var initialPrompt: String?
    /// Whether memory extraction has been completed for this session.
    var memoryExtracted: Bool?

    var isResumable: Bool { claudeResumeId != nil }
    var isAbnormalTermination: Bool { endedAt == nil }

    /// The display date used for time-based grouping (prefers endedAt, falls back to startedAt).
    var displayDate: Date { endedAt ?? startedAt }

    /// Computes projectPath from an agentFilePath like `/path/to/project/.claude/agents/name.md`.
    /// Returns nil for home agents (`~/.claude/agents/name.md`).
    /// Time-based period for grouping session records.
    enum TimePeriod: CaseIterable {
        case today, yesterday, thisWeek, lastWeek, older

        func label(_ l10n: L10n) -> String {
            switch self {
            case .today: return l10n.today
            case .yesterday: return l10n.yesterday
            case .thisWeek: return l10n.thisWeek
            case .lastWeek: return l10n.lastWeek
            case .older: return l10n.older
            }
        }

        static func from(date: Date, calendar: Calendar = .current) -> TimePeriod {
            let now = Date()
            if calendar.isDateInToday(date) { return .today }
            if calendar.isDateInYesterday(date) { return .yesterday }
            let startOfWeek = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? now
            if date >= startOfWeek { return .thisWeek }
            if let prevWeekStart = calendar.date(byAdding: .weekOfYear, value: -1, to: startOfWeek),
               date >= prevWeekStart { return .lastWeek }
            return .older
        }
    }

    static func deriveProjectPath(from agentFilePath: String?) -> String? {
        guard let path = agentFilePath else { return nil }
        let url = URL(filePath: path)
        // Go up 3 levels: name.md -> agents -> .claude -> project
        let projectURL = url
            .deletingLastPathComponent()   // agents/
            .deletingLastPathComponent()   // .claude/
            .deletingLastPathComponent()   // project/

        let homePath = FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false)
        let projectPathStr = projectURL.path(percentEncoded: false)

        // If the project path IS the home directory, this is a home agent — no project
        if projectPathStr.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            == homePath.trimmingCharacters(in: CharacterSet(charactersIn: "/")) {
            return nil
        }
        return projectPathStr
    }
}

/// Groups session records by time period for display.
struct SessionTimeGroup: Identifiable {
    let label: String
    let records: [SessionRecord]
    var id: String { label }

    /// Groups the given records into time-based sections, preserving order within each group.
    static func group(_ records: [SessionRecord], l10n: L10n) -> [SessionTimeGroup] {
        var buckets: [SessionRecord.TimePeriod: [SessionRecord]] = [:]
        for record in records {
            let period = SessionRecord.TimePeriod.from(date: record.displayDate)
            buckets[period, default: []].append(record)
        }
        return SessionRecord.TimePeriod.allCases.compactMap { period in
            guard let items = buckets[period], !items.isEmpty else { return nil }
            return SessionTimeGroup(label: period.label(l10n), records: items)
        }
    }
}
