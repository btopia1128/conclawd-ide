import Foundation

/// Persists session history to disk and provides query methods for the UI.
@Observable
@MainActor
final class SessionHistoryService {

    // MARK: - Properties

    private(set) var records: [SessionRecord] = []

    private var storageURL: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = appSupport.appending(path: "Conclawd")
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        return appDir.appending(path: "session_history.json")
    }

    // MARK: - Lifecycle

    func load() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        // Try primary file first, then fall back to backup if corrupted
        let loaded: [SessionRecord]? = {
            if let data = try? Data(contentsOf: storageURL),
               let items = try? decoder.decode([SessionRecord].self, from: data) {
                return items
            }
            // Primary failed — try backup
            let backupURL = storageURL.appendingPathExtension("bak")
            if let data = try? Data(contentsOf: backupURL),
               let items = try? decoder.decode([SessionRecord].self, from: data) {
                print("[SessionHistory] Primary file corrupted, restored from backup (\(items.count) records)")
                return items
            }
            return nil
        }()
        guard let loaded else { return }
        records = loaded

        // Finalize orphaned sessions from previous runs where the app was
        // killed without graceful shutdown (e.g. Xcode restart, force-quit).
        var needsSave = false
        // Track already-claimed resume IDs to avoid assigning the same .jsonl
        // to multiple orphaned sessions in the same project.
        var claimedIds: Set<String> = Set(records.compactMap(\.claudeResumeId))
        for i in records.indices where records[i].endedAt == nil {
            records[i].endedAt = records[i].startedAt

            // Try to recover the resume ID by scanning Claude's projects directory
            // for a transcript file created around the session start time.
            if records[i].claudeResumeId == nil {
                let workingDir = records[i].projectPath
                    ?? FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false)
                if let resumeId = AgentProcessManager.findClaudeSessionId(
                    workingDirectory: workingDir, aroundTime: records[i].startedAt, excludingIds: claimedIds) {
                    records[i].claudeResumeId = resumeId
                    claimedIds.insert(resumeId)
                }
            }

            needsSave = true
        }
        if needsSave {
            save()
        }
    }

    // MARK: - Recording

    /// Records a session start. Called when a non-creation session begins.
    func recordSessionStart(session: AgentSession) {
        let record = SessionRecord(
            id: session.id,
            agentName: session.agentName,
            agentFilePath: session.agentFilePath,
            projectPath: session.workingDirectory?.path(percentEncoded: false)
                ?? SessionRecord.deriveProjectPath(from: session.agentFilePath),
            startedAt: session.startedAt,
            endedAt: nil,
            claudeResumeId: nil,
            exitCode: nil,
            cliProviderType: session.cliProviderType,
            isScheduledSession: session.isScheduledSession
        )
        records.insert(record, at: 0)
        save()
    }

    /// Finalizes a session with exit details.
    /// Safe to call multiple times — sets `endedAt` on first call and
    /// merges `exitCode`/`resumeId`/`initialPrompt` on subsequent calls so the
    /// `processTerminated` callback can fill in values that weren't
    /// available when the tab was closed.
    func finalizeSession(sessionId: UUID, exitCode: Int32?, resumeId: String?, terminalText: String? = nil) {
        guard let index = records.firstIndex(where: { $0.id == sessionId }) else {
            print("[ResumeID] finalizeSession: record not found for \(sessionId)")
            return
        }
        let existingResumeId = records[index].claudeResumeId
        print("[ResumeID] finalizeSession: incoming=\(resumeId ?? "nil") existing=\(existingResumeId ?? "nil") for \(sessionId)")
        var changed = false
        if records[index].endedAt == nil {
            records[index].endedAt = Date()
            changed = true
        }
        if let exitCode, records[index].exitCode == nil {
            records[index].exitCode = exitCode
            changed = true
        }
        if let resumeId, records[index].claudeResumeId == nil {
            records[index].claudeResumeId = resumeId
            changed = true
        }
        if records[index].initialPrompt == nil, let terminalText {
            if let prompt = Self.extractInitialPrompt(from: terminalText) {
                records[index].initialPrompt = prompt
                changed = true
            }
        }
        if changed { save() }
    }

    /// Extracts the first user prompt from Claude CLI terminal output.
    /// Strips ANSI escape sequences first, then looks for prompt indicators.
    static func extractInitialPrompt(from text: String) -> String? {
        let clean = Self.stripAnsiEscapes(text)
            .replacingOccurrences(of: "\0", with: "")
        let lines = clean.components(separatedBy: .newlines)
        // Prompt indicators used by Claude CLI (current and historical)
        let promptPrefixes: [String] = ["❯\u{00A0}", "❯ ", "> "]
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            for prefix in promptPrefixes {
                guard trimmed.hasPrefix(prefix) else { continue }
                // Skip decorative lines like "> ─────"
                let prompt = String(trimmed.dropFirst(prefix.count))
                    .trimmingCharacters(in: .whitespaces)
                if !prompt.isEmpty && !prompt.allSatisfy({ $0 == "─" || $0 == "-" }) {
                    return String(prompt.prefix(120))
                }
            }
        }
        return nil
    }

    /// Removes ANSI escape sequences (CSI, OSC, etc.) from terminal output.
    static func stripAnsiEscapes(_ text: String) -> String {
        // CSI sequences: ESC [ ... final_byte
        // OSC sequences: ESC ] ... ST
        // Simple escapes: ESC followed by a single character
        guard let regex = try? NSRegularExpression(
            pattern: "\\x1B(?:\\[[0-9;]*[A-Za-z]|\\][^\u{07}\\x1B]*(?:\u{07}|\\x1B\\\\)|[()][0-9A-Za-z]|.)",
            options: []
        ) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
    }

    /// Sets the initial prompt directly (e.g., from programmatic sendInput).
    /// Only sets if not already present.
    func setInitialPrompt(sessionId: UUID, prompt: String) {
        guard let index = records.firstIndex(where: { $0.id == sessionId }),
              records[index].initialPrompt == nil else { return }
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        records[index].initialPrompt = String(trimmed.prefix(120))
        save()
    }

    /// Marks memory extraction as completed for a session.
    func markMemoryExtracted(sessionId: UUID) {
        guard let index = records.firstIndex(where: { $0.id == sessionId }) else { return }
        records[index].memoryExtracted = true
        save()
    }

    /// Clears resume ID for a session (e.g., after successful resume or failure).
    func clearResumeId(sessionId: UUID) {
        guard let index = records.firstIndex(where: { $0.id == sessionId }) else { return }
        records[index].claudeResumeId = nil
        save()
    }

    // MARK: - Queries

    /// Returns the most recent records for a project (or all if projectPath is nil with `.all` mode).
    /// Excludes records whose IDs appear in `excludingIds`.
    func recentRecords(projectPath: String?, limit: Int = 20, resumableOnly: Bool = false, excludingIds: Set<UUID> = []) -> [SessionRecord] {
        let filtered: [SessionRecord]
        if let projectPath {
            filtered = records.filter { $0.projectPath == projectPath }
        } else {
            // nil projectPath = home agents (user-level)
            filtered = records.filter { $0.projectPath == nil }
        }
        return Array(
            filtered
                .filter { !excludingIds.contains($0.id) }
                .filter { !resumableOnly || $0.isResumable }
                .prefix(limit)
        )
    }

    /// Returns all records, optionally filtered.
    func allRecords(
        projectPath: String? = nil,
        agentName: String? = nil,
        resumableOnly: Bool = false,
        excludingIds: Set<UUID> = []
    ) -> [SessionRecord] {
        records.filter { record in
            if excludingIds.contains(record.id) { return false }
            if let projectPath, record.projectPath != projectPath { return false }
            if let agentName, !agentName.isEmpty,
               !record.agentName.localizedCaseInsensitiveContains(agentName) { return false }
            if resumableOnly, !record.isResumable { return false }
            return true
        }
    }

    // MARK: - Deletion

    /// Deletes a single record by ID.
    func deleteRecord(id: UUID) {
        records.removeAll { $0.id == id }
        save()
    }

    /// Deletes all history records.
    func deleteAllRecords() {
        records.removeAll()
        save()
    }

    // MARK: - Persistence

    private func save() {
        // Soft limit: trim to 500 records
        if records.count > 500 {
            records = Array(records.prefix(500))
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted]
        guard let data = try? encoder.encode(records) else { return }

        // Create backup of the current file before overwriting
        let backupURL = storageURL.appendingPathExtension("bak")
        try? FileManager.default.removeItem(at: backupURL)
        try? FileManager.default.copyItem(at: storageURL, to: backupURL)

        // Atomic write: writes to a temp file first, then renames.
        // Survives app crashes / force-quit mid-write.
        try? data.write(to: storageURL, options: .atomic)
    }
}
