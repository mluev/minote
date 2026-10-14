import AppKit
import MinoteEditor
import MinoteKit
import SwiftUI

/// Every tab and where opened notes and files go. A note or file opens in the
/// window in front: it takes the place of a library tab nobody typed in, and
/// otherwise gets a new tab beside the one in front (see `OpenPlacement`).
/// Opening stays light: a file from Finder with no window open gets a window
/// of its own, and the library is read only once a window shows it.
@Observable
final class Workspace {
    let library: Library
    let storage: LibraryStorageSwitcher

    /// The tab in front (its window is main): the menus act on it.
    private(set) var frontPage: PageWindow?
    /// The library tab that shows the library's alerts: the latest in front.
    private(set) var alertPage: PageWindow?
    /// File ▸ Open Recent, newest first. The system keeps the app's access to
    /// these files across launches.
    private(set) var recents: [URL] = []

    @ObservationIgnored private var pages: [PageWindow] = []
    /// Files whose tab closed while their last save was still on its way.
    @ObservationIgnored private var closingFiles: [OpenedFile] = []
    @ObservationIgnored private var accessedRecents: Set<URL> = []
    @ObservationIgnored private var loading: Task<Void, Never>?
    /// The tabs of the last session are put back once, when the library first loads.
    @ObservationIgnored private var restoresTabs = true
    @ObservationIgnored private var tabsSave: Task<Void, Never>?
    /// The tab group of the window in front, watched for tabs dragged into another order.
    @ObservationIgnored private weak var watchedGroup: NSWindowTabGroup?
    @ObservationIgnored private var groupObservation: NSKeyValueObservation?

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

    var hasWindows: Bool { !pages.isEmpty }

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

    /// Brings a library window forward, or opens one (at launch, from the
    /// Dock, Launchpad or Spotlight, or for a library command).
    func showLibrary() {
        if let page = frontmost(where: \.isLibraryPage) {
            page.bringForward()
            return
        }
        let page = makePage(.library, sidebar: .all, restoring: true)
        library.attach(page.editor)
        if library.isLoaded, page.windowState.noteID == nil, let id = freeNote() {
            library.show(id, in: page.editor)
        }
        page.showAsNewWindow()
        loadLibrary()
        restoreTabs()
    }

    // MARK: Opening notes

    /// Shows a library note: brings its tab forward if it has one, otherwise
    /// puts it where `OpenPlacement` says. `newTab` asks for a tab of its own.
    func open(note id: Note.ID, newTab: Bool = false, focus: Bool = true) {
        guard library.note(with: id) != nil else { return }
        if let editor = library.editor(showing: id), let page = page(for: editor) {
            page.bringForward()
            if focus { page.editor.focus() }
            return
        }
        let front = targetPage
        let page: PageWindow
        switch OpenPlacement.of(isOpen: false, front: front?.frontTab, forceNewTab: newTab) {
        case .replaceFront:
            guard let front else { return }
            page = front
            library.show(id, in: page.editor)
            page.bringForward()
        case .newTab:
            guard let front else { return }
            page = makePage(.library, sidebar: front.windowState.columnVisibility)
            library.show(id, in: page.editor)
            front.window.addTabbedWindow(page.window, ordered: .above)
            page.bringForward()
        case .newWindow, .focusExisting:
            page = makePage(.library, sidebar: .all)
            library.show(id, in: page.editor)
            page.showAsNewWindow()
        }
        if focus { page.editor.focus() }
        tabsDidChange()
    }

    /// File ▸ New Tab and the tab bar's "+": an empty note in a tab of its own.
    func newTab() {
        Task { @MainActor in
            await loadLibrary().value
            guard let id = library.makeDraft() else { return }
            let front = targetPage
            let page = makePage(.library, sidebar: front?.windowState.columnVisibility ?? .all)
            library.show(id, in: page.editor)
            if let front {
                front.window.addTabbedWindow(page.window, ordered: .above)
                page.bringForward()
            } else {
                page.showAsNewWindow()
            }
            page.editor.focus()
            tabsDidChange()
        }
    }

    /// File ▸ New Note: a new draft where notes open, or the empty one in front.
    func newNote() {
        Task { @MainActor in
            await loadLibrary().value
            if let page = targetPage, page.isLibraryPage, let id = page.windowState.noteID,
               library.note(with: id)?.isDraft == true, page.editor.currentText().isBlank {
                page.bringForward()
                page.editor.focus()
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
        if let page = pages.first(where: { $0.file?.url == url }) {
            page.bringForward()
            return
        }
        let front = targetPage
        let file = OpenedFile(url: url)
        let page = makePage(.file(file), sidebar: front?.windowState.columnVisibility ?? .detailOnly)
        file.library.attach(page.editor)
        switch OpenPlacement.of(isOpen: false, front: front?.frontTab) {
        case .replaceFront:
            guard let front else { return }
            front.window.addTabbedWindow(page.window, ordered: .below)
            page.bringForward()
            front.window.close()
        case .newTab:
            guard let front else { return }
            front.window.addTabbedWindow(page.window, ordered: .above)
            page.bringForward()
        case .newWindow, .focusExisting:
            page.showAsNewWindow()
        }
        page.editor.focus()
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

    /// Window ▸ the tab at `index` of the front window; nil for the last one.
    func selectTab(at index: Int?) {
        guard let window = targetPage?.window, let tabs = window.tabbedWindows, !tabs.isEmpty else { return }
        let tab = index.map { min($0, tabs.count - 1) } ?? tabs.count - 1
        page(for: tabs[tab])?.bringForward()
    }

    /// Showing or hiding the sidebar does it for every tab of the window, so
    /// switching tabs doesn't move the page. Showing it loads the library.
    func sidebarVisibilityChanged(in page: PageWindow) {
        let visibility = page.windowState.columnVisibility
        if visibility != .detailOnly { loadLibrary() }
        for window in page.window.tabbedWindows ?? [] {
            guard let other = self.page(for: window), other !== page,
                  other.windowState.columnVisibility != visibility else { continue }
            other.windowState.columnVisibility = visibility
        }
    }

    /// A note the tab showed was removed: the tab closes if its window has
    /// others; a window's last tab shows another note instead.
    private func closeTab(showing editor: any NoteEditor) -> Bool {
        guard let page = page(for: editor), (page.window.tabbedWindows?.count ?? 1) > 1 else { return false }
        page.window.close()
        return true
    }

    // MARK: Pages

    func pageBecameMain(_ page: PageWindow) {
        frontPage = page
        page.library.activate(page.editor)
        if page.isLibraryPage { alertPage = page }
        watchTabOrder(of: page.window)
        tabsDidChange()
        // In case the watcher missed something (e.g. while the Mac slept).
        if let file = page.file, file.library.isLoaded { file.library.scheduleRescan() }
    }

    func pageResignedMain(_ page: PageWindow) {
        if frontPage === page { frontPage = nil }
    }

    /// The tab closed: its note is wrapped up and saved; a file stops being watched.
    func pageWillClose(_ page: PageWindow) {
        defer { tabsDidChange() }
        pages.removeAll { $0 === page }
        if frontPage === page { frontPage = nil }
        if alertPage === page { alertPage = frontmost(where: \.isLibraryPage) }
        switch page.content {
        case .library:
            library.detach(page.editor)
        case .file(let file):
            closingFiles.append(file)
            Task { @MainActor in
                await file.finish(editor: page.editor)
                // A save that failed keeps retrying; quitting asks about it.
                if !file.library.hasUnsavedChanges {
                    closingFiles.removeAll { $0 === file }
                }
            }
        }
    }

    /// A new tab. Library tabs the user opens themselves take the place of
    /// the last session's, if those weren't put back yet (`restoring` is for
    /// the window they're put back into).
    private func makePage(_ content: PageWindow.Content, sidebar: NavigationSplitViewVisibility, restoring: Bool = false) -> PageWindow {
        if case .library = content, library.isLoaded, !restoring { restoresTabs = false }
        let page = PageWindow(content: content, workspace: self, sidebar: sidebar)
        pages.append(page)
        return page
    }

    private func page(for window: NSWindow) -> PageWindow? {
        pages.first { $0.window === window }
    }

    private func page(for editor: any NoteEditor) -> PageWindow? {
        pages.first { $0.editor === editor }
    }

    /// The selected tab of the front-most window: where opened things go.
    var targetPage: PageWindow? {
        frontmost { _ in true }
    }

    /// The front-most window's selected tab that matches.
    private func frontmost(where matches: (PageWindow) -> Bool) -> PageWindow? {
        for window in NSApp.orderedWindows where window.isVisible {
            let selected = window.tabGroup?.selectedWindow ?? window
            if let page = page(for: selected), matches(page) { return page }
        }
        return pages.last(where: matches)
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
        var groups = Set<ObjectIdentifier>()
        var lines: [String] = []
        for window in NSApp.orderedWindows where page(for: window) != nil {
            guard groups.insert(ObjectIdentifier(window.tabGroup ?? window)).inserted else { continue }
            let selected = window.tabGroup?.selectedWindow ?? window
            lines.append("window")
            for tab in (window.tabbedWindows ?? [window]).compactMap({ page(for: $0) }) {
                let kind = tab.isLibraryPage ? "note" : "file"
                let marks = [tab.window === selected ? "selected" : nil, tab.windowState.isEdited ? "edited" : nil,
                             tab.window.tab.attributedTitle != nil ? "italic" : nil].compactMap { $0 }
                lines.append("  \(kind) \"\(tab.window.title)\" \(marks.joined(separator: " "))")
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
            // After AppKit is done moving the windows.
            try? await Task.sleep(for: .milliseconds(100))
            tabsSave = nil
            for page in pages { page.updateTitleVisibility() }
            saveTabs()
        }
    }

    /// Dragging tabs into another order changes nothing else that's watched.
    private func watchTabOrder(of window: NSWindow) {
        guard let group = window.tabGroup, group !== watchedGroup else { return }
        watchedGroup = group
        groupObservation = group.observe(\.windows) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.tabsDidChange() }
        }
    }

    /// The library tabs of every window, front window first.
    func saveTabs() {
        // A library never loaded this session (or not yet given back its
        // tabs) leaves the last session's tabs alone.
        guard library.isLoaded, !restoresTabs else { return }
        var groups = Set<ObjectIdentifier>()
        var windows: [SavedTabs.Window] = []
        for window in NSApp.orderedWindows where page(for: window) != nil {
            guard groups.insert(ObjectIdentifier(window.tabGroup ?? window)).inserted else { continue }
            let tabs = (window.tabbedWindows ?? [window]).compactMap { page(for: $0) }
            let names = tabs.map { page -> String? in
                guard page.isLibraryPage, let id = page.windowState.noteID else { return nil }
                return library.note(with: id)?.fileURL?.lastPathComponent
            }
            let kept = names.compactMap { $0 }
            guard !kept.isEmpty else { continue }
            let selected = window.tabGroup?.selectedWindow ?? window
            let selectedIndex = tabs.firstIndex { $0.window === selected } ?? 0
            let front = names.prefix(selectedIndex).compactMap { $0 }.count
            windows.append(SavedTabs.Window(notes: kept, front: min(front, kept.count - 1)))
        }
        SavedTabs(windows: windows).save()
    }

    /// Puts back the last session's library tabs, starting in the first
    /// library window (opened at launch, or later after a file from Finder),
    /// if nothing happened to it meanwhile.
    private func restoreTabs() {
        let libraryPages = pages.filter(\.isLibraryPage)
        guard restoresTabs, library.isLoaded, !libraryPages.isEmpty else { return }
        restoresTabs = false
        let names = Set(library.notes.compactMap { $0.fileURL?.lastPathComponent })
        guard libraryPages.count == 1, let first = libraryPages.first, !first.windowState.isEdited,
              let saved = SavedTabs.load()?.restored(existing: names), !saved.windows.isEmpty else { return }

        library.show(nil, in: first.editor)
        // Back to front, so the window that was in front ends up there.
        for (index, window) in saved.windows.enumerated().reversed() {
            var tabs: [PageWindow] = []
            for name in window.notes {
                guard let id = library.notes.first(where: { $0.fileURL?.lastPathComponent == name })?.id,
                      library.editor(showing: id) == nil else { continue }
                let page = index == 0 && tabs.isEmpty ? first : makePage(.library, sidebar: first.windowState.columnVisibility, restoring: true)
                library.show(id, in: page.editor)
                if let last = tabs.last {
                    last.window.addTabbedWindow(page.window, ordered: .above)
                } else if page !== first {
                    page.window.setFrame(first.window.frame.offsetBy(dx: CGFloat(index) * 24, dy: CGFloat(-index) * 24), display: false)
                    page.window.orderFront(nil)
                }
                tabs.append(page)
            }
            let front = tabs.indices.contains(window.front) ? tabs[window.front] : tabs.last
            front?.bringForward()
        }
        if first.windowState.noteID == nil, let id = freeNote() {
            library.show(id, in: first.editor)
        }
        tabsDidChange()
    }

    // MARK: Saving

    private var fileLibraries: [Library] {
        pages.compactMap(\.file?.library) + closingFiles.map(\.library)
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
