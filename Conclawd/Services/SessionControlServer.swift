import Foundation

/// Listens on a Unix domain socket for requests from the bundled `conclawd`
/// helper CLI (invoked by Claude inside a session, e.g. via the
/// conclawd-session-split skill) and forwards them to AppState.
///
/// Socket I/O runs on a private serial queue; `onRequest` is invoked on the
/// main actor and its return value is written back to the waiting CLI, which
/// blocks until it gets the response — that round trip is what makes the
/// helper CLI bidirectional.
final class SessionControlServer: @unchecked Sendable {

    /// Handles a decoded request and returns the response to send back.
    var onRequest: (@MainActor (SessionControlRequest) -> SessionControlResponse)?

    private let queue = DispatchQueue(label: "com.conclawd.session-control")
    private let socketPath = SessionControlProtocol.defaultSocketPath
    private var listenFd: Int32 = -1
    private var acceptSource: DispatchSourceRead?

    deinit {
        acceptSource?.cancel()
        unlink(socketPath)
    }

    func start() {
        queue.async { [self] in startOnQueue() }
    }

    private func startOnQueue() {
        guard listenFd < 0 else { return }

        let directory = (socketPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true)
        // A stale socket file from a previous run blocks bind().
        unlink(socketPath)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            print("[SessionControlServer] socket() failed: \(String(cString: strerror(errno)))")
            return
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxLength = MemoryLayout.size(ofValue: addr.sun_path) - 1
        guard socketPath.utf8.count <= maxLength else {
            print("[SessionControlServer] socket path too long: \(socketPath)")
            close(fd)
            return
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            socketPath.withCString { cString in
                _ = strncpy(raw.baseAddress!.assumingMemoryBound(to: CChar.self), cString, maxLength)
            }
        }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(fd, 4) == 0 else {
            print("[SessionControlServer] bind/listen failed: \(String(cString: strerror(errno)))")
            close(fd)
            return
        }
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)

        listenFd = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptPending() }
        source.setCancelHandler { close(fd) }
        source.resume()
        acceptSource = source
    }

    private func acceptPending() {
        while true {
            let clientFd = accept(listenFd, nil, nil)
            guard clientFd >= 0 else { return }
            var one: Int32 = 1
            setsockopt(clientFd, SOL_SOCKET, SO_NOSIGPIPE, &one,
                       socklen_t(MemoryLayout<Int32>.size))
            var timeout = timeval(tv_sec: 5, tv_usec: 0)
            setsockopt(clientFd, SOL_SOCKET, SO_RCVTIMEO, &timeout,
                       socklen_t(MemoryLayout<timeval>.size))
            setsockopt(clientFd, SOL_SOCKET, SO_SNDTIMEO, &timeout,
                       socklen_t(MemoryLayout<timeval>.size))
            handleConnection(fd: clientFd)
        }
    }

    private func handleConnection(fd: Int32) {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while data.count < 1_048_576 {
            let n = read(fd, &buffer, buffer.count)
            guard n > 0 else { break }
            data.append(contentsOf: buffer[0..<n])
            if buffer[0..<n].contains(0x0A) { break }
        }
        if let newline = data.firstIndex(of: 0x0A) {
            data = data.prefix(upTo: newline)
        }

        guard !data.isEmpty,
              let request = try? JSONDecoder().decode(SessionControlRequest.self, from: data) else {
            writeResponse(SessionControlResponse(ok: false, sessionId: nil, error: "invalid request"), to: fd)
            return
        }

        DispatchQueue.main.async { [weak self] in
            let response = MainActor.assumeIsolated {
                self?.onRequest?(request)
                    ?? SessionControlResponse(ok: false, sessionId: nil, error: "Conclawd is not ready")
            }
            guard let self else {
                close(fd)
                return
            }
            self.queue.async { self.writeResponse(response, to: fd) }
        }
    }

    private func writeResponse(_ response: SessionControlResponse, to fd: Int32) {
        defer { close(fd) }
        guard var payload = try? JSONEncoder().encode(response) else { return }
        payload.append(0x0A)
        payload.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                guard n > 0 else { break }
                offset += n
            }
        }
    }
}
