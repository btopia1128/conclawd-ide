import Foundation

// conclawd — helper CLI bundled inside Conclawd.app (Contents/Helpers).
// Sends one JSON request line to the running app's Unix domain socket, waits
// for the response, and reports the outcome. Sessions launched by Conclawd
// receive the binary's path in $CONCLAWD_CLI and the socket path in
// $CONCLAWD_SOCKET.

let usage = """
usage: conclawd split --title <title> (--prompt <text> | --prompt-file <path>) [--cwd <dir>]

Creates a new session tab in the running Conclawd app. The prompt is submitted
to the new session automatically once it finishes starting. --cwd defaults to
the current directory.
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("conclawd: \(message)\n".utf8))
    exit(1)
}

var arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first, command != "-h", command != "--help" else {
    print(usage)
    exit(arguments.isEmpty ? 64 : 0)
}
arguments.removeFirst()

guard command == "split" else {
    fail("unknown command '\(command)'\n\(usage)")
}

var title: String?
var prompt: String?
var cwd: String?

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
    case "-h", "--help":
        print(usage)
        exit(0)
    default:
        fail("unknown option '\(flag)'\n\(usage)")
    }
    index += 1
}

guard let prompt, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
    fail("a non-empty prompt is required (--prompt or --prompt-file)")
}

let request = SessionControlRequest(
    command: "split",
    title: title,
    prompt: prompt,
    cwd: cwd ?? FileManager.default.currentDirectoryPath
)

let socketPath = ProcessInfo.processInfo.environment["CONCLAWD_SOCKET"]
    ?? SessionControlProtocol.defaultSocketPath

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
var timeout = timeval(tv_sec: 15, tv_usec: 0)
setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

guard var payload = try? JSONEncoder().encode(request) else { fail("failed to encode request") }
payload.append(0x0A)
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
    let label = title.map { " \"\($0)\"" } ?? ""
    print("Created new session tab\(label). "
        + "The handoff prompt will be submitted automatically once the session is ready.")
} else {
    fail(response.error ?? "unknown error")
}
