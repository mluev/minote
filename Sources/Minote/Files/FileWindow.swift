import AppKit
import MinoteEditor
import MinoteKit
import SwiftUI

/// One opened file: a library holding just that file, and the window that
/// edits it. The window is AppKit's own, so it can open before any SwiftUI
/// scene exists (a launch from Finder) and is never restored at the next launch.
final class FileSession: NSObject, NSWindowDelegate {
    let url: URL
    let library: Library
    let windowState = WindowState()
    let window: NSWindow
    var onMainChange: ((FileSession, Bool) -> Void)?
    var onClose: ((FileSession) -> Void)?

    private let watcher: FileWatcher

    init(url: URL) {
        self.url = url
        let store = NoteFileStore(file: url, backupDirectory: LibraryLocation.backupDirectory())
        let watcher = FileWatcher(url: store.singleFile ?? url)
        self.watcher = watcher
        library = Library(store: store, watcher: watcher)
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        super.init()

        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.tabbingMode = .disallowed
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.titlebarAppearsTransparent = true
        window.backgroundColor = EditorTheme.background
        window.minSize = NSSize(width: 420, height: 320)
        window.title = url.lastPathComponent
        window.representedURL = url
        let host = NSHostingView(rootView: FileWindowView(library: library, windowState: windowState))
        host.sizingOptions = []
        window.contentView = host
        window.delegate = self
    }

    /// Shows the window (offset from `previous`, if given) and reads the file.
    func show(after previous: NSWindow?) {
        if let previous {
            window.setFrameTopLeftPoint(NSPoint(x: previous.frame.minX + 24, y: previous.frame.maxY - 24))
        } else {
            window.center()
        }
        window.makeKeyAndOrderFront(nil)
        Task { await library.load() }
    }

    /// The window closed: saves what the editor had, then stops watching the file.
    func finish() async {
        if let editor = windowState.editor { library.detach(editor) }
        await library.saveNow()
        await library.waitUntilIdle()
        watcher.stop()
    }

    // MARK: NSWindowDelegate

    func windowDidBecomeMain(_ notification: Notification) {
        onMainChange?(self, true)
        // In case the watcher missed something (e.g. while the Mac slept).
        if library.isLoaded { library.scheduleRescan() }
    }

    func windowDidResignMain(_ notification: Notification) {
        onMainChange?(self, false)
    }

    func windowWillClose(_ notification: Notification) {
        onClose?(self)
    }
}

/// An opened file's window: just the page, no sidebar.
struct FileWindowView: View {
    let library: Library
    let windowState: WindowState

    var body: some View {
        EditorPage(library: library, windowState: windowState)
            .libraryErrorAlert(library)
    }
}
