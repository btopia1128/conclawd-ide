import Foundation

/// Persistent, human-readable diagnostics log for session process lifecycle.
/// Sessions have been observed dying from an unidentified SIGTERM sender
/// (2026-08-07); this records every process start, every stop()/forceKill()
/// call with its reason, and every termination with a decoded exit status so
/// the next occurrence can be attributed after the fact.
///
/// Log file: ~/Library/Application Support/Conclawd/logs/session-diagnostics.log
///
/// Multiple app instances (Release + Xcode Debug) share this file, so every
/// line carries the writing instance's pid and build kind.
final class SessionDiagnosticsLog: @unchecked Sendable {

    static let shared = SessionDiagnosticsLog()

    static var logFileURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appending(path: "Conclawd/logs/session-diagnostics.log")
    }

    /// Trim the file back to `trimmedSize` once it exceeds `maxFileSize`.
    private let maxFileSize = 512 * 1024
    private let trimmedSize = 256 * 1024

    private let queue = DispatchQueue(label: "com.conclawd.session-diagnostics-log")

    /// Identifies which app instance wrote a line, since Release and Debug
    /// builds share the same log file.
    private let instanceTag: String = {
        let kind = Bundle.main.bundlePath.contains("DerivedData") ? "dev" : "app"
        return "\(kind):\(getpid())"
    }()

    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    func log(_ message: String) {
        let line = "[\(dateFormatter.string(from: Date()))] [\(instanceTag)] \(message)\n"
        queue.async { self.append(line) }
    }

    /// Human-readable decoding of the value SwiftTerm reports on termination,
    /// which is a raw waitpid(2) status. e.g. 36608 → "exit 143 (SIGTERM)".
    static func describeExitCode(_ code: Int32?) -> String {
        guard let code else { return "nil" }
        let signal = code & 0x7f
        if signal != 0 {
            return "raw \(code) = killed by signal \(signal) (\(signalName(signal)))"
        }
        let status = (code >> 8) & 0xff
        if status > 128 {
            return "raw \(code) = exit \(status) (128+\(status - 128) → \(signalName(status - 128)))"
        }
        return "raw \(code) = exit \(status)"
    }

    private static func signalName(_ signal: Int32) -> String {
        if let cName = strsignal(signal) {
            return String(cString: cName)
        }
        return "signal \(signal)"
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
