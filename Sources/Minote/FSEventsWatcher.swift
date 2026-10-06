import CoreServices
import Foundation
import MinoteKit

/// Watches the library folder with FSEvents, so edits made by other apps
/// (Finder, Obsidian, vim, sync clients) show up live.
final class FSEventsWatcher: LibraryWatching {
    private let directory: URL
    private var stream: FSEventStreamRef?
    private var onChange: (@MainActor () -> Void)?

    init(directory: URL) {
        self.directory = directory
    }

    func start(onChange: @escaping @MainActor () -> Void) {
        stop()
        self.onChange = onChange

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            // The stream is scheduled on the main queue.
            MainActor.assumeIsolated {
                Unmanaged<FSEventsWatcher>.fromOpaque(info).takeUnretainedValue().onChange?()
            }
        }
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagUseCFTypes
        )
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            [directory.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.25,
            flags
        ) else { return }

        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    isolated deinit {
        stop()
    }
}
