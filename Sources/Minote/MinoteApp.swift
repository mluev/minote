import AppKit
import MinoteKit
import SwiftUI
import MinoteEditor

@main
struct MinoteApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @ViewState private var library: Library
    @ViewState private var windowState = WindowState()
    @AppStorage(PreferenceKey.appearance) private var appearance = AppearancePreference.system

    @ViewState private var storage: LibraryStorageSwitcher

    init() {
        AppDelegate.registerDefaults()
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
        _library = ViewState(initialValue: library)
        _storage = ViewState(initialValue: LibraryStorageSwitcher(
            library: library,
            makeStore: { directory, isUbiquitous in
                NoteFileStore(directory: directory, isUbiquitous: isUbiquitous, backupDirectory: backups)
            },
            makeWatcher: { FSEventsWatcher(directory: $0.standardizedFileURL.resolvingSymlinksInPath()) }
        ))
    }

    var body: some Scene {
        Window("Minote", id: "main") {
            ContentView(library: library, windowState: windowState)
                .frame(minWidth: 520, minHeight: 400)
                .windowToolbarFullScreenVisibility(.onHover)
                .task {
                    appDelegate.library = library
                    #if DEBUG
                    DebugDriver.startIfRequested(windowState: windowState)
                    #endif
                    await storage.open()
                }
                .onChange(of: appearance, initial: true) { _, preference in
                    NSApp.appearance = preference.nsAppearance
                }
        }
        .defaultSize(width: 1100, height: 760)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            AppCommands(library: library, windowState: windowState, storage: storage)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var library: Library?

    /// Writing defaults: Markdown is typed literally, spelling is checked.
    /// Registered (not set), so Edit ▸ Substitutions toggles still win.
    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            "NSAutomaticQuoteSubstitutionEnabled": false,
            "NSAutomaticDashSubstitutionEnabled": false,
            "NSAutomaticTextReplacementEnabled": false,
            "NSAutomaticLinkDetectionEnabled": false,
            "NSContinuousSpellCheckingEnabled": true,
        ])
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    func applicationDidResignActive(_ notification: Notification) {
        guard let library else { return }
        Task { await library.saveNow() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Waits for every note to be on disk before quitting. If something can't
    /// be saved, asks instead of silently dropping text.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let library else { return .terminateNow }
        Task {
            await library.prepareForTermination()
            guard library.hasUnsavedChanges else {
                sender.reply(toApplicationShouldTerminate: true)
                return
            }
            let alert = NSAlert()
            alert.messageText = "Some notes couldn't be saved"
            alert.informativeText = "If you quit now, your latest changes will be lost."
            alert.alertStyle = .critical
            alert.addButton(withTitle: "Don't Quit")
            alert.addButton(withTitle: "Quit Anyway")
            let quit = alert.runModal() == .alertSecondButtonReturn
            if !quit { library.cancelTermination() }
            sender.reply(toApplicationShouldTerminate: quit)
        }
        return .terminateLater
    }
}
