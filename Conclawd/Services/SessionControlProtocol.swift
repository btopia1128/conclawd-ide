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
    var path: String?
    /// `$CONCLAWD_SESSION_ID` of the session that ran the CLI, so `split` can
    /// launch the new session with the same agent and model.
    var sourceSessionId: String?
    /// `split --agent`: agent name or absolute path to its `.md` file. The new
    /// session runs that agent instead of the requesting session's.
    var agent: String?
    /// `split --agent`: the CLI's current directory. Agent names are looked up
    /// in its `.claude/agents/`, and it is the fallback working directory when
    /// neither `--cwd` nor the agent provides one. (`cwd` is only sent when
    /// `--cwd` was given, so a project agent starts in its own project root.)
    var callerDirectory: String?
}

/// Error reported back to the CLI as the response's `error` text.
struct SessionControlError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct SessionControlResponse: Codable, Sendable {
    var ok: Bool
    var sessionId: String?
    var error: String?
    /// `add-project` only: true when the directory was already registered.
    var alreadyRegistered: Bool? = nil
}
