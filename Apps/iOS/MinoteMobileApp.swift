import MinoteEditor
import MinoteKit
import SwiftUI
import UIKit

@main
struct MinoteMobileApp: App {
    @ViewState private var library: Library
    @ViewState private var state: MobileState
    @ViewState private var lock: LockController
    @Environment(\.scenePhase) private var scenePhase

    @ViewState private var storage: LibraryStorageSwitcher

    init() {
        var biometrics: any BiometricUnlocking = SecureEnclaveUnlock()
        #if DEBUG
        // UI tests start from a known note, and have no face for Face ID.
        let environment = ProcessInfo.processInfo.environment
        if let seed = environment["MINOTE_UITEST_NOTE"] {
            let directory = LibraryLocation.defaultDirectory()
            for file in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
            where NoteNaming.isNoteFile(file) || file.lastPathComponent == VaultRecord.fileName || file.lastPathComponent == FolderSettings.fileName
                || ((try? file.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true && !file.lastPathComponent.hasPrefix(".")) {
                try? FileManager.default.removeItem(at: file)
            }
            for key in ["LockVault", LibraryView.key, "CollapsedFolders"] { UserDefaults.standard.removeObject(forKey: key) }
            try? seed.write(to: directory.appendingPathComponent("UI Test.md"), atomically: true, encoding: .utf8)
            // A folder holding a note.
            if let folder = environment["MINOTE_UITEST_FOLDER"] {
                let url = directory.appendingPathComponent(folder, isDirectory: true)
                try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                try? "Filed Note\nInside the folder".write(to: url.appendingPathComponent("Filed Note.md"), atomically: true, encoding: .utf8)
            }
            // A locked note, sealed with this password.
            if let password = environment["MINOTE_UITEST_LOCKED"],
               let key = try? LibraryKey.create(password: password, hint: "the test one", rounds: 1_000) {
                try? NoteSealer(key).seal("Locked Test\nThe hidden line").write(to: directory.appendingPathComponent("Locked Test.mdlock"))
                try? VaultRecord(key: key.record, scope: .notes).encoded().write(to: directory.appendingPathComponent(VaultRecord.fileName))
            }
            biometrics = FakeBiometricUnlock()
        }
        #endif
        let backups = LibraryLocation.backupDirectory()
        let store = NoteFileStore(directory: LibraryLocation.defaultDirectory(), backupDirectory: backups, trash: MobileTrash.moveToTrash)
        let library = Library(store: store, watcher: FolderWatcher(root: store.directory))
        _library = ViewState(initialValue: library)
        let lock = LockController(library: library, biometrics: biometrics)
        _lock = ViewState(initialValue: lock)
        let state = MobileState()
        state.lock = lock
        library.organisationHandler = { [weak state] change in state?.follow(change) }
        _state = ViewState(initialValue: state)
        _storage = ViewState(initialValue: LibraryStorageSwitcher(
            library: library,
            makeStore: { directory, isUbiquitous in
                NoteFileStore(directory: directory, isUbiquitous: isUbiquitous, backupDirectory: backups, trash: MobileTrash.moveToTrash)
            },
            makeWatcher: { FolderWatcher(root: $0.standardizedFileURL.resolvingSymlinksInPath()) }
        ))
        MobileTrash.purgeExpired()
    }

    var body: some Scene {
        WindowGroup {
            RootView(library: library, state: state, storage: storage, lock: lock)
                .task { await storage.open() }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                // Leaving Minote locks the notes. Not on `.inactive`: Face ID's
                // own prompt makes the scene inactive (the privacy cover hides
                // the page meanwhile).
                saveInBackground(locking: true)
            case .inactive:
                saveInBackground()
            case .active:
                lock.noteActivity()
                // Catch up with changes made in the Files app meanwhile (once
                // the library is open: at launch, opening does the first scan).
                if library.isLoaded { Task { await library.rescanNow() } }
            @unknown default:
                break
            }
        }
        .commands {
            MobileCommands(library: library, state: state, lock: lock)
        }
    }

    /// Writes pending edits when the app leaves the screen. iOS may suspend the
    /// app right after, so the save runs inside a background task. `locking`
    /// takes locked notes' text out of memory first (at once, not in the task).
    private func saveInBackground(locking: Bool = false) {
        let task = BackgroundTask(named: "Save notes")
        if locking { lock.lockNow() }
        Task {
            await library.saveNow()
            task.end()
        }
    }
}

/// Extra time to finish work after the app leaves the screen. Ended exactly
/// once: by the work finishing or by iOS running out of patience.
@MainActor
private final class BackgroundTask {
    private var identifier = UIBackgroundTaskIdentifier.invalid

    init(named name: String) {
        identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            MainActor.assumeIsolated { self?.end() }
        }
    }

    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}

/// App-wide UI state shared by the list, the editor and the menus.
@Observable
final class MobileState {
    /// The note being renamed, if any. Starting a rename fills in its name.
    var renaming: Note? {
        didSet { if let renaming, renaming !== oldValue { renameText = renaming.fileStem ?? renaming.title } }
    }
    /// The Rename alert's text field.
    var renameText = ""
    var statistics = TextStatistics(words: 0, characters: 0)
    var isEditorFocused = false
    /// Preview: the note is read, not edited.
    var isPreviewing = false
    /// Which column shows on iPhone: the library first.
    var preferredColumn: NavigationSplitViewColumn = .sidebar
    /// The Locked Notes settings sheet.
    var isShowingSecurity = false
    /// The password sheet for a command (Lock Note without a password, or while locked).
    var passwordRequest: MobilePasswordRequest?
    /// The list's view settings and closed folders, on this device.
    let sidebar = SidebarPreferences()
    /// The folder the list looks into ("Show Only This Folder").
    var scope: FolderPath = .root
    /// The folder being renamed or made, if any. Starting fills in its name.
    var renamingFolder: FolderPath? {
        didSet { if let renamingFolder, renamingFolder != oldValue { folderNameText = renamingFolder.name ?? "" } }
    }
    /// The folder alert's text field.
    var folderNameText = ""

    /// Folders renamed, moved or trashed: closed folders and the folder
    /// looked into follow.
    func follow(_ change: OrganisationChange) {
        sidebar.follow(change)
        switch change {
        case .folderMoved(let from, let to): scope = from.rebasing(scope, onto: to)
        case .folderRemoved(let folder): while folder.contains(scope), let parent = scope.parent { scope = parent }
        case .noteMoved: break
        }
    }

    @ObservationIgnored weak var editor: MobileEditorCoordinator?
    @ObservationIgnored weak var lock: LockController?
}
