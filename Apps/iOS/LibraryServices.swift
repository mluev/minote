import Foundation
import MinoteKit

/// iOS has no system Trash for an app's own files, so deleted notes move to a
/// hidden folder (restorable by Undo) and are purged after 30 days.
enum MobileTrash {
    nonisolated static let directory = URL.applicationSupportDirectory.appendingPathComponent("Trash", isDirectory: true)

    nonisolated static let moveToTrash: TrashHandler = { url in
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent("\(UUID().uuidString)-\(url.lastPathComponent)")
        try FileManager.default.moveItem(at: url, to: destination)
        return destination
    }

    static func purgeExpired(after days: Int = 30) {
        let manager = FileManager.default
        guard let items = try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        for item in items {
            let modified = (try? item.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if modified < cutoff { try? manager.removeItem(at: item) }
        }
    }
}

/// Watches the Documents folder for notes added, removed or replaced from the
/// Files app. (Edits by other apps arrive as replacements; the library also
/// rescans whenever the app becomes active.)
final class DirectoryWatcher: LibraryWatching, @unchecked Sendable {
    private let directory: URL
    private var source: DispatchSourceFileSystemObject?
    private var onChange: (@MainActor () -> Void)?

    init(directory: URL) {
        self.directory = directory
    }

    func start(onChange: @escaping @MainActor () -> Void) {
        stop()
        self.onChange = onChange
        let descriptor = open(directory.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .rename, .delete, .extend, .link],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.onChange?() }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        self.source = source
    }

    func stop() {
        source?.cancel()
        source = nil
    }
}
