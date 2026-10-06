import Foundation

/// Opens the library where the user keeps it and moves it between this
/// device and iCloud Drive. Each app supplies how to make a store (its trash)
/// and a watcher for a folder.
@MainActor
@Observable
public final class LibraryStorageSwitcher {
    /// iCloud Drive is on, signed in, and this build is entitled for it.
    public private(set) var isICloudAvailable = false
    public private(set) var isMoving = false

    @ObservationIgnored private let library: Library
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let makeStore: (URL, Bool) -> NoteFileStore
    @ObservationIgnored private let makeWatcher: (URL) -> (any LibraryWatching)?

    static let preferenceKey = "LibraryStorage"

    public init(
        library: Library,
        defaults: UserDefaults = .standard,
        makeStore: @escaping (URL, Bool) -> NoteFileStore,
        makeWatcher: @escaping (URL) -> (any LibraryWatching)?
    ) {
        self.library = library
        self.defaults = defaults
        self.makeStore = makeStore
        self.makeWatcher = makeWatcher
    }

    public var storage: LibraryStorage { library.isInICloud ? .iCloud : .local }

    /// At launch: loads the library from iCloud Drive if that's where the
    /// user keeps it (and iCloud is reachable), otherwise from this device.
    public func open() async {
        let iCloud = await LibraryLocation.resolveICloudDirectory()
        isICloudAvailable = iCloud != nil
        if defaults.string(forKey: Self.preferenceKey) == LibraryStorage.iCloud.rawValue, let iCloud {
            await library.relocate(to: makeStore(iCloud, true), watcher: makeWatcher(iCloud), movingNotes: false)
        } else {
            await library.load()
        }
    }

    /// Moves every note into iCloud Drive or back to this device.
    public func move(to storage: LibraryStorage) async {
        guard storage != self.storage, !isMoving else { return }
        isMoving = true
        defer { isMoving = false }
        let directory: URL
        switch storage {
        case .iCloud:
            guard let iCloud = await LibraryLocation.resolveICloudDirectory() else {
                isICloudAvailable = false
                return
            }
            directory = iCloud
        case .local:
            directory = LibraryLocation.defaultDirectory()
        }
        await library.relocate(to: makeStore(directory, storage == .iCloud), watcher: makeWatcher(directory), movingNotes: true)
        defaults.set(storage.rawValue, forKey: Self.preferenceKey)
    }
}
