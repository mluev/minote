import MinoteEditor
import MinoteKit
import SwiftUI
import UIKit

@main
struct MinoteMobileApp: App {
    @ViewState private var library: Library
    @ViewState private var state = MobileState()
    @Environment(\.scenePhase) private var scenePhase

    @ViewState private var storage: LibraryStorageSwitcher

    init() {
        #if DEBUG
        // UI tests start from a known note.
        if let seed = ProcessInfo.processInfo.environment["MINOTE_UITEST_NOTE"] {
            let directory = LibraryLocation.defaultDirectory()
            for file in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] where NoteNaming.isNoteFile(file) {
                try? FileManager.default.removeItem(at: file)
            }
            try? seed.write(to: directory.appendingPathComponent("UI Test.md"), atomically: true, encoding: .utf8)
        }
        #endif
        let store = NoteFileStore(directory: LibraryLocation.defaultDirectory(), trash: MobileTrash.moveToTrash)
        let library = Library(store: store, watcher: DirectoryWatcher(directory: store.directory))
        _library = ViewState(initialValue: library)
        _storage = ViewState(initialValue: LibraryStorageSwitcher(
            library: library,
            makeStore: { directory, isUbiquitous in
                NoteFileStore(directory: directory, isUbiquitous: isUbiquitous, trash: MobileTrash.moveToTrash)
            },
            makeWatcher: { DirectoryWatcher(directory: $0.standardizedFileURL.resolvingSymlinksInPath()) }
        ))
        MobileTrash.purgeExpired()
    }

    var body: some Scene {
        WindowGroup {
            RootView(library: library, state: state, storage: storage)
                .task { await storage.open() }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background, .inactive:
                saveInBackground()
            case .active:
                Task { await library.rescanNow() }
            @unknown default:
                break
            }
        }
        .commands {
            MobileCommands(library: library, state: state)
        }
    }

    /// Writes pending edits when the app leaves the screen. iOS may suspend the
    /// app right after, so the save runs inside a background task.
    private func saveInBackground() {
        let application = UIApplication.shared
        var taskID = UIBackgroundTaskIdentifier.invalid
        taskID = application.beginBackgroundTask(withName: "Save notes") {
            application.endBackgroundTask(taskID)
        }
        Task {
            await library.saveNow()
            application.endBackgroundTask(taskID)
        }
    }
}

/// App-wide UI state shared by the list, the editor and the menus.
@Observable
final class MobileState {
    var renaming: Note?
    var statistics = TextStatistics(words: 0, characters: 0)
    var isEditorFocused = false
    /// Preview: the note is read, not edited.
    var isPreviewing = false
    /// Which column shows on iPhone: the library first.
    var preferredColumn: NavigationSplitViewColumn = .sidebar

    @ObservationIgnored weak var editor: MobileEditorCoordinator?
}

/// SwiftUI's `State` property wrapper (see the Mac app's ViewState.swift: the
/// Command Line Tools can't expand the `@State` macro of the newest SDKs).
typealias ViewState = SwiftUI.State
