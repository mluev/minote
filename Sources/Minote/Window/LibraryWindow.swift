import AppKit
import MinoteEditor
import MinoteKit
import SwiftUI

/// The library window: sidebar and page. Like an opened file's window it is
/// AppKit's own, and it is made the first time it's needed: a launch that
/// only opens files (Finder, the Dock) never reads, watches or draws the library.
final class LibraryWindow: NSObject, NSWindowDelegate {
    let library: Library
    let windowState = WindowState()
    let storage: LibraryStorageSwitcher

    private(set) var window: NSWindow?
    private var opened: Task<Void, Never>?

    override init() {
        var directory = LibraryLocation.defaultDirectory()
        #if DEBUG
        // Interaction tests run against their own library.
        if ProcessInfo.processInfo.environment["MINOTE_DRIVER"] != nil {
            directory = directory.deletingLastPathComponent().appendingPathComponent("DriverNotes", isDirectory: true)
        }
        #endif
        let backups = LibraryLocation.backupDirectory()
        let store = NoteFileStore(directory: directory, backupDirectory: backups)
        let library = Library(store: store, watcher: FSEventsWatcher(directory: store.directory))
        self.library = library
        storage = LibraryStorageSwitcher(
            library: library,
            makeStore: { directory, isUbiquitous in
                NoteFileStore(directory: directory, isUbiquitous: isUbiquitous, backupDirectory: backups)
            },
            makeWatcher: { FSEventsWatcher(directory: $0.standardizedFileURL.resolvingSymlinksInPath()) }
        )
        super.init()
    }

    var isVisible: Bool { window?.isVisible == true }

    /// Brings the window forward, making it and loading the library the first time.
    func show() {
        let window = self.window ?? makeWindow()
        window.makeKeyAndOrderFront(nil)
        guard opened == nil else { return }
        #if DEBUG
        DebugDriver.startIfRequested(windowState: windowState)
        #endif
        opened = Task { await storage.open() }
    }

    /// File ▸ New Note: shows the window and starts a draft, once the library has loaded.
    func newNote() {
        show()
        guard !library.isLoaded else {
            library.newNote()
            return
        }
        let opened = self.opened
        Task {
            await opened?.value
            library.newNote()
        }
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.tabbingMode = .disallowed
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.toolbarStyle = .unified
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.backgroundColor = EditorTheme.background
        window.minSize = NSSize(width: 520, height: 400)
        window.title = "Minote"
        let host = NSHostingView(rootView: ContentView(library: library, windowState: windowState))
        host.sizingOptions = []
        // SwiftUI fills in the toolbar (sidebar toggle, "+") and the window title.
        host.sceneBridgingOptions = .all
        window.contentView = host
        window.delegate = self
        if !window.setFrameUsingName("LibraryWindow") { window.center() }
        window.setFrameAutosaveName("LibraryWindow")
        self.window = window
        return window
    }

    // MARK: NSWindowDelegate

    /// The window is kept, not torn down: reopening it is instant.
    func windowWillClose(_ notification: Notification) {
        Task { await library.saveNow() }
    }

    /// Full screen: the toolbar shows when the pointer reaches the top.
    func window(_ window: NSWindow, willUseFullScreenPresentationOptions proposedOptions: NSApplication.PresentationOptions) -> NSApplication.PresentationOptions {
        proposedOptions.union(.autoHideToolbar)
    }
}
