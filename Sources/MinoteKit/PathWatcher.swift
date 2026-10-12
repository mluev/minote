import Foundation

/// Watches one file or folder, so changes other apps make there show up live.
/// Editors that save by replacing a file leave the watched one deleted or
/// renamed: the watcher then picks up whatever is at the path now, and keeps
/// looking while nothing is there.
@MainActor
public final class PathWatcher: LibraryWatching {
    private let url: URL
    private var source: DispatchSourceFileSystemObject?
    private var retry: Task<Void, Never>?
    private var onChange: (@MainActor () -> Void)?

    public init(url: URL) {
        self.url = url
    }

    public func start(onChange: @escaping @MainActor () -> Void) {
        stop()
        self.onChange = onChange
        watch()
    }

    public func stop() {
        retry?.cancel()
        retry = nil
        source?.cancel()
        source = nil
    }

    private func watch() {
        source?.cancel()
        source = nil
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else {
            watchAgain(after: .seconds(1))
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .attrib, .link, .delete, .rename, .revoke],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let events = self.source?.data else { return }
                self.onChange?()
                if !events.isDisjoint(with: [.delete, .rename, .revoke]) {
                    self.watchAgain(after: .milliseconds(100))
                }
            }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        self.source = source
    }

    /// The item went away (or is being replaced): watch the path again soon.
    private func watchAgain(after delay: Duration) {
        source?.cancel()
        source = nil
        retry?.cancel()
        retry = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled else { return }
            self.watch()
            if self.source != nil { self.onChange?() }
        }
    }

    isolated deinit {
        stop()
    }
}
