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

    /// Every window is AppKit's own (`PageWindow`, with its tabs), made only
    /// when needed: opening a file from Finder must not pay for the library.
    /// SwiftUI contributes the menus; the empty Settings scene only hosts them.
    var body: some Scene {
        Settings { EmptyView() }
            .commands {
                AppCommands(workspace: appDelegate.workspace)
            }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Every tab and window. The library is read only once a window shows it:
    /// a launch that only opens files never loads it.
    let workspace = Workspace()
    private var tabKeys: Any?
    private var middleClicks: Any?

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
        // The tab bar is Minote's own: no system tabs (nor their menu items).
        NSWindow.allowsAutomaticWindowTabbing = false
        PageTheme.applySaved()
        workspace.refreshRecents()
        tabKeys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated { self?.handleTabKey(event) ?? false }
            return handled ? nil : event
        }
        // A middle click on a tab closes it, as in browsers and editors.
        middleClicks = NSEvent.addLocalMonitorForEvents(matching: .otherMouseUp) { [weak self] event in
            let handled = MainActor.assumeIsolated { self?.handleMiddleClick(event) ?? false }
            return handled ? nil : event
        }
    }

    /// Files to open arrive before this. A launch that opened files shows just
    /// them, like a preview; otherwise the library opens.
    func applicationDidFinishLaunching(_ notification: Notification) {
        if !workspace.hasWindows { workspace.showLibrary() }
        #if DEBUG
        DebugDriver.startIfRequested(workspace: workspace)
        #endif
    }

    /// Finder (double-click, Open With), files dropped on the Dock icon, recent files.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { workspace.open(url) }
    }

    /// Opening Minote itself while it runs (Dock icon, Launchpad, Spotlight)
    /// shows the library, also when only opened files' windows are on screen.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        workspace.showLibrary()
        return false
    }

    func applicationDidResignActive(_ notification: Notification) {
        Task { await workspace.saveAll() }
    }

    /// Tab shortcuts without menu items, as in Safari: ⌘1…⌘8 a tab, ⌘9 the
    /// last, ⌘⇧] / ⌘⇧[ and ⌃Tab / ⌃⇧Tab the next or previous one. Only in a
    /// tab's window.
    private func handleTabKey(_ event: NSEvent) -> Bool {
        guard let window = NSApp.keyWindow, window is PageNSWindow, window.attachedSheet == nil else { return false }
        let modifiers = event.modifierFlags.intersection([.command, .shift, .control, .option])
        if modifiers == .command, let digit = event.charactersIgnoringModifiers.flatMap(Int.init), (1...9).contains(digit) {
            workspace.selectTab(at: digit == 9 ? nil : digit - 1)
            return true
        }
        switch (modifiers, event.keyCode) {
        case ([.command, .shift], 30), (.control, 48): workspace.selectTab(offset: 1)            // ] or Tab
        case ([.command, .shift], 33), ([.control, .shift], 48): workspace.selectTab(offset: -1) // [ or Tab
        default: return false
        }
        return true
    }

    private func handleMiddleClick(_ event: NSEvent) -> Bool {
        guard event.buttonNumber == 2, let window = event.window, window is PageNSWindow else { return false }
        return workspace.closeHoveredTab(in: window)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Waits for every note and opened file to be on disk before quitting. If
    /// something can't be saved, asks instead of silently dropping text.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let workspace = self.workspace
        Task {
            await workspace.prepareForTermination()
            guard workspace.hasUnsavedChanges else {
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
                workspace.cancelTermination()
            }
            sender.reply(toApplicationShouldTerminate: quit)
        }
        return .terminateLater
    }
}
