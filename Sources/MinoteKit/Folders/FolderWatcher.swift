import Foundation

/// Watches the library folder and every folder below it, one `PathWatcher`
/// each, for platforms without a recursive watcher (iOS; the Mac uses
/// FSEvents). The library tells it which folders exist after every scan.
@MainActor
public final class FolderWatcher: LibraryWatching {
    private let root: URL
    private var watchers: [URL: PathWatcher] = [:]
    /// Each watcher holds a file descriptor: past this many folders, the
    /// deepest go unwatched (coming back to the app rescans them anyway).
    static let limit = 64
    private var onChange: (@MainActor () -> Void)?
    /// The folders the library last told about, watched once started.
    private var wanted: [URL] = []

    public init(root: URL) {
        self.root = root
    }

    public func start(onChange: @escaping @MainActor () -> Void) {
        stop()
        self.onChange = onChange
        watch(folders: wanted)
    }

    public func stop() {
        for watcher in watchers.values { watcher.stop() }
        watchers.removeAll()
        onChange = nil
    }

    public func watch(folders: [URL]) {
        self.wanted = folders
        guard let onChange else { return }
        let rootURL = root.standardizedFileURL
        let byDepth = folders.map(\.standardizedFileURL).filter { $0 != rootURL }.sorted { $0.pathComponents.count < $1.pathComponents.count }
        let wanted = Set([rootURL] + byDepth.prefix(Self.limit - 1))
        for (url, watcher) in watchers where !wanted.contains(url) {
            watcher.stop()
            watchers[url] = nil
        }
        for url in wanted where watchers[url] == nil {
            let watcher = PathWatcher(url: url)
            watcher.start(onChange: onChange)
            watchers[url] = watcher
        }
    }
}
