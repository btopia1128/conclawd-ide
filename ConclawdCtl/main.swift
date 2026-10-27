import Foundation

// conclawd — helper CLI bundled inside Conclawd.app (Contents/Helpers).
// Sends one JSON request line to the running app's Unix domain socket, waits
// for the response, and reports the outcome. Sessions launched by Conclawd
// receive the binary's path in $CONCLAWD_CLI and the socket path in
// $CONCLAWD_SOCKET.

let usage = """
usage: conclawd split --title <title> (--prompt <text> | --prompt-file <path>) [--cwd <dir>] [--agent <name|path>]
       conclawd open [--beside] <path>
       conclawd add-project <dir>
       conclawd preview-hook  (reads a Claude Code PostToolUse payload on stdin)
       conclawd status-hook   (reads a Claude Code hook payload on stdin)

split: Creates a new session tab in the running Conclawd app. The prompt is
submitted to the new session automatically once it finishes starting. --cwd
defaults to the current directory. Without --agent the new session runs the
same agent and model as the session that called it. --agent runs the given
agent instead (a name, looked up in <cwd>/.claude/agents/ then
~/.claude/agents/, or a path to its .md file); it then starts in --cwd if
given, otherwise in the agent's own directory (its project root).

open: Opens the file at <path> in the Conclawd editor pane. Relative paths are
resolved against the current directory. With --beside the file opens in the
pane next to the calling session (splitting the window if needed) so the
session's terminal stays visible.

add-project: Registers <dir> as a Conclawd project so the agents in its
.claude/agents/ appear in the Agents list. The current project selection is
left unchanged. Relative paths are resolved against the current directory.

preview-hook: Claude Code PostToolUse hook installed by Conclawd. When a tool
writes a previewable file (image, video, audio, HTML), it shows that file in
the pane beside the session. Never fails the hook: problems exit 0 silently.

status-hook: Claude Code hook installed by Conclawd on prompt submit, tool use,
Stop and Notification. It reports the session's state (running, done, done
with background tasks still in flight) so the sidebar status does not have
to be guessed from terminal output. Like preview-hook, it never fails.
"""

/// Extensions `preview-hook` forwards to the app. Everything else (source
/// code, Markdown, config) is ignored so ordinary edits never steal a pane.
let previewableExtensions: Set<String> = [
    "png", "jpg", "jpeg", "gif", "webp", "bmp", "tiff", "tif", "svg", "heic", "heif",
    "mp4", "mov", "m4v", "webm",
    "wav", "mp3", "m4a", "aac", "flac", "ogg",
    "html", "htm",
]

/// `preview-hook` must never surface as a hook error inside the session.
nonisolated(unsafe) var silentFailures = false

func fail(_ message: String) -> Never {
    if silentFailures { exit(0) }
    FileHandle.standardError.write(Data("conclawd: \(message)\n".utf8))
    exit(1)
}

var arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first, command != "-h", command != "--help" else {
    print(usage)
    exit(arguments.isEmpty ? 64 : 0)
}
arguments.removeFirst()

var title: String?
var prompt: String?
var cwd: String?
var openPath: String?
var agent: String?
var beside = false
var hookEvent: String?
var notificationType: String?
var backgroundTasks: [String]?

switch command {
case "split":
    var index = 0
    while index < arguments.count {
        let flag = arguments[index]
        func value() -> String {
            index += 1
            guard index < arguments.count else { fail("missing value for \(flag)") }
            return arguments[index]
        }
        switch flag {
        case "--title":
            title = value()
        case "--prompt":
            prompt = value()
        case "--prompt-file":
            let path = value()
            guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else {
                fail("cannot read prompt file: \(path)")
            }
            prompt = contents
        case "--cwd":
            cwd = value()
        case "--agent":
            let spec = value()
            // Resolve paths here — the app has a different working directory.
            agent = spec.contains("/") || spec.hasSuffix(".md")
                ? URL(fileURLWithPath: spec).standardizedFileURL.path
                : spec
        case "-h", "--help":
            print(usage)
            exit(0)
        default:
            fail("unknown option '\(flag)'\n\(usage)")
        }
        index += 1
    }
    guard let promptValue = prompt,
          !promptValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        fail("a non-empty prompt is required (--prompt or --prompt-file)")
    }
case "open":
    if let flagIndex = arguments.firstIndex(of: "--beside") {
        beside = true
        arguments.remove(at: flagIndex)
    }
    guard arguments.count == 1, let rawPath = arguments.first, !rawPath.isEmpty else {
        fail("open takes exactly one file path\n\(usage)")
    }
    if rawPath == "-h" || rawPath == "--help" {
        print(usage)
        exit(0)
    }
    // Resolve relative paths here — the app has a different working directory.
    openPath = URL(fileURLWithPath: rawPath).standardizedFileURL.path
case "add-project":
    guard arguments.count == 1, let rawPath = arguments.first, !rawPath.isEmpty else {
        fail("add-project takes exactly one directory path\n\(usage)")
    }
    if rawPath == "-h" || rawPath == "--help" {
        print(usage)
        exit(0)
    }
    openPath = URL(fileURLWithPath: rawPath).standardizedFileURL.path
case "preview-hook":
    silentFailures = true
    let input = FileHandle.standardInput.readDataToEndOfFile()
    guard let payload = try? JSONSerialization.jsonObject(with: input) as? [String: Any],
          let toolInput = payload["tool_input"] as? [String: Any],
          let rawPath = (toolInput["file_path"] as? String) ?? (toolInput["notebook_path"] as? String),
          !rawPath.isEmpty else { exit(0) }
    let base = (payload["cwd"] as? String) ?? FileManager.default.currentDirectoryPath
    let url = rawPath.hasPrefix("/")
        ? URL(fileURLWithPath: rawPath)
        : URL(fileURLWithPath: base).appendingPathComponent(rawPath)
    guard previewableExtensions.contains(url.pathExtension.lowercased()) else { exit(0) }
    openPath = url.standardizedFileURL.path
case "status-hook":
    silentFailures = true
    let input = FileHandle.standardInput.readDataToEndOfFile()
    guard ProcessInfo.processInfo.environment["CONCLAWD_SESSION_ID"] != nil,
          let payload = try? JSONSerialization.jsonObject(with: input) as? [String: Any],
          let event = payload["hook_event_name"] as? String else { exit(0) }
    // Subagent tool calls fire the same hooks (with `agent_id`; a `--agent`
    // session carries only `agent_type`). Only the main agent decides the status.
    if payload["agent_id"] != nil { exit(0) }
    hookEvent = event
    notificationType = payload["notification_type"] as? String
    if event == "Stop" {
        let tasks = payload["background_tasks"] as? [[String: Any]] ?? []
        backgroundTasks = tasks.map { task in
            (task["description"] as? String) ?? (task["command"] as? String) ?? (task["type"] as? String) ?? "task"
        }
    }
default:
    fail("unknown command '\(command)'\n\(usage)")
}

let request = SessionControlRequest(
    command: command == "preview-hook" ? "preview" : command == "status-hook" ? "status" : command,
    title: title,
    prompt: prompt,
    // With --agent, an implicit cwd is left to the agent's own directory.
    cwd: command == "split"
        ? (cwd.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
            ?? (agent == nil ? FileManager.default.currentDirectoryPath : nil))
        : nil,
    path: openPath,
    sourceSessionId: (command == "split" || command == "preview-hook" || command == "status-hook" || beside) ? ProcessInfo.processInfo.environment["CONCLAWD_SESSION_ID"] : nil,
    agent: agent,
    callerDirectory: agent == nil ? nil : FileManager.default.currentDirectoryPath,
    beside: beside ? true : nil,
    hookEvent: hookEvent,
    notificationType: notificationType,
    backgroundTasks: backgroundTasks
)

let socketPath = ProcessInfo.processInfo.environment["CONCLAWD_SOCKET"]
    ?? SessionControlProtocol.defaultSocketPath

// Encode before connecting so the payload goes out immediately after connect().
guard var payload = try? JSONEncoder().encode(request) else { fail("failed to encode request") }
payload.append(0x0A)

let fd = socket(AF_UNIX, SOCK_STREAM, 0)
guard fd >= 0 else { fail("socket() failed") }

var addr = sockaddr_un()
addr.sun_family = sa_family_t(AF_UNIX)
let maxLength = MemoryLayout.size(ofValue: addr.sun_path) - 1
guard socketPath.utf8.count <= maxLength else { fail("socket path too long: \(socketPath)") }
withUnsafeMutableBytes(of: &addr.sun_path) { raw in
    socketPath.withCString { cString in
        _ = strncpy(raw.baseAddress!.assumingMemoryBound(to: CChar.self), cString, maxLength)
    }
}
let connected = withUnsafePointer(to: &addr) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
    }
}
guard connected == 0 else {
    fail("cannot reach the Conclawd app at \(socketPath) — is Conclawd running?")
}

var one: Int32 = 1
setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
// The hook blocks the session until it returns, so keep it short.
var timeout = timeval(tv_sec: command.hasSuffix("-hook") ? 3 : 15, tv_usec: 0)
setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

let sent = payload.withUnsafeBytes { raw -> Bool in
    var offset = 0
    while offset < raw.count {
        let n = write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
        guard n > 0 else { return false }
        offset += n
    }
    return true
}
guard sent else { fail("failed to send request") }
shutdown(fd, SHUT_WR)

var responseData = Data()
var buffer = [UInt8](repeating: 0, count: 4096)
while responseData.count < 1_048_576 {
    let n = read(fd, &buffer, buffer.count)
    guard n > 0 else { break }
    responseData.append(contentsOf: buffer[0..<n])
    if buffer[0..<n].contains(0x0A) { break }
}
close(fd)
if let newline = responseData.firstIndex(of: 0x0A) {
    responseData = responseData.prefix(upTo: newline)
}

guard let response = try? JSONDecoder().decode(SessionControlResponse.self, from: responseData) else {
    fail("no response from Conclawd (timed out or malformed reply)")
}

if response.ok {
    switch command {
    case "preview-hook", "status-hook":
        break
    case "open":
        print(beside
            ? "Opened \(openPath ?? "the file") in the Conclawd pane beside this session."
            : "Opened \(openPath ?? "the file") in the Conclawd editor.")
    case "add-project":
        if response.alreadyRegistered == true {
            print("\(openPath ?? "The directory") is already a Conclawd project.")
        } else {
            print("Added \(openPath ?? "the directory") as a Conclawd project.")
        }
    default:
        let label = title.map { " \"\($0)\"" } ?? ""
        let agentLabel = agent.map { " running agent \($0)" } ?? ""
        print("Created new session tab\(label)\(agentLabel). "
            + "The handoff prompt will be submitted automatically once the session is ready.")
    }
} else {
    fail(response.error ?? "unknown error")
}
