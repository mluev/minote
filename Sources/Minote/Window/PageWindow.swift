import AppKit
import MinoteEditor
import MinoteKit
import SwiftUI

/// One window: a tab bar at the top, the library on the left (hidden at first
/// for a file opened from Finder), and the page of the tab in front. Each tab
/// has its own editor; switching tabs swaps the page, closing the last tab
/// closes the window. The window is AppKit's own, so it can open before any
/// SwiftUI scene exists (a launch from Finder), and it is never restored by
/// the system.
final class PageWindow: NSObject, NSWindowDelegate {
    let window: PageNSWindow
    let state = WindowState()
    private weak var workspace: Workspace?
    private let buttonsKeeper: WindowButtonsKeeper

    /// Where library windows open, saved as they move and resize.
    private static let frameName = "LibraryWindow"

    init(workspace: Workspace, sidebar: Bool) {
        self.workspace = workspace
        window = PageNSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        buttonsKeeper = WindowButtonsKeeper(window: window)
        super.init()
        state.isSidebarVisible = sidebar

        window.isReleasedWhenClosed = false
        window.isRestorable = false
        // The tab bar is ours: no system tabs on top of it.
        window.tabbingMode = .disallowed
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none
        window.backgroundColor = PageTheme.saved.palette.background
        window.minSize = NSSize(width: 480, height: 320)
        window.title = "Minote"
        let host = NSHostingView(rootView: PageView(page: self, workspace: workspace, state: state))
        // The window's size is the user's; SwiftUI doesn't add a toolbar or
        // keep the page clear of the titlebar: the tab bar is the titlebar.
        host.sizingOptions = []
        host.sceneBridgingOptions = []
        host.safeAreaRegions = []
        window.contentView = host
        window.delegate = self
        buttonsKeeper.onPlace = { [weak self] width in
            guard let self, self.state.windowButtonsWidth != width else { return }
            self.state.windowButtonsWidth = width
        }
    }

    var tabs: [PageTab] { state.tabs }
    var selectedTab: PageTab? { state.selectedTab }

    // MARK: Tabs

    /// Adds a tab, after the one in front unless `index` says where.
    func insert(_ tab: PageTab, at index: Int? = nil, select: Bool = true, focus: Bool = true) {
        tab.window = self
        let after = state.selectedTab.flatMap(index(of:)).map { $0 + 1 } ?? tabs.count
        state.tabs.insert(tab, at: min(index ?? after, tabs.count))
        if select || state.selectedTab == nil {
            self.select(tab, focus: focus)
        }
        workspace?.tabsDidChange()
    }

    /// Puts the tab in front. Its note becomes the library's selection, and
    /// typing goes to it.
    func select(_ tab: PageTab, focus: Bool = true) {
        guard index(of: tab) != nil else { return }
        if state.selectedTab !== tab {
            state.selectedTab = tab
            updateTitle()
        }
        tab.library.activate(tab.editor)
        if focus { tab.editor.focus() }
        workspace?.tabsDidChange()
    }

    /// Selects the tab and brings the window forward.
    func bringForward(_ tab: PageTab, focus: Bool = true) {
        select(tab, focus: focus)
        window.makeKeyAndOrderFront(nil)
    }

    /// The next (or previous) tab, around the end.
    func selectTab(offset: Int) {
        guard let selected = state.selectedTab, let index = index(of: selected), tabs.count > 1 else { return }
        select(tabs[(index + offset + tabs.count) % tabs.count])
    }

    /// Takes a tab out of the bar, to close it or to move it to another
    /// window. The tab after it comes forward; the window closes with its
    /// last tab.
    func remove(_ tab: PageTab) {
        guard let index = index(of: tab) else { return }
        state.tabs.remove(at: index)
        if tab.window === self { tab.window = nil }
        if state.selectedTab === tab {
            state.selectedTab = nil
            if !tabs.isEmpty {
                select(tabs[min(index, tabs.count - 1)], focus: window.isKeyWindow)
            }
        }
        if tabs.isEmpty {
            window.close()
        }
        workspace?.tabsDidChange()
    }

    /// Closes a tab: its note is wrapped up and saved.
    func close(_ tab: PageTab) {
        guard index(of: tab) != nil else { return }
        workspace?.tabWillClose(tab)
        remove(tab)
    }

    func closeOtherTabs(than kept: PageTab) {
        for tab in tabs where tab !== kept { close(tab) }
    }

    func closeTabs(after kept: PageTab) {
        guard let index = index(of: kept) else { return }
        for tab in tabs.suffix(from: index + 1) { close(tab) }
    }

    /// A tab dragged to another place in the bar.
    func move(_ tab: PageTab, to index: Int) {
        guard let from = self.index(of: tab) else { return }
        let to = min(max(index, 0), tabs.count - 1)
        guard from != to else { return }
        state.tabs.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        workspace?.tabsDidChange()
    }

    /// A tab showing something else in the same place (a Finder file opened
    /// over an untouched note).
    func replace(_ old: PageTab, with new: PageTab) {
        insert(new, at: index(of: old), select: true)
        close(old)
    }

    func index(of tab: PageTab) -> Int? {
        tabs.firstIndex { $0 === tab }
    }

    /// The window's title (Window menu, Mission Control) is its front tab's.
    func updateTitle() {
        let title = state.selectedTab?.title ?? "Minote"
        let url = state.selectedTab?.file?.url
        guard window.title != title || window.representedURL != url else { return }
        window.title = title
        window.representedURL = url
        // A new title lays the titlebar out again, the zoom button back at
        // AppKit's place: do it now and put the buttons back before drawing.
        window.contentView?.superview?.layoutSubtreeIfNeeded()
        buttonsKeeper.place()
    }

    // MARK: The window

    /// A point in the window's content (from its top left, as SwiftUI's
    /// global space) on screen.
    func screenPoint(_ point: CGPoint) -> NSPoint {
        NSPoint(x: window.frame.minX + point.x, y: window.frame.maxY - point.y)
    }

    /// Shows the window for the first time.
    func showAsNewWindow(frame: NSRect? = nil) {
        if let frame {
            window.setFrame(frame, display: false)
        } else if tabs.contains(where: \.isLibraryTab), window.setFrameUsingName(Self.frameName) {
            // Where the library was last.
        } else {
            if !tabs.contains(where: \.isLibraryTab) { window.setContentSize(NSSize(width: 820, height: 760)) }
            window.center()
        }
        buttonsKeeper.start()
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: NSWindowDelegate

    func windowDidBecomeMain(_ notification: Notification) {
        workspace?.windowBecameMain(self)
    }

    func windowDidResignMain(_ notification: Notification) {
        workspace?.windowResignedMain(self)
    }

    func windowWillClose(_ notification: Notification) {
        workspace?.windowWillClose(self)
    }

    /// After every event: AppKit puts the zoom button back at its own place
    /// when the title changes (a tab selected), without saying so. Placing
    /// them again costs nothing when nothing moved.
    func windowDidUpdate(_ notification: Notification) {
        buttonsKeeper.place()
    }

    func windowWillEnterFullScreen(_ notification: Notification) {
        state.windowButtonsWidth = nil
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        buttonsKeeper.place()
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        buttonsKeeper.place()
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        saveFrame()
    }

    func windowDidMove(_ notification: Notification) {
        saveFrame()
    }

    private func saveFrame() {
        guard tabs.contains(where: \.isLibraryTab), !window.styleMask.contains(.fullScreen) else { return }
        window.saveFrame(usingName: Self.frameName)
    }
}

/// Every Minote window: the tab shortcuts work in these only.
final class PageNSWindow: NSWindow {
    /// The tab bar lies where a titlebar would be, and AppKit starts moving
    /// the window from a press on anything there that doesn't refuse it
    /// (SwiftUI's views don't): a tab couldn't be clicked or dragged. Only the
    /// bar's empty parts (`WindowDragArea`) move the window.
    override func sendEvent(_ event: NSEvent) {
        guard event.type == .leftMouseDown, isMovable, let frameView = contentView?.superview,
              event.locationInWindow.y >= frame.height - TitlebarLayout.height,
              let hit = frameView.hitTest(event.locationInWindow), hit.isDescendant(of: contentView!),
              !(hit is WindowDragArea.DragView) else {
            super.sendEvent(event)
            return
        }
        isMovable = false
        super.sendEvent(event)
        isMovable = true
    }

}

/// A window's content: the sidebar with its header, and beside it the tab bar
/// over the page of the tab in front.
struct PageView: View {
    let page: PageWindow
    let workspace: Workspace
    @Bindable var state: WindowState

    @AppStorage(PreferenceKey.appearance) private var theme = PageTheme.system
    @AppStorage(PreferenceKey.sidebarWidth) private var sidebarWidth = SidebarMetrics.defaultWidth

    var body: some View {
        let palette = theme.palette
        HStack(spacing: 0) {
            if state.isSidebarVisible {
                SidebarColumn(library: workspace.library, state: state, workspace: workspace, palette: palette)
                    .frame(width: sidebarWidth)
                    .transition(.move(edge: .leading))
                SidebarDivider(width: $sidebarWidth, palette: palette)
            }
            VStack(spacing: 0) {
                TabBar(page: page, workspace: workspace, state: state, palette: palette)
                if let tab = state.selectedTab {
                    EditorPage(tab: tab, windowState: state)
                        .id(ObjectIdentifier(tab))
                } else {
                    Color(nsColor: palette.background)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .clipped()
        .background(Color(nsColor: palette.background))
        .background(WindowBackground(color: palette.background))
        .onChange(of: state.isSidebarVisible, initial: true) { _, visible in
            if visible { workspace.loadLibrary() }
        }
        .onChange(of: titles) {
            page.updateTitle()
            // Tabs are kept by file name: a note renamed (or a draft saved) changes them.
            workspace.tabsDidChange()
        }
        .sheet(item: $state.renaming) { note in
            RenameSheet(note: note, library: workspace.library) { state.renaming = nil }
        }
        .libraryErrorAlert(workspace.library, isEnabled: workspace.alertWindow === page)
    }

    private var titles: [String?] {
        [state.selectedTab?.title] + state.tabs.map(\.fileName)
    }
}
