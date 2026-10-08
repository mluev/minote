import AppKit
import MinoteKit
import SwiftUI
import MinoteEditor

@main
struct MinoteApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        AppDelegate.registerDefaults()
    }

    /// Every window is AppKit's own (`LibraryWindow`, `FileSession`), made only
    /// when needed: opening a file from Finder must not pay for the library.
    /// SwiftUI contributes the menus; the empty Settings scene only hosts them.
    var body: some Scene {
        Settings { EmptyView() }
            .commands {
                AppCommands(libraryWindow: appDelegate.libraryWindow, openedFiles: appDelegate.openedFiles)
            }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Made at the first need: a launch that only opens files never shows or loads it.
    let libraryWindow = LibraryWindow()
    /// Markdown files opened from elsewhere, each in its own window.
    let openedFiles = OpenedFiles()

    private var library: Library { libraryWindow.library }

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
        let appearance = UserDefaults.standard.string(forKey: PreferenceKey.appearance).flatMap(AppearancePreference.init(rawValue:))
        NSApp.appearance = appearance?.nsAppearance
        openedFiles.libraryWindow = libraryWindow
        openedFiles.refreshRecents()
    }

    /// Files to open arrive before this. A launch that opened files shows just
    /// them, like a preview; otherwise the library opens.
    func applicationDidFinishLaunching(_ notification: Notification) {
        if !openedFiles.hasWindows { libraryWindow.show() }
    }

    /// Finder (double-click, Open With), files dropped on the Dock icon, recent files.
    func application(_ application: NSApplication, open urls: [URL]) {
        openedFiles.openFromOutside(urls)
    }

    /// Opening Minote itself while it runs (Dock icon, Launchpad, Spotlight)
    /// shows the library, also when only opened files' windows are on screen.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        libraryWindow.show()
        return false
    }

    func applicationDidResignActive(_ notification: Notification) {
        Task {
            if library.isLoaded { await library.saveNow() }
            await openedFiles.saveAll()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Waits for every note and opened file to be on disk before quitting. If
    /// something can't be saved, asks instead of silently dropping text.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // A library that was never opened has nothing to save.
        let library = self.library.isLoaded ? self.library : nil
        let openedFiles = self.openedFiles
        Task {
            await library?.prepareForTermination()
            await openedFiles.prepareForTermination()
            guard library?.hasUnsavedChanges == true || openedFiles.hasUnsavedChanges else {
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
            if !quit {
                library?.cancelTermination()
                openedFiles.cancelTermination()
            }
            sender.reply(toApplicationShouldTerminate: quit)
        }
        return .terminateLater
    }
}
