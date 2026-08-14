import Foundation

/// Persistent, human-readable diagnostics log for memory extraction.
/// os.Logger info-level messages are not persisted by default and `print()` is
/// invisible in a GUI app, so extraction problems (wrong provider, CLI not found,
/// parse failures) were impossible to diagnose after the fact. This writes every
/// extraction decision to a plain-text file the user can open from Settings.
///
/// Log file: ~/Library/Application Support/Conclawd/logs/memory-extraction.log
final class MemoryExtractionLog: @unchecked Sendable {

    static let shared = MemoryExtractionLog()

    static var logFileURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appending(path: "Conclawd/logs/memory-extraction.log")
    }

    /// Trim the file back to `trimmedSize` once it exceeds `maxFileSize`.
    private let maxFileSize = 512 * 1024
    private let trimmedSize = 256 * 1024

    private let queue = DispatchQueue(label: "com.conclawd.memory-extraction-log")

    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    func log(_ message: String) {
        let line = "[\(dateFormatter.string(from: Date()))] \(message)\n"
        queue.async { self.append(line) }
    }

    func warn(_ message: String) {
        log("WARN: \(message)")
    }

    func error(_ message: String) {
        log("ERROR: \(message)")
    }

    /// Ensure the log file exists on disk (so "Open Log" works before the first write).
    func ensureFileExists() {
        queue.sync {
            let url = Self.logFileURL
            let fm = FileManager.default
            guard !fm.fileExists(atPath: url.path(percentEncoded: false)) else { return }
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            fm.createFile(atPath: url.path(percentEncoded: false), contents: nil)
        }
    }

    // MARK: - Private

    private func append(_ line: String) {
        let url = Self.logFileURL
        let fm = FileManager.default
        guard let data = line.data(using: .utf8) else { return }

        if !fm.fileExists(atPath: url.path(percentEncoded: false)) {
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            fm.createFile(atPath: url.path(percentEncoded: false), contents: nil)
        }

        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)

        trimIfNeeded(at: url)
    }

    private func trimIfNeeded(at url: URL) {
        guard let size = try? FileManager.default
            .attributesOfItem(atPath: url.path(percentEncoded: false))[.size] as? Int,
            size > maxFileSize,
            let data = try? Data(contentsOf: url) else { return }

        var trimmed = data.suffix(trimmedSize)
        // Cut at the next newline so the file doesn't start mid-line
        if let newlineIndex = trimmed.firstIndex(of: UInt8(ascii: "\n")) {
            trimmed = trimmed.suffix(from: trimmed.index(after: newlineIndex))
        }
        try? trimmed.write(to: url)
    }
}
