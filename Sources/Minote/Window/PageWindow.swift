import AppKit
import MinoteEditor
import MinoteKit
import SwiftUI

/// One tab: an AppKit window in the system's tab group, with its own editor,
/// showing a library note or a file opened from elsewhere. Tabs reorder, drag
/// out into windows and into other windows' tab bars the way Finder's do.
/// The window is AppKit's own, so it can open before any SwiftUI scene exists
/// (a launch from Finder), and it is never restored by the system.
final class PageWindow: NSObject, NSWindowDelegate {
    enum Content {
        /// The library's notes, one at a time.
        case library
        /// A file opened from elsewhere, alone.
        case file(OpenedFile)
    }

    let content: Content
    /// The library this tab's note belongs to.
    let library: Library
    let editor: EditorCoordinator
    let windowState = WindowState()
    let window: NSWindow
    private weak var workspace: Workspace?

    static let tabbingIdentifier = "com.mlutfullaev.minote.page"
    /// Where the library's windows open, saved as they move and resize.
    private static let frameName = "LibraryWindow"

    init(content: Content, workspace: Workspace, sidebar: NavigationSplitViewVisibility) {
        self.content = content
        self.workspace = workspace
        if case .file(let file) = content {
            library = file.library
        } else {
            library = workspace.library
        }
        editor = EditorCoordinator(configuration: EditorPreferences().configuration(preview: false, paper: PageTheme.saved.paper))
        let window = PageNSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        self.window = window
        super.init()

        windowState.columnVisibility = sidebar
        windowState.editor = editor
        editor.library = library
        editor.windowState = windowState

        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.tabbingMode = .automatic
        window.tabbingIdentifier = Self.tabbingIdentifier
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.toolbarStyle = .unified
        window.titlebarAppearsTransparent = true
        window.backgroundColor = PageTheme.saved.palette.background
        window.minSize = NSSize(width: 420, height: 320)
        window.titleVisibility = .hidden
        if case .file(let file) = content {
            window.title = file.url.lastPathComponent
            window.representedURL = file.url
        } else {
            window.title = "Minote"
        }
        window.onNewTab = { [weak workspace] in workspace?.newTab() }
        let host = NSHostingView(rootView: PageView(page: self, workspace: workspace, windowState: windowState))
        host.sizingOptions = []
        // SwiftUI fills in the toolbar (sidebar toggle, "+", "Aa"); the title is the tab's.
        host.sceneBridgingOptions = [.toolbars]
        window.contentView = host
        window.delegate = self
    }

    var file: OpenedFile? {
        if case .file(let file) = content { return file }
        return nil
    }

    var isLibraryPage: Bool { file == nil }

    /// What `OpenPlacement` needs to know about this tab.
    var frontTab: OpenPlacement.FrontTab {
        isLibraryPage ? .libraryNote(edited: windowState.isEdited) : .outsideFile
    }

    /// Selects this tab and brings its window forward; the library's
    /// selection follows at once, without waiting for the window to activate.
    func bringForward() {
        if let group = window.tabGroup, group.selectedWindow !== window {
            group.selectedWindow = window
        }
        window.makeKeyAndOrderFront(nil)
        library.activate(editor)
        workspace?.tabsDidChange()
    }

    /// Shows the tab in a window of its own.
    func showAsNewWindow() {
        if isLibraryPage, window.setFrameUsingName(Self.frameName) {
            // Where the library was last.
        } else {
            if file != nil { window.setContentSize(NSSize(width: 820, height: 760)) }
            window.center()
        }
        window.makeKeyAndOrderFront(nil)
    }

    /// A file alone in its window shows its name in the titlebar, as before
    /// tabs; with the tab bar showing, the tabs name every page.
    func updateTitleVisibility() {
        let visibility: NSWindow.TitleVisibility = file != nil && (window.tabbedWindows?.count ?? 1) <= 1 ? .visible : .hidden
        if window.titleVisibility != visibility { window.titleVisibility = visibility }
    }

    /// The tab shows its note's title; in italics while nobody typed in it,
    /// as the next note opened will take its place.
    func applyTitle(_ title: String, untouched: Bool) {
        if window.title != title { window.title = title }
        let tab = window.tab
        if untouched {
            let italic = NSAttributedString(string: title, attributes: [.obliqueness: 0.18])
            if tab.attributedTitle != italic { tab.attributedTitle = italic }
        } else if tab.attributedTitle != nil {
            tab.attributedTitle = nil
        }
    }

    // MARK: NSWindowDelegate

    func windowDidBecomeMain(_ notification: Notification) {
        workspace?.pageBecameMain(self)
    }

    func windowDidResignMain(_ notification: Notification) {
        workspace?.pageResignedMain(self)
    }

    func windowWillClose(_ notification: Notification) {
        workspace?.pageWillClose(self)
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        saveFrame()
    }

    func windowDidMove(_ notification: Notification) {
        saveFrame()
    }

    private func saveFrame() {
        guard isLibraryPage, !window.styleMask.contains(.fullScreen) else { return }
        window.saveFrame(usingName: Self.frameName)
    }

    /// Full screen: the toolbar shows when the pointer reaches the top.
    func window(_ window: NSWindow, willUseFullScreenPresentationOptions proposedOptions: NSApplication.PresentationOptions) -> NSApplication.PresentationOptions {
        proposedOptions.union(.autoHideToolbar)
    }
}

/// The tab bar's "+" button asks the window for a new tab.
final class PageNSWindow: NSWindow {
    var onNewTab: (() -> Void)?

    override func newWindowForTab(_ sender: Any?) {
        onNewTab?()
    }
}

/// A tab's content: the library on the left (hidden at first for a file
/// opened from Finder), the page on the right.
struct PageView: View {
    let page: PageWindow
    let workspace: Workspace
    @Bindable var windowState: WindowState

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ViewState private var fader = ChromeFader()

    var body: some View {
        NavigationSplitView(columnVisibility: $windowState.columnVisibility) {
            SidebarView(library: workspace.library, windowState: windowState, workspace: workspace)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 360)
        } detail: {
            EditorPage(editor: page.editor, windowState: windowState, onUserEdit: { fader.userDidType() })
        }
        .background(WindowAccessor { window in fader.attach(to: window) })
        .onChange(of: windowState.columnVisibility, initial: true) { _, visibility in
            fader.isEnabled = visibility == .detailOnly
            workspace.sidebarVisibilityChanged(in: page)
        }
        .onChange(of: reduceMotion, initial: true) { _, reduce in
            fader.animates = !reduce
        }
        .onChange(of: tabTitle, initial: true) { _, title in
            page.applyTitle(title.text, untouched: title.untouched)
        }
        .onChange(of: fileName) {
            // Tabs are kept by file name: a note renamed (or a draft saved) changes them.
            workspace.tabsDidChange()
        }
        .sheet(item: $windowState.renaming) { note in
            RenameSheet(note: note, library: workspace.library) { windowState.renaming = nil }
        }
        .libraryErrorAlert(page.library, isEnabled: page.file != nil || workspace.alertPage === page)
    }

    private struct TabTitle: Equatable {
        var text: String
        var untouched: Bool
    }

    private var fileName: String? {
        guard page.isLibraryPage else { return nil }
        return windowState.noteID.flatMap(workspace.library.note(with:))?.fileURL?.lastPathComponent
    }

    private var tabTitle: TabTitle {
        if let file = page.file {
            return TabTitle(text: file.url.lastPathComponent, untouched: false)
        }
        let note = windowState.noteID.flatMap(workspace.library.note(with:))
        return TabTitle(text: note?.displayTitle ?? "Minote", untouched: !windowState.isEdited)
    }
}
