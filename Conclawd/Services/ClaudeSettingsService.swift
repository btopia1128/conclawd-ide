import Foundation

/// Reads and writes `~/.claude/settings.json` for Claude Code configuration.
final class ClaudeSettingsService: Sendable {

    static let shared = ClaudeSettingsService()

    private var settingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
    }

    // MARK: - Read

    func loadSettings() -> [String: Any] {
        guard let data = try? Data(contentsOf: settingsURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return json
    }

    // MARK: - Write

    func saveSettings(_ settings: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys]) else {
            return
        }
        try? data.write(to: settingsURL, options: .atomic)
    }

    // MARK: - Hooks Helpers

    func getHooks() -> [String: Any] {
        let settings = loadSettings()
        return settings["hooks"] as? [String: Any] ?? [:]
    }

    func setHooks(_ hooks: [String: Any]) {
        var settings = loadSettings()
        settings["hooks"] = hooks
        saveSettings(settings)
    }

    /// Returns true if a notification hook exists for the given event.
    func hasNotificationHook(event: String) -> Bool {
        let hooks = getHooks()
        guard let eventHooks = hooks[event] as? [[String: Any]] else { return false }
        return eventHooks.contains { hookGroup in
            guard let innerHooks = hookGroup["hooks"] as? [[String: Any]] else { return false }
            return innerHooks.contains { hook in
                guard let command = hook["command"] as? String else { return false }
                return command.contains("display notification")
            }
        }
    }

    /// Sets or removes a notification hook for the given event.
    func setNotificationHook(event: String, enabled: Bool, message: String, sound: String?) {
        var hooks = getHooks()

        if enabled {
            var osascript = "osascript -e 'display notification \"\(message)\" with title \"Claude Code\""
            if let sound, !sound.isEmpty {
                osascript += " sound name \"\(sound)\""
            }
            osascript += "'"

            let hook: [String: Any] = [
                "hooks": [
                    [
                        "type": "command",
                        "command": osascript
                    ]
                ]
            ]

            // Replace existing notification hook or add new one
            if var eventHooks = hooks[event] as? [[String: Any]] {
                // Remove existing notification hooks
                eventHooks.removeAll { hookGroup in
                    guard let innerHooks = hookGroup["hooks"] as? [[String: Any]] else { return false }
                    return innerHooks.contains { ($0["command"] as? String)?.contains("display notification") == true }
                }
                eventHooks.append(hook)
                hooks[event] = eventHooks
            } else {
                hooks[event] = [hook]
            }
        } else {
            // Remove notification hooks for this event
            if var eventHooks = hooks[event] as? [[String: Any]] {
                eventHooks.removeAll { hookGroup in
                    guard let innerHooks = hookGroup["hooks"] as? [[String: Any]] else { return false }
                    return innerHooks.contains { ($0["command"] as? String)?.contains("display notification") == true }
                }
                if eventHooks.isEmpty {
                    hooks.removeValue(forKey: event)
                } else {
                    hooks[event] = eventHooks
                }
            }
        }

        setHooks(hooks)
    }

    /// Reads the notification message for a given hook event.
    func getNotificationMessage(event: String) -> String? {
        guard let command = findNotificationCommand(event: event) else { return nil }
        // Command looks like: osascript -e 'display notification "MSG" with title "Claude Code" ...'
        if let range = command.range(of: "display notification \""),
           let endRange = command.range(of: "\"", range: range.upperBound..<command.endIndex) {
            return String(command[range.upperBound..<endRange.lowerBound])
        }
        return nil
    }

    /// Reads the notification sound for a given hook event.
    func getNotificationSound(event: String) -> String? {
        guard let command = findNotificationCommand(event: event) else { return nil }
        if let range = command.range(of: "sound name \""),
           let endRange = command.range(of: "\"", range: range.upperBound..<command.endIndex) {
            return String(command[range.upperBound..<endRange.lowerBound])
        }
        return nil
    }

    // MARK: - Codex Skill Sync Hook

    private static let codexSyncMarker = "sync-skills-to-codex.sh"

    /// Returns true if the Codex skill sync hook is installed.
    func hasCodexSyncHook() -> Bool {
        let hooks = getHooks()
        guard let eventHooks = hooks["Stop"] as? [[String: Any]] else { return false }
        return eventHooks.contains { hookGroup in
            guard let innerHooks = hookGroup["hooks"] as? [[String: Any]] else { return false }
            return innerHooks.contains { hook in
                guard let command = hook["command"] as? String else { return false }
                return command.contains(Self.codexSyncMarker)
            }
        }
    }

    /// Installs or removes the Codex skill sync hook.
    func setCodexSyncHook(enabled: Bool, scriptPath: String) {
        var hooks = getHooks()

        if enabled {
            let hook: [String: Any] = [
                "hooks": [
                    [
                        "type": "command",
                        "command": scriptPath
                    ]
                ]
            ]

            if var eventHooks = hooks["Stop"] as? [[String: Any]] {
                eventHooks.removeAll { isCodexSyncHookGroup($0) }
                eventHooks.append(hook)
                hooks["Stop"] = eventHooks
            } else {
                hooks["Stop"] = [hook]
            }
        } else {
            if var eventHooks = hooks["Stop"] as? [[String: Any]] {
                eventHooks.removeAll { isCodexSyncHookGroup($0) }
                if eventHooks.isEmpty {
                    hooks.removeValue(forKey: "Stop")
                } else {
                    hooks["Stop"] = eventHooks
                }
            }
        }

        setHooks(hooks)
    }

    private func isCodexSyncHookGroup(_ hookGroup: [String: Any]) -> Bool {
        guard let innerHooks = hookGroup["hooks"] as? [[String: Any]] else { return false }
        return innerHooks.contains { ($0["command"] as? String)?.contains(Self.codexSyncMarker) == true }
    }

    // MARK: - Skill Usage Hook

    private static let skillUsageMarker = "log-skill-usage.sh"

    /// Returns true if the skill usage tracking hook is installed.
    func hasSkillUsageHook() -> Bool {
        let hooks = getHooks()
        guard let eventHooks = hooks["PostToolUse"] as? [[String: Any]] else { return false }
        return eventHooks.contains { hookGroup in
            guard let innerHooks = hookGroup["hooks"] as? [[String: Any]] else { return false }
            return innerHooks.contains { hook in
                guard let command = hook["command"] as? String else { return false }
                return command.contains(Self.skillUsageMarker)
            }
        }
    }

    /// Installs or removes the skill usage tracking hook.
    func setSkillUsageHook(enabled: Bool, scriptPath: String) {
        var hooks = getHooks()

        if enabled {
            let hook: [String: Any] = [
                "matcher": "Skill",
                "hooks": [
                    [
                        "type": "command",
                        "command": scriptPath
                    ]
                ]
            ]

            if var eventHooks = hooks["PostToolUse"] as? [[String: Any]] {
                eventHooks.removeAll { isSkillUsageHookGroup($0) }
                eventHooks.append(hook)
                hooks["PostToolUse"] = eventHooks
            } else {
                hooks["PostToolUse"] = [hook]
            }
        } else {
            if var eventHooks = hooks["PostToolUse"] as? [[String: Any]] {
                eventHooks.removeAll { isSkillUsageHookGroup($0) }
                if eventHooks.isEmpty {
                    hooks.removeValue(forKey: "PostToolUse")
                } else {
                    hooks["PostToolUse"] = eventHooks
                }
            }
        }

        setHooks(hooks)
    }

    private func isSkillUsageHookGroup(_ hookGroup: [String: Any]) -> Bool {
        guard let innerHooks = hookGroup["hooks"] as? [[String: Any]] else { return false }
        return innerHooks.contains { ($0["command"] as? String)?.contains(Self.skillUsageMarker) == true }
    }

    private func findNotificationCommand(event: String) -> String? {
        let hooks = getHooks()
        guard let eventHooks = hooks[event] as? [[String: Any]] else { return nil }
        for hookGroup in eventHooks {
            guard let innerHooks = hookGroup["hooks"] as? [[String: Any]] else { continue }
            for hook in innerHooks {
                guard let command = hook["command"] as? String,
                      command.contains("display notification") else { continue }
                return command
            }
        }
        return nil
    }
}
