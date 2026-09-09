import Foundation

/// A single logged skill invocation.
struct SkillUsageEntry: Identifiable {
    let id = UUID()
    let skill: String
    let date: Date
}

/// Tracks skill usage by installing a Claude Code PostToolUse hook
/// that logs each Skill invocation to a JSONL file.
@Observable
@MainActor
final class SkillUsageService {

    // MARK: - State

    private(set) var usageCounts: [String: Int] = [:]
    private(set) var usageEntries: [SkillUsageEntry] = []

    // MARK: - Paths

    private static let logFileName = "skill_usage.jsonl"

    private var appDir: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appending(path: "Conclawd")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private var logURL: URL {
        appDir.appending(path: Self.logFileName)
    }

    private var hookScriptURL: URL {
        let dir = appDir.appending(path: "hooks")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appending(path: "log-skill-usage.sh")
    }

    // MARK: - Usage Counts

    func loadUsageCounts() {
        guard FileManager.default.fileExists(atPath: logURL.path(percentEncoded: false)),
              let data = try? Data(contentsOf: logURL),
              let text = String(data: data, encoding: .utf8) else {
            usageCounts = [:]
            usageEntries = []
            return
        }

        let isoFormatter = ISO8601DateFormatter()
        var counts: [String: Int] = [:]
        var entries: [SkillUsageEntry] = []
        for line in text.components(separatedBy: .newlines) where !line.isEmpty {
            guard let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let skill = json["skill"] as? String, !skill.isEmpty else { continue }
            counts[skill, default: 0] += 1
            if let ts = json["timestamp"] as? String,
               let date = isoFormatter.date(from: ts) {
                entries.append(SkillUsageEntry(skill: skill, date: date))
            }
        }
        usageCounts = counts
        usageEntries = entries
    }

    func count(for skillName: String) -> Int {
        usageCounts[skillName, default: 0]
    }

    /// Entries on or after the given date (nil = all).
    func entries(since date: Date?) -> [SkillUsageEntry] {
        guard let date else { return usageEntries }
        return usageEntries.filter { $0.date >= date }
    }

    // MARK: - Hook Management

    var isHookInstalled: Bool {
        ClaudeSettingsService.shared.hasSkillUsageHook()
    }

    func installHook() {
        let logPath = logURL.path(percentEncoded: false)

        let script = """
        #!/bin/bash
        /usr/bin/python3 -c "
        import sys, json, datetime, os
        data = json.load(sys.stdin)
        skill = data.get('tool_input', {}).get('skill', '')
        if not skill:
            sys.exit(0)
        ts = datetime.datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ')
        entry = json.dumps({'timestamp': ts, 'skill': skill})
        log_dir = os.path.dirname('\(logPath)')
        os.makedirs(log_dir, exist_ok=True)
        with open('\(logPath)', 'a') as f:
            f.write(entry + chr(10))
        "
        """

        try? script.write(to: hookScriptURL, atomically: true, encoding: .utf8)

        // Make executable
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: hookScriptURL.path(percentEncoded: false)
        )

        ClaudeSettingsService.shared.setSkillUsageHook(
            enabled: true,
            scriptPath: hookScriptURL.path(percentEncoded: false)
        )
    }

    /// Re-installs the hook if an earlier install wrote the script path
    /// unquoted — the hook command runs through a shell, so the space in
    /// "Application Support" made every invocation fail silently.
    func repairHookIfNeeded() {
        guard isHookInstalled,
              let command = ClaudeSettingsService.shared.skillUsageHookCommand(),
              !command.hasPrefix("\"") else { return }
        installHook()
    }

    func uninstallHook() {
        ClaudeSettingsService.shared.setSkillUsageHook(enabled: false, scriptPath: "")
        try? FileManager.default.removeItem(at: hookScriptURL)
    }
}
