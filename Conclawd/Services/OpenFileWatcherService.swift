import Foundation

/// Watches individual open files for external modifications and notifies via callback.
final class OpenFileWatcherService {

    private var watchers: [UUID: FileWatch] = [:]
    private let debounceInterval: TimeInterval

    /// Called when an open file is modified externally. Parameter is the file's OpenFile ID.
    var onFileChanged: ((UUID) -> Void)?

    /// Remembers each watched file's path so the watch can be re-armed after an
    /// atomic save (write-temp + rename) replaces the original inode.
    private var watchedURLs: [UUID: URL] = [:]

    init(debounceInterval: TimeInterval = 0.5) {
        self.debounceInterval = debounceInterval
    }

    deinit {
        stopAll()
    }

    /// Start watching a file associated with an OpenFile ID.
    func watch(id: UUID, url: URL) {
        guard watchers[id] == nil else { return }
        watchedURLs[id] = url

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
            // Capture the event mask before handling: a rename/delete means the
            // inode this fd points at was replaced (atomic save), so the watch is
            // now dead and must be re-armed on the path.
            let isReplaced = !source.data.intersection([.rename, .delete]).isEmpty
            self?.handleChange(id: id, replaced: isReplaced)
        }

        source.setCancelHandler {
            close(fd)
        }

        source.resume()
    }

    /// Stop watching a specific file.
    func unwatch(id: UUID) {
        watchedURLs.removeValue(forKey: id)
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
        watchedURLs.removeAll()
    }

    private func handleChange(id: UUID, replaced: Bool) {
        guard let watch = watchers[id] else { return }

        // Atomic save replaced the file: the current fd is now stale. Re-arm the
        // watch on the same path so subsequent external edits keep firing.
        if replaced, let url = watchedURLs[id] {
            watch.debounceWork?.cancel()
            watch.source.cancel()
            watchers.removeValue(forKey: id)
            watchedURLs.removeValue(forKey: id)
            self.watch(id: id, url: url)
        }

        let notifyWork = DispatchWorkItem { [weak self] in
            self?.onFileChanged?(id)
        }
        // Re-fetch the (possibly re-armed) watch to attach the debounce token.
        let activeWatch = watchers[id] ?? watch
        activeWatch.debounceWork?.cancel()
        activeWatch.debounceWork = notifyWork
        DispatchQueue.main.asyncAfter(deadline: .now() + debounceInterval, execute: notifyWork)
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
