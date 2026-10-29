import AppKit
import MinoteEditor
import MinoteKit
import SwiftUI

/// Every window and tab, and where opened notes and files go. A note or file
/// opens in the window in front: it takes the place of a library tab nobody
/// typed in, and otherwise gets a new tab beside the one in front (see
/// `OpenPlacement`). Opening stays light: a file from Finder with no window
/// open gets a window of its own, and the library is read only once a window
/// shows it.
@Observable
final class Workspace {
    let library: Library
    let storage: LibraryStorageSwitcher

    /// The window in front (main): the menus act on its front tab.
    private(set) var frontWindow: PageWindow?
    /// The library window that shows the library's alerts: the latest in front.
    private(set) var alertWindow: PageWindow?
    /// File ▸ Open Recent, newest first. The system keeps the app's access to
    /// these files across launches.
    private(set) var recents: [URL] = []

    @ObservationIgnored private var windows: [PageWindow] = []
    /// Files whose tab closed while their last save was still on its way.
    @ObservationIgnored private var closingFiles: [OpenedFile] = []
    @ObservationIgnored private var accessedRecents: Set<URL> = []
    @ObservationIgnored private var loading: Task<Void, Never>?
    /// The tabs of the last session are put back once, when the library first loads.
    @ObservationIgnored private var restoresTabs = true
    @ObservationIgnored private var tabsSave: Task<Void, Never>?

    init() {
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
        library.openHandler = { [weak self] id in self?.open(note: id) }
        library.shownNoteRemovedHandler = { [weak self] editor in self?.closeTab(showing: editor) ?? false }
    }

    var hasWindows: Bool { !windows.isEmpty }

    /// The tab the menus act on: the front window's.
    var frontTab: PageTab? { frontWindow?.selectedTab }

    // MARK: The library

    /// Reads the library the first time a window shows it; later calls get the same task.
    @discardableResult
    func loadLibrary() -> Task<Void, Never> {
        if let loading { return loading }
        let task = Task { @MainActor in
            await storage.open()
            restoreTabs()
        }
        loading = task
        return task
    }

    /// Brings a library tab forward, or opens a window with one (at launch,
    /// from the Dock, Launchpad or Spotlight, or for a library command).
    func showLibrary() {
        for window in orderedWindows {
            if let tab = window.selectedTab, tab.isLibraryTab {
                window.bringForward(tab)
                return
            }
            if let tab = window.tabs.first(where: \.isLibraryTab) {
                window.bringForward(tab)
                return
            }
        }
        let window = makeWindow(sidebar: true)
        let tab = makeTab(.library, restoring: true)
        library.attach(tab.editor)
        window.insert(tab)
        if library.isLoaded, tab.noteID == nil, let id = freeNote() {
            library.show(id, in: tab.editor)
        }
        window.showAsNewWindow()
        loadLibrary()
        restoreTabs()
    }

    // MARK: Opening notes

    /// Shows a library note: brings its tab forward if it has one, otherwise
    /// puts it where `OpenPlacement` says. `newTab` asks for a tab of its own.
    func open(note id: Note.ID, newTab: Bool = false, focus: Bool = true) {
        guard library.note(with: id) != nil else { return }
        if let tab = tab(showing: id), let window = tab.window {
            window.bringForward(tab, focus: focus)
            return
        }
        let front = targetWindow?.selectedTab
        switch OpenPlacement.of(isOpen: false, front: front?.placement, forceNewTab: newTab) {
        case .replaceFront:
            guard let front, let window = front.window else { return }
            library.show(id, in: front.editor)
            window.bringForward(front, focus: focus)
        case .newTab:
            guard let window = front?.window else { return }
            let tab = makeTab(.library)
            library.show(id, in: tab.editor)
            window.insert(tab, focus: focus)
            window.window.makeKeyAndOrderFront(nil)
        case .newWindow, .focusExisting:
            let window = makeWindow(sidebar: true)
            let tab = makeTab(.library)
            library.show(id, in: tab.editor)
            window.insert(tab, focus: focus)
            window.showAsNewWindow()
        }
        tabsDidChange()
    }

    /// File ▸ New Tab and the tab bar's "+": an empty note in a tab of its
    /// own, in the given window or the one in front.
    func newTab(in window: PageWindow? = nil) {
        Task { @MainActor in
            await loadLibrary().value
            guard let id = library.makeDraft() else { return }
            let tab = makeTab(.library)
            library.show(id, in: tab.editor)
            if let window = window ?? targetWindow {
                window.insert(tab)
                window.window.makeKeyAndOrderFront(nil)
            } else {
                let window = makeWindow(sidebar: true)
                window.insert(tab)
                window.showAsNewWindow()
            }
            tabsDidChange()
        }
    }

    /// File ▸ New Note: a new draft where notes open, or the empty one in front.
    func newNote() {
        Task { @MainActor in
            await loadLibrary().value
            if let tab = targetWindow?.selectedTab, tab.isLibraryTab, tab.note?.isDraft == true,
               tab.editor.currentText().isBlank, let window = tab.window {
                window.bringForward(tab)
                return
            }
            guard let id = library.makeDraft() else { return }
            open(note: id)
        }
    }

    // MARK: Opening files

    /// Finder (double-click, Open With), files dropped on the Dock icon, recent files.
    func open(_ url: URL) {
        let url = url.standardizedFileURL.resolvingSymlinksInPath()
        guard OpenedFile.canOpen(url) else {
            NSSound.beep()
            return
        }
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        refreshRecents()

        // One of the library's own notes: two editors on one file would
        // overwrite each other. Only a library that's already loaded is
        // asked; opening a file never loads it.
        if library.isLoaded, let note = library.notes.first(where: { $0.fileURL?.path == url.path }) {
            open(note: note.id)
            return
        }
        if let tab = allTabs.first(where: { $0.file?.url == url }), let window = tab.window {
            window.bringForward(tab)
            return
        }
        let front = targetWindow?.selectedTab
        let file = OpenedFile(url: url)
        let tab = makeTab(.file(file))
        file.library.attach(tab.editor)
        switch OpenPlacement.of(isOpen: false, front: front?.placement) {
        case .replaceFront:
            guard let front, let window = front.window else { return }
            window.replace(front, with: tab)
            window.window.makeKeyAndOrderFront(nil)
        case .newTab:
            guard let window = front?.window else { return }
            window.insert(tab)
            window.window.makeKeyAndOrderFront(nil)
        case .newWindow, .focusExisting:
            let window = makeWindow(sidebar: false)
            window.insert(tab)
            window.showAsNewWindow()
        }
        tabsDidChange()
        Task { await file.library.load() }
    }

    /// File ▸ Open…
    func showOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = OpenedFile.contentTypes
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { open(url) }
    }

    // MARK: Recent files

    func openRecent(_ url: URL) {
        // Recent files may come back as security-scoped URLs.
        if !accessedRecents.contains(url), url.startAccessingSecurityScopedResource() {
            accessedRecents.insert(url)
        }
        open(url)
    }

    func clearRecents() {
        NSDocumentController.shared.clearRecentDocuments(nil)
        refreshRecents()
    }

    /// The file's name, with its folder when another recent file has the same name.
    func recentTitle(for url: URL) -> String {
        let name = url.lastPathComponent
        let sameName = recents.filter { $0.lastPathComponent == name }.count
        guard sameName > 1 else { return name }
        return "\(name) — \(url.deletingLastPathComponent().lastPathComponent)"
    }

    /// Reads File ▸ Open Recent from the system (at launch, and after changes).
    func refreshRecents() {
        recents = NSDocumentController.shared.recentDocumentURLs
    }

    // MARK: Tabs

    /// ⌘1…⌘9: the tab at `index` of the front window; nil for the last one.
    func selectTab(at index: Int?) {
        guard let window = targetWindow, !window.tabs.isEmpty else { return }
        let tabs = window.tabs
        window.select(tabs[index.map { min($0, tabs.count - 1) } ?? tabs.count - 1])
    }

    /// ⌃Tab, ⌘⇧], and back.
    func selectTab(offset: Int) {
        targetWindow?.selectTab(offset: offset)
    }

    /// File ▸ Close Tab.
    func closeFrontTab() {
        guard let window = targetWindow, let tab = window.selectedTab else { return }
        window.close(tab)
    }

    /// A middle click: closes the tab under the pointer, if there is one.
    func closeHoveredTab(in nsWindow: NSWindow) -> Bool {
        guard let window = windows.first(where: { $0.window === nsWindow }), let hovered = window.state.hoveredTab,
              let tab = window.tabs.first(where: { $0.id == hovered }) else { return false }
        window.close(tab)
        return true
    }

    /// Moves a tab into another window's bar, at `index` (the end if nil).
    func move(_ tab: PageTab, to target: PageWindow, at index: Int? = nil) {
        guard let source = tab.window else { return }
        if source === target {
            source.move(tab, to: index ?? source.tabs.count - 1)
            return
        }
        source.remove(tab)
        target.insert(tab, at: index ?? target.tabs.count)
        target.window.makeKeyAndOrderFront(nil)
    }

    /// Window ▸ Move Tab to New Window, or a tab dragged out of its bar: a
    /// window of its own, its top left corner at `topLeft` if given. A
    /// window's only tab moves the window instead.
    func moveToNewWindow(_ tab: PageTab, topLeft: NSPoint? = nil) {
        guard let source = tab.window else { return }
        let frame = source.window.frame
        if source.tabs.count == 1 {
            if let topLeft { source.window.setFrameTopLeftPoint(topLeft) }
            return
        }
        source.remove(tab)
        let window = makeWindow(sidebar: source.state.isSidebarVisible)
        window.insert(tab)
        let origin = topLeft.map { NSPoint(x: $0.x, y: $0.y - frame.height) } ?? NSPoint(x: frame.minX + 28, y: frame.minY - 28)
        window.showAsNewWindow(frame: NSRect(origin: origin, size: frame.size))
    }

    /// Window ▸ Merge All Windows: every tab in the front window, in order.
    func mergeAllWindows() {
        guard let target = targetWindow else { return }
        let selected = target.selectedTab
        for window in orderedWindows where window !== target {
            for tab in window.tabs {
                move(tab, to: target)
            }
        }
        if let selected { target.bringForward(selected) }
    }

    /// A tab pulled out of its bar and let go at a point on screen: into the
    /// bar under it, or into a window of its own there.
    func drop(_ tab: PageTab, at point: NSPoint) {
        if let target = dropTarget(at: point) {
            move(tab, to: target.window, at: target.index)
        } else {
            moveToNewWindow(tab, topLeft: NSPoint(x: point.x - 80, y: point.y + TitlebarLayout.height / 2))
        }
    }

    /// The window whose tab bar is under a point on screen (a tab being
    /// dropped there), with where the tab goes in it.
    func dropTarget(at point: NSPoint) -> (window: PageWindow, index: Int)? {
        for window in orderedWindows where window.window.isVisible {
            let frame = window.window.frame
            guard frame.contains(point) else { continue }
            // The front-most window under the point decides.
            guard point.y >= frame.maxY - TitlebarLayout.height, let strip = window.state.strip else { return nil }
            let x = point.x - frame.minX - strip.frame.minX + strip.scrollOffset
            let index = Int((x / max(strip.tabWidth, 1)).rounded())
            return (window, min(max(index, 0), window.tabs.count))
        }
        return nil
    }

    /// A note a tab showed was removed: the tab closes if its window has
    /// others; a window's last tab shows another note instead.
    private func closeTab(showing editor: any NoteEditor) -> Bool {
        guard let tab = allTabs.first(where: { $0.editor === editor }), let window = tab.window, window.tabs.count > 1 else { return false }
        window.close(tab)
        return true
    }

    /// The tab is closing: its note is wrapped up and saved; a file stops being watched.
    func tabWillClose(_ tab: PageTab) {
        switch tab.content {
        case .library:
            library.detach(tab.editor)
        case .file(let file):
            closingFiles.append(file)
            Task { @MainActor in
                await file.finish(editor: tab.editor)
                // A save that failed keeps retrying; quitting asks about it.
                if !file.library.hasUnsavedChanges {
                    closingFiles.removeAll { $0 === file }
                }
            }
        }
    }

    // MARK: Windows

    func windowBecameMain(_ window: PageWindow) {
        frontWindow = window
        if let tab = window.selectedTab {
            tab.library.activate(tab.editor)
            // In case the watcher missed something (e.g. while the Mac slept).
            if let file = tab.file, file.library.isLoaded { file.library.scheduleRescan() }
        }
        if window.tabs.contains(where: \.isLibraryTab) { alertWindow = window }
        tabsDidChange()
    }

    func windowResignedMain(_ window: PageWindow) {
        if frontWindow === window { frontWindow = nil }
    }

    /// The window closed with every tab in it.
    func windowWillClose(_ window: PageWindow) {
        defer { tabsDidChange() }
        for tab in window.tabs { tabWillClose(tab) }
        window.state.tabs = []
        window.state.selectedTab = nil
        windows.removeAll { $0 === window }
        if frontWindow === window { frontWindow = nil }
        if alertWindow === window { alertWindow = orderedWindows.first { $0.tabs.contains(where: \.isLibraryTab) } }
    }

    /// A new tab. Library tabs the user opens themselves take the place of
    /// the last session's, if those weren't put back yet (`restoring` is for
    /// the tabs put back).
    private func makeTab(_ content: PageTab.Content, restoring: Bool = false) -> PageTab {
        if case .library = content, library.isLoaded, !restoring { restoresTabs = false }
        switch content {
        case .library: return PageTab(content: content, library: library)
        case .file(let file): return PageTab(content: content, library: file.library)
        }
    }

    private func makeWindow(sidebar: Bool) -> PageWindow {
        let window = PageWindow(workspace: self, sidebar: sidebar)
        windows.append(window)
        return window
    }

    private var allTabs: [PageTab] {
        windows.flatMap(\.tabs)
    }

    private func tab(showing id: Note.ID) -> PageTab? {
        allTabs.first { $0.isLibraryTab && $0.editor.displayedNoteID == id }
    }

    /// Minote's windows, front to back (on screen first).
    private var orderedWindows: [PageWindow] {
        let onScreen = NSApp.orderedWindows.compactMap { window in windows.first { $0.window === window } }
        return onScreen + windows.filter { window in !onScreen.contains { $0 === window } }.reversed()
    }

    /// The window in front: where opened things go.
    var targetWindow: PageWindow? {
        orderedWindows.first { $0.window.isVisible } ?? orderedWindows.first
    }

    /// A note no tab shows, or a new draft.
    private func freeNote() -> Note.ID? {
        library.selectedNote.flatMap { library.editor(showing: $0.id) == nil ? $0.id : nil }
            ?? library.notes.first { library.editor(showing: $0.id) == nil }?.id
            ?? library.makeDraft()
    }

    #if DEBUG
    /// Every window's tabs, front window first, for interaction tests.
    func describeTabs() -> String {
        var lines: [String] = []
        for window in orderedWindows {
            lines.append("window \(window.window.frame) sidebar \(window.state.isSidebarVisible)")
            for tab in window.tabs {
                let kind = tab.isLibraryTab ? "note" : "file"
                let marks = [tab === window.selectedTab ? "selected" : nil, tab.isEdited ? "edited" : nil,
                             tab.isUntouched ? "italic" : nil].compactMap { $0 }
                lines.append("  \(kind) \"\(tab.title)\" \(marks.joined(separator: " "))")
            }
        }
        lines.append("library loaded \(library.isLoaded), notes \(library.notes.count), selected \(library.selectedNote?.displayTitle ?? "-")")
        return lines.joined(separator: "\n")
    }
    #endif

    // MARK: Tabs across launches

    /// Saves the tabs soon, once for a burst of changes. They're saved as they
    /// change, not when quitting: Minote supports sudden termination, so a
    /// quit with nothing left to write ends the app without asking it.
    func tabsDidChange() {
        guard tabsSave == nil else { return }
        tabsSave = Task { @MainActor in
            // After AppKit is done ordering the windows.
            try? await Task.sleep(for: .milliseconds(100))
            tabsSave = nil
            saveTabs()
        }
    }

    /// The library tabs of every window, front window first.
    func saveTabs() {
        // A library never loaded this session (or not yet given back its
        // tabs) leaves the last session's tabs alone.
        guard library.isLoaded, !restoresTabs else { return }
        let saved = orderedWindows.compactMap { window -> SavedTabs.Window? in
            let names = window.tabs.map(\.fileName)
            let kept = names.compactMap { $0 }
            guard !kept.isEmpty else { return nil }
            let selected = window.selectedTab.flatMap(window.index(of:)) ?? 0
            let front = names.prefix(selected).compactMap { $0 }.count
            let untouched = window.tabs.filter(\.isUntouched).compactMap(\.fileName)
            return SavedTabs.Window(notes: kept, front: min(front, kept.count - 1), untouched: untouched.isEmpty ? nil : untouched)
        }
        SavedTabs(windows: saved).save()
    }

    /// Puts back the last session's library tabs, starting in the first
    /// library window (opened at launch, or later after a file from Finder),
    /// if nothing happened to it meanwhile.
    private func restoreTabs() {
        let libraryTabs = allTabs.filter(\.isLibraryTab)
        guard restoresTabs, library.isLoaded, !libraryTabs.isEmpty else { return }
        restoresTabs = false
        let names = Set(library.notes.compactMap { $0.fileURL?.lastPathComponent })
        guard libraryTabs.count == 1, let first = libraryTabs.first, !first.isEdited, let firstWindow = first.window,
              let saved = SavedTabs.load()?.restored(existing: names), !saved.windows.isEmpty else { return }

        library.show(nil, in: first.editor)
        // Back to front, so the window that was in front ends up there.
        for (index, savedWindow) in saved.windows.enumerated().reversed() {
            let notes = savedWindow.notes.compactMap { name in
                library.notes.first { $0.fileURL?.lastPathComponent == name }.map { (id: $0.id, name: name) }
            }.filter { library.editor(showing: $0.id) == nil }
            guard !notes.isEmpty else { continue }
            let window = index == 0 ? firstWindow : makeWindow(sidebar: firstWindow.state.isSidebarVisible)
            var restored: [PageTab] = []
            for note in notes {
                let tab = index == 0 && restored.isEmpty ? first : makeTab(.library, restoring: true)
                library.show(note.id, in: tab.editor)
                tab.isEdited = !savedWindow.isUntouched(note.name)
                if tab !== first {
                    let after = restored.last.flatMap(window.index(of:)).map { $0 + 1 }
                    window.insert(tab, at: after, select: false, focus: false)
                }
                restored.append(tab)
            }
            let front = restored.indices.contains(savedWindow.front) ? restored[savedWindow.front] : restored[restored.count - 1]
            window.select(front, focus: index == 0)
            if window !== firstWindow {
                let offset = CGFloat(index) * 24
                window.showAsNewWindow(frame: firstWindow.window.frame.offsetBy(dx: offset, dy: -offset))
            }
        }
        if first.noteID == nil, let id = freeNote() {
            library.show(id, in: first.editor)
        }
        if let selected = firstWindow.selectedTab { firstWindow.bringForward(selected) }
        tabsDidChange()
    }

    // MARK: Saving

    private var fileLibraries: [Library] {
        allTabs.compactMap(\.file?.library) + closingFiles.map(\.library)
    }

    /// When Minote is left: every note and file on disk, the tabs remembered.
    func saveAll() async {
        if library.isLoaded { await library.saveNow() }
        for library in fileLibraries { await library.saveNow() }
        saveTabs()
    }

    func prepareForTermination() async {
        if library.isLoaded { await library.prepareForTermination() }
        for library in fileLibraries { await library.prepareForTermination() }
        saveTabs()
    }

    var hasUnsavedChanges: Bool {
        (library.isLoaded && library.hasUnsavedChanges) || fileLibraries.contains { $0.hasUnsavedChanges }
    }

    func cancelTermination() {
        if library.isLoaded { library.cancelTermination() }
        for library in fileLibraries { library.cancelTermination() }
    }
}
