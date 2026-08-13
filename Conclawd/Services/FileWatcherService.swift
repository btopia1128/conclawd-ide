import Foundation

/// Watches directories for file changes and notifies via callback.
final class FileWatcherService {

    private var sources: [DispatchSourceFileSystemObject] = []
    private var watchedPaths: [String] = []
    private var debounceWorkItem: DispatchWorkItem?
    private let debounceInterval: TimeInterval

    var onChange: (() -> Void)?

    init(debounceInterval: TimeInterval = 0.5) {
        self.debounceInterval = debounceInterval
    }

    deinit {
        stopAll()
    }

    /// Start watching a directory for changes.
    func watch(directory: URL) {
        let path = directory.path(percentEncoded: false)
        guard !watchedPaths.contains(path) else { return }

        // Ensure directory exists
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else { return }

        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete, .extend],
            queue: .main
        )

        source.setEventHandler { [weak self] in
            self?.handleChange()
        }

        source.setCancelHandler {
            close(fd)
        }

        source.resume()
        sources.append(source)
        watchedPaths.append(path)
    }

    /// Stop watching all directories.
    func stopAll() {
        for source in sources {
            source.cancel()
        }
        sources.removeAll()
        watchedPaths.removeAll()
        debounceWorkItem?.cancel()
    }

    /// Remove a specific watch.
    func stopWatching(directory: URL) {
        let path = directory.path(percentEncoded: false)
        guard let index = watchedPaths.firstIndex(of: path) else { return }
        sources[index].cancel()
        sources.remove(at: index)
        watchedPaths.remove(at: index)
    }

    private func handleChange() {
        debounceWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.onChange?()
        }
        debounceWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + debounceInterval, execute: work)
    }
}
