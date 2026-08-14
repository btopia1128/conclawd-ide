import Foundation

/// Wire protocol shared between the app's `SessionControlServer` and the
/// bundled `conclawd` helper CLI: one JSON request line in, one JSON response
/// line out over a Unix domain socket.
///
/// This file is compiled into both the Conclawd app target and the ConclawdCtl
/// tool target — keep it dependency-free.
enum SessionControlProtocol {
    /// Default Unix domain socket path. The app listens here; the CLI reads
    /// `$CONCLAWD_SOCKET` first so a session always talks to the app that
    /// spawned it even if the default ever changes.
    static var defaultSocketPath: String {
        NSHomeDirectory() + "/Library/Application Support/Conclawd/conclawd.sock"
    }
}

struct SessionControlRequest: Codable, Sendable {
    var command: String
    var title: String?
    var prompt: String?
    var cwd: String?
}

struct SessionControlResponse: Codable, Sendable {
    var ok: Bool
    var sessionId: String?
    var error: String?
}
