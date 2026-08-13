import Foundation

/// Watches individual open files for external modifications and notifies via callback.
final class OpenFileWatcherService {

    private var watchers: [UUID: FileWatch] = [:]
    private let debounceInterval: TimeInterval

    /// Called when an open file is modified externally. Parameter is the file's OpenFile ID.
    var onFileChanged: ((UUID) -> Void)?

    init(debounceInterval: TimeInterval = 0.5) {
        self.debounceInterval = debounceInterval
    }

    deinit {
        stopAll()
    }

    /// Start watching a file associated with an OpenFile ID.
    func watch(id: UUID, url: URL) {
        guard watchers[id] == nil else { return }

        let path = url.path(percentEncoded: false)
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete, .extend],
            queue: .main
        )

        let watch = FileWatch(fd: fd, source: source)
        watchers[id] = watch

        source.setEventHandler { [weak self] in
            self?.handleChange(id: id)
        }

        source.setCancelHandler {
            close(fd)
        }

        source.resume()
    }

    /// Stop watching a specific file.
    func unwatch(id: UUID) {
        guard let watch = watchers.removeValue(forKey: id) else { return }
        watch.debounceWork?.cancel()
        watch.source.cancel()
    }

    /// Stop watching all files.
    func stopAll() {
        for (_, watch) in watchers {
            watch.debounceWork?.cancel()
            watch.source.cancel()
        }
        watchers.removeAll()
    }

    private func handleChange(id: UUID) {
        guard let watch = watchers[id] else { return }

        watch.debounceWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.onFileChanged?(id)
        }
        watch.debounceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + debounceInterval, execute: work)
    }

    private class FileWatch {
        let fd: Int32
        let source: DispatchSourceFileSystemObject
        var debounceWork: DispatchWorkItem?

        init(fd: Int32, source: DispatchSourceFileSystemObject) {
            self.fd = fd
            self.source = source
        }
    }
}
