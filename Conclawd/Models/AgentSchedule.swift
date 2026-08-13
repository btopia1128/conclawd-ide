import Foundation

// MARK: - Schedule Type

/// Defines when a schedule should fire.
enum ScheduleType: Hashable {
    case interval(minutes: Int)
    case daily(hour: Int, minute: Int)
    case weekly(weekday: Int, hour: Int, minute: Int) // weekday: 1=Sunday ... 7=Saturday

    var displayName: String {
        switch self {
        case .interval(let minutes):
            if minutes < 60 { return "Every \(minutes)min" }
            let hours = minutes / 60
            let remaining = minutes % 60
            if remaining == 0 { return "Every \(hours)h" }
            return "Every \(hours)h \(remaining)min"
        case .daily(let hour, let minute):
            return String(format: "Daily %02d:%02d", hour, minute)
        case .weekly(let weekday, let hour, let minute):
            let dayNames = ["", "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
            let day = (weekday >= 1 && weekday <= 7) ? dayNames[weekday] : "?"
            return String(format: "Weekly %@ %02d:%02d", day, hour, minute)
        }
    }

    var icon: String {
        switch self {
        case .interval: return "arrow.clockwise"
        case .daily: return "sun.max"
        case .weekly: return "calendar"
        }
    }
}

// MARK: - ScheduleType Codable

extension ScheduleType: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, minutes, hour, minute, weekday
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .interval(let minutes):
            try container.encode("interval", forKey: .type)
            try container.encode(minutes, forKey: .minutes)
        case .daily(let hour, let minute):
            try container.encode("daily", forKey: .type)
            try container.encode(hour, forKey: .hour)
            try container.encode(minute, forKey: .minute)
        case .weekly(let weekday, let hour, let minute):
            try container.encode("weekly", forKey: .type)
            try container.encode(weekday, forKey: .weekday)
            try container.encode(hour, forKey: .hour)
            try container.encode(minute, forKey: .minute)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "interval":
            let minutes = try container.decode(Int.self, forKey: .minutes)
            self = .interval(minutes: minutes)
        case "daily":
            let hour = try container.decode(Int.self, forKey: .hour)
            let minute = try container.decode(Int.self, forKey: .minute)
            self = .daily(hour: hour, minute: minute)
        case "weekly":
            let weekday = try container.decode(Int.self, forKey: .weekday)
            let hour = try container.decode(Int.self, forKey: .hour)
            let minute = try container.decode(Int.self, forKey: .minute)
            self = .weekly(weekday: weekday, hour: hour, minute: minute)
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: container,
                debugDescription: "Unknown schedule type: \(type)")
        }
    }
}

// MARK: - Agent Schedule

/// A persisted schedule definition for an agent.
struct AgentSchedule: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var agentName: String
    var prompt: String
    var scheduleType: ScheduleType
    var isEnabled: Bool = true
    var maxConcurrentSessions: Int = 3
    var scope: AgentScope
    var projectPath: String?
    var createdAt: Date = Date()
    var lastExecutedAt: Date?
    var lastError: String?

    /// Derive the expected agent file path from scope, projectPath, and agentName.
    var agentFilePath: String? {
        switch scope {
        case .project:
            guard let projectPath else { return nil }
            return URL(filePath: projectPath)
                .appending(path: ".claude/agents/\(agentName).md")
                .path(percentEncoded: false)
        case .user:
            return FileManager.default.homeDirectoryForCurrentUser
                .appending(path: ".claude/agents/\(agentName).md")
                .path(percentEncoded: false)
        case .cloud:
            return nil // Cloud schedules don't have local agent files
        }
    }
}

// MARK: - Schedule Execution

/// Records a single execution of a schedule (for history tracking).
struct ScheduleExecution: Identifiable, Codable {
    let id: UUID
    let scheduleId: UUID
    let agentName: String
    let executedAt: Date
    let sessionId: UUID?
    let status: ExecutionStatus
    let errorMessage: String?
    let isCatchUp: Bool

    enum ExecutionStatus: String, Codable {
        case success
        case failed
        case skipped
    }

    init(
        id: UUID = UUID(),
        scheduleId: UUID,
        agentName: String,
        executedAt: Date = Date(),
        sessionId: UUID? = nil,
        status: ExecutionStatus,
        errorMessage: String? = nil,
        isCatchUp: Bool = false
    ) {
        self.id = id
        self.scheduleId = scheduleId
        self.agentName = agentName
        self.executedAt = executedAt
        self.sessionId = sessionId
        self.status = status
        self.errorMessage = errorMessage
        self.isCatchUp = isCatchUp
    }
}
