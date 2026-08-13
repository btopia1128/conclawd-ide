import Foundation

// MARK: - Cloud Trigger (RemoteTrigger API Response)

/// Represents a cloud-based scheduled trigger from the Anthropic RemoteTrigger API.
/// Maps to `GET/POST /v1/code/triggers` responses.
struct CloudTrigger: Identifiable, Codable, Hashable {
    let id: String                  // e.g. "trig_..."
    var name: String
    var cronExpression: String
    var enabled: Bool
    var persistSession: Bool?
    var jobConfig: JobConfig
    var mcpConnections: [MCPConnection]?
    let createdAt: String?
    var updatedAt: String?
    var nextRunAt: String?
    var creator: Creator?

    // MARK: - Nested Types

    struct JobConfig: Codable, Hashable {
        var ccr: CCR

        struct CCR: Codable, Hashable {
            var environmentId: String?
            var sessionContext: SessionContext?
            var events: [Event]?

            struct SessionContext: Codable, Hashable {
                var model: String?
                var allowedTools: [String]?
                var appendSystemPrompt: String?
            }

            struct Event: Codable, Hashable {
                var data: EventData?

                struct EventData: Codable, Hashable {
                    var uuid: String?
                    var sessionId: String?
                    var type: String?
                    var parentToolUseId: String?
                    var message: EventMessage?

                    struct EventMessage: Codable, Hashable {
                        var content: String?
                        var role: String?
                    }
                }
            }
        }
    }

    struct MCPConnection: Codable, Hashable {
        var name: String?
        var url: String?
    }

    struct Creator: Codable, Hashable {
        var id: String?
        var name: String?
        var email: String?
    }

    // MARK: - Computed Properties

    /// The prompt text from the first event message.
    var prompt: String? {
        jobConfig.ccr.events?.first?.data?.message?.content
    }

    /// The model used for this trigger.
    var model: String? {
        jobConfig.ccr.sessionContext?.model
    }

    /// The environment ID (defaults to "default").
    var environmentId: String {
        jobConfig.ccr.environmentId ?? "default"
    }

    /// Human-readable cron description.
    var cronDisplayName: String {
        CronFormatter.describe(cronExpression)
    }

    /// Parsed next run date.
    var nextRunDate: Date? {
        guard let nextRunAt else { return nil }
        return Self.iso8601Formatter.date(from: nextRunAt)
    }

    /// Parsed creation date.
    var createdDate: Date? {
        guard let createdAt else { return nil }
        return Self.iso8601Formatter.date(from: createdAt)
    }

    private static nonisolated(unsafe) let iso8601Formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}

// MARK: - Create Request Body

/// Body for `POST /v1/code/triggers` (create).
struct CloudTriggerCreateRequest: Codable {
    var name: String
    var cronExpression: String
    var enabled: Bool
    var jobConfig: CloudTrigger.JobConfig

    /// Build a create request with the essential fields.
    static func build(
        name: String,
        cronExpression: String,
        enabled: Bool = true,
        prompt: String,
        model: String = "claude-sonnet-4-6",
        environmentId: String = "default",
        allowedTools: [String] = ["Bash", "Read", "Write", "Edit", "Glob", "Grep", "WebFetch", "WebSearch"]
    ) -> CloudTriggerCreateRequest {
        CloudTriggerCreateRequest(
            name: name,
            cronExpression: cronExpression,
            enabled: enabled,
            jobConfig: .init(ccr: .init(
                environmentId: environmentId,
                sessionContext: .init(
                    model: model,
                    allowedTools: allowedTools,
                    appendSystemPrompt: nil
                ),
                events: [
                    .init(data: .init(
                        uuid: UUID().uuidString.lowercased(),
                        sessionId: "",
                        type: "user",
                        parentToolUseId: nil,
                        message: .init(content: prompt, role: "user")
                    ))
                ]
            ))
        )
    }
}

// MARK: - API Response Wrapper

/// The list response from `GET /v1/code/triggers`.
struct CloudTriggerListResponse: Codable {
    let data: [CloudTrigger]?
}

// MARK: - Cron Formatter

enum CronFormatter {
    /// Convert a cron expression to a human-readable description.
    static func describe(_ cron: String) -> String {
        let parts = cron.split(separator: " ").map(String.init)
        guard parts.count == 5 else { return cron }

        let minute = parts[0]
        let hour = parts[1]
        let dayOfMonth = parts[2]
        let month = parts[3]
        let dayOfWeek = parts[4]

        // Every hour: "0 * * * *"
        if minute != "*" && hour == "*" && dayOfMonth == "*" && month == "*" && dayOfWeek == "*" {
            return "Every hour at :\(minute.paddedMinute)"
        }

        // Daily: "M H * * *"
        if minute != "*" && hour != "*" && dayOfMonth == "*" && month == "*" && dayOfWeek == "*" {
            return "Daily at \(hour.paddedHour):\(minute.paddedMinute) UTC"
        }

        // Weekdays: "M H * * 1-5"
        if minute != "*" && hour != "*" && dayOfMonth == "*" && month == "*" && dayOfWeek == "1-5" {
            return "Weekdays at \(hour.paddedHour):\(minute.paddedMinute) UTC"
        }

        // Specific day of week: "M H * * N"
        if minute != "*" && hour != "*" && dayOfMonth == "*" && month == "*" && dayOfWeek != "*" {
            let dayName = weekdayName(dayOfWeek)
            return "\(dayName) at \(hour.paddedHour):\(minute.paddedMinute) UTC"
        }

        return cron
    }

    private static func weekdayName(_ dow: String) -> String {
        switch dow {
        case "0", "7": return "Sunday"
        case "1": return "Monday"
        case "2": return "Tuesday"
        case "3": return "Wednesday"
        case "4": return "Thursday"
        case "5": return "Friday"
        case "6": return "Saturday"
        case "1-5": return "Weekdays"
        default: return dow
        }
    }
}

private extension String {
    var paddedMinute: String {
        count == 1 ? "0\(self)" : self
    }

    var paddedHour: String {
        count == 1 ? "0\(self)" : self
    }
}
