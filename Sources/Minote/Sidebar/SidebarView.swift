import AppKit
import MinoteEditor
import MinoteKit
import SwiftUI

/// The library as the sidebar lists it: folders that open and close, the
/// notes in them, or a flat list (by date, or none), filtered by the search
/// above. Its own rows rather than a system list: the page's paper a shade
/// darker, and a soft rounded selection instead of the accent-colored
/// capsule. The highlighted row is the front tab's note; opening a note
/// follows the tab rules (`Workspace.open(note:)`).
struct SidebarView: View {
    @Bindable var library: Library
    @Bindable var state: WindowState
    let workspace: Workspace
    @Environment(\.undoManager) private var undoManager
    @FocusState private var isListFocused: Bool
    @ViewState private var hoveredRow: String? = nil
    @ViewState private var drag: SidebarDragState? = nil
    @ViewState private var geometry = SidebarGeometry()
    @AppStorage(PreferenceKey.appearance) private var theme = PageTheme.system

    private var preferences: SidebarPreferences { workspace.sidebar }
    /// The rows' own coordinates: where they are, and where the pointer is, in a drag.
    nonisolated private static let space = "SidebarRows"

    var body: some View {
        let rows = SidebarRows.build(.init(
            notes: library.notes, folders: library.folders, settings: library.folderSettings,
            view: preferences.view, collapsed: preferences.collapsed, scope: state.scope
        ))
        let isTree = preferences.view.groupBy == .folder
        let _ = (geometry.rows = rows)
        ScrollViewReader { proxy in
            let _ = (geometry.proxy = proxy)
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(rows) { row in
                        rowView(row, isTree: isTree)
                            .id(row.id)
                            .opacity(isDragged(row) ? 0.4 : 1)
                            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: { frame in
                                geometry.frames[row.id] = frame
                            }
                    }
                }
                // Rows appear and go at once: folders open and close without motion.
                .transaction { $0.animation = nil }
                .coordinateSpace(.named(Self.space))
                .overlay(alignment: .topLeading) { dropLine }
                .onGeometryChange(for: CGPoint.self) { $0.frame(in: .global).origin } action: { origin in
                    geometry.rowsOrigin = origin
                }
                .padding(.horizontal, 10)
                .padding(.vertical, SidebarGeometry.verticalPadding)
            }
            .onScrollGeometryChange(for: CGRect.self, of: { CGRect(origin: $0.contentOffset, size: $0.containerSize) }) { _, visible in
                geometry.visible = visible
            }
            .windowFrame { geometry.listFrame = $0 }
            .onChange(of: selectedID, initial: true) { _, id in
                // Another note opened: the keyboard goes on from it, and a Shift selection ends.
                state.sidebarCursor = nil
                clearSelection()
                guard let id else { return }
                withAnimation(ChromeMotion.move) { proxy.scrollTo("note:" + id.uuidString) }
            }
            .onChange(of: state.sidebarCursor) { _, id in
                guard let id else { return }
                withAnimation(ChromeMotion.move) { proxy.scrollTo(id) }
            }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($isListFocused)
        .onChange(of: isListFocused) { _, focused in
            state.isSidebarFocused = focused
        }
        .onKeyPress(keys: [.upArrow, .downArrow], phases: [.down, .repeat]) { press in
            let offset = press.key == .upArrow ? -1 : 1
            if press.modifiers.contains(.shift) {
                extendSelection(by: offset, in: rows)
            } else {
                clearSelection()
                step(offset, in: rows)
            }
            return .handled
        }
        .onKeyPress(.leftArrow) { stepOut(in: rows); return .handled }
        .onKeyPress(.rightArrow) { stepIn(in: rows); return .handled }
        .onKeyPress(.return) {
            if let folder = cursorFolder(in: rows) { toggle(folder) } else { state.selectedTab?.editor.focus() }
            return .handled
        }
        .onKeyPress(.escape) {
            if drag != nil {
                cancelDrag()
            } else if !state.sidebarSelection.isEmpty {
                clearSelection()
            } else {
                return .ignored
            }
            return .handled
        }
        .onDeleteCommand {
            // Behind the Whole Library lock screen, the list may still have focus.
            guard !library.isLibraryLocked else { return }
            if !state.sidebarSelection.isEmpty {
                trashSelection()
            } else if let folder = cursorFolder(in: rows) {
                trashFolder(folder)
            } else if let id = selectedID, library.note(with: id) != nil {
                trash(id)
            }
        }
        .onChange(of: state.sidebarFocusRequest) {
            isListFocused = true
        }
        .onAppear { state.secondaryClickHandlers["sidebar"] = menuItems(at:) }
        .onDisappear { state.secondaryClickHandlers["sidebar"] = nil }
        .onChange(of: library.folders) { _, folders in
            // The folder looked into went away: step back to what's left of it.
            while !state.scope.isRoot && !folders.contains(state.scope), let parent = state.scope.parent {
                state.scope = parent
            }
        }
        .overlay {
            if rows.isEmpty && preferences.view.lockedOnly {
                Text("No locked notes here")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Color(nsColor: theme.palette.syntax))
            }
        }
    }

    @ViewBuilder
    private func rowView(_ row: SidebarRow, isTree: Bool) -> some View {
        switch row {
        case .folder(let path, let depth, let count, let isOpen):
            FolderRow(
                path: path, depth: depth, count: count, isOpen: isOpen, palette: theme.palette,
                isHovered: hoveredRow == row.id && drag == nil, isDropTarget: drag?.drop?.highlight == path,
                isKeyboardCursor: isListFocused && state.sidebarCursor == row.id && state.sidebarSelection.isEmpty,
                isPicked: state.sidebarSelection.contains(row.id),
                showsCount: preferences.view.showsCounts,
                isRenaming: state.renamingFolder == path,
                onToggle: {
                    if NSEvent.modifierFlags.contains(.shift) {
                        isListFocused = true
                        extendSelection(to: row)
                    } else {
                        clearSelection()
                        toggle(path)
                    }
                },
                onNewNote: { workspace.newNote(in: path) },
                onRename: { name in rename(path, to: name) }
            )
            .onHover { hover(row, $0) }

            .simultaneousGesture(dragGesture(row, item: .folder(path), title: path.name ?? "", systemImage: "folder"))
        case .note(let note, let depth, let label):
            NoteRow(note: note, palette: theme.palette,
                    isSelected: state.sidebarSelection.isEmpty ? note.id == selectedID : state.sidebarSelection.contains(row.id),
                    isHovered: hoveredRow == row.id && drag == nil,
                    depth: depth, folderLabel: label, showsDate: preferences.view.showsDates, isTree: isTree)
                .contentShape(Rectangle())
                .onTapGesture {
                    isListFocused = true
                    // ⇧-click: picks every row from the last one to this one.
                    if NSEvent.modifierFlags.contains(.shift) {
                        extendSelection(to: row)
                        return
                    }
                    clearSelection()
                    // ⌘-click: a tab of its own.
                    let newTab = NSEvent.modifierFlags.contains(.command)
                    workspace.open(note: note.id, newTab: newTab, focus: false)
                    keepBrowsing(note.id)
                }
                .onHover { hover(row, $0) }

                .simultaneousGesture(dragGesture(row, item: .note(note), title: note.displayTitle, systemImage: "doc.text"))
        case .section(let title):
            SectionHeader(title: title, palette: theme.palette)
        }
    }

    // MARK: Dragging

    /// Pressing a row and moving it: a chip follows the pointer, the folder
    /// under it lights up or a line shows the place it would land; letting
    /// go moves the note or folder there (⌘Z puts it back).
    private func dragGesture(_ row: SidebarRow, item: SidebarDragItem, title: String, systemImage: String) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named(Self.space))
            .onChanged { value in
                if drag == nil {
                    guard !library.isLibraryLocked, state.renamingFolder == nil else { return }
                    var started = SidebarDragState(item: item, rowID: row.id)
                    // A picked row takes the other picked ones along.
                    if state.sidebarSelection.count > 1 && state.sidebarSelection.contains(row.id) {
                        started.group = state.sidebarSelection
                    } else {
                        clearSelection()
                    }
                    drag = started
                    isListFocused = true
                }
                guard var current = drag, !current.isCancelled else { return }
                geometry.pointer = value.location
                updateDrop(&current)
                if current != drag { drag = current }
                if let window = workspace.window(for: state) {
                    let point = CGPoint(x: geometry.rowsOrigin.x + value.location.x, y: geometry.rowsOrigin.y + value.location.y)
                    let count = current.group?.count ?? 1
                    TabDragPreview.shared.show(title: count > 1 ? "\(count) items" : title, italic: false,
                                               systemImage: count > 1 ? "square.stack" : systemImage, palette: theme.palette,
                                               at: window.screenPoint(point))
                }
                autoScrollIfNearEdge()
            }
            .onEnded { _ in
                TabDragPreview.shared.hide()
                geometry.stopTimers()
                let ended = drag
                drag = nil
                guard let ended, !ended.isCancelled, let drop = ended.drop else { return }
                if let group = ended.group {
                    performGroup(drop, moving: group)
                } else {
                    perform(drop, moving: ended.item)
                }
            }
    }

    private func updateDrop(_ current: inout SidebarDragState) {
        let visible = geometry.rows.filter { geometry.frames[$0.id] != nil }
        let frames = visible.compactMap { geometry.frames[$0.id] }
        let pointer = geometry.pointer
        let width = frames.first?.maxX ?? 0
        // Off the list to the side: nothing.
        guard pointer.x > -12, pointer.x < width + 12 else {
            current.drop = nil
            current.lineY = nil
            geometry.scheduleOpening(nil) { _ in }
            return
        }
        let drop = SidebarDrop.resolve(
            rows: visible, frames: frames, y: pointer.y, dragging: current.item, ordering: library.ordering, scope: state.scope,
            isFolderView: preferences.view.groupBy == .folder,
            isSearching: !library.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        )
        current.drop = drop
        if let line = drop?.line {
            current.lineY = line.afterRow.map { frames[$0].maxY + 1 } ?? ((frames.first?.minY ?? 0) - 1)
            current.lineDepth = line.depth
        } else {
            current.lineY = nil
        }
        // Held over a closed folder for a moment: it opens.
        let closed = drop?.highlight.flatMap { preferences.collapsed.contains($0) ? $0 : nil }
        geometry.scheduleOpening(closed) { folder in
            guard drag?.drop?.highlight == folder else { return }
            preferences.collapsed.remove(folder)
        }
    }

    /// Near the list's top or bottom edge: the list scrolls a row at a time
    /// while the pointer stays there.
    private func autoScrollIfNearEdge() {
        guard geometry.autoScroll == nil, geometry.edgeDirection != 0 else { return }
        geometry.autoScroll = Task { @MainActor in
            while !Task.isCancelled, var current = drag, !current.isCancelled, geometry.edgeDirection != 0 {
                let before = geometry.visible.minY
                geometry.scrollOneRow(geometry.edgeDirection)
                try? await Task.sleep(for: .milliseconds(70))
                // The content moved under a still pointer.
                geometry.pointer.y += geometry.visible.minY - before
                updateDrop(&current)
                if current != drag { drag = current }
            }
            geometry.autoScroll = nil
        }
    }

    private func cancelDrag() {
        TabDragPreview.shared.hide()
        geometry.stopTimers()
        drag?.isCancelled = true
        drag?.drop = nil
        drag?.lineY = nil
    }

    private func perform(_ drop: SidebarDrop, moving item: SidebarDragItem) {
        Task {
            switch (drop.target, item) {
            case (.into(let folder), .note(let note)):
                await library.moveNote(note.id, to: folder, undoManager: undoManager)
            case (.at(let folder, let index), .note(let note)):
                await library.moveNote(note.id, to: folder, at: index, undoManager: undoManager)
            case (.into(let folder), .folder(let path)):
                await library.moveFolder(path, into: folder, undoManager: undoManager)
            case (.at(let folder, let index), .folder(let path)):
                await library.moveFolder(path, into: folder, at: index, undoManager: undoManager)
            }
        }
    }

    /// The line where a dragged row would land.
    @ViewBuilder
    private var dropLine: some View {
        if let drag, !drag.isCancelled, let y = drag.lineY {
            Capsule()
                .fill(Color(nsColor: theme.palette.text).opacity(0.55))
                .frame(height: 2)
                .padding(.leading, 6 + CGFloat(drag.lineDepth) * SidebarMetrics.indent)
                .offset(y: y - 1)
                .allowsHitTesting(false)
        }
    }

    private func hover(_ row: SidebarRow, _ inside: Bool) {
        if inside {
            hoveredRow = row.id
        } else if hoveredRow == row.id {
            hoveredRow = nil
        }
    }

    /// The front tab's note, if it's one of the library's.
    private var selectedID: Note.ID? {
        guard let tab = state.selectedTab, tab.isLibraryTab else { return nil }
        return tab.noteID
    }

    // MARK: Keyboard

    /// Where the keyboard is: a folder it was moved onto, else the open note.
    private func cursor(in rows: [SidebarRow]) -> String? {
        if let cursor = state.sidebarCursor, rows.contains(where: { $0.id == cursor }) { return cursor }
        return selectedID.map { "note:" + $0.uuidString }
    }

    private func cursorFolder(in rows: [SidebarRow]) -> FolderPath? {
        guard let id = state.sidebarCursor else { return nil }
        return rows.first { $0.id == id }?.folder
    }

    /// ↑/↓ go through every row: a note opens (under the tab rules, so
    /// browsing stays in one untouched tab), a folder just takes the cursor.
    private func step(_ offset: Int, in rows: [SidebarRow]) {
        guard let row = SidebarRows.row(from: cursor(in: rows), offset: offset, in: rows) else { return }
        go(to: row)
    }

    /// ←: closes the open folder the cursor is on, else goes up to its folder.
    private func stepOut(in rows: [SidebarRow]) {
        guard let current = cursor(in: rows) else { return }
        if let folder = rows.first(where: { $0.id == current })?.folder, preferences.isOpen(folder),
           preferences.view.groupBy == .folder {
            toggle(folder)
        } else if let parent = SidebarRows.parentRow(of: current, in: rows) {
            go(to: parent)
        }
    }

    /// →: opens the closed folder the cursor is on, else steps into it.
    private func stepIn(in rows: [SidebarRow]) {
        guard let current = cursor(in: rows), let row = rows.first(where: { $0.id == current }),
              case .folder(let folder, _, _, let isOpen) = row else { return }
        if !isOpen {
            toggle(folder)
        } else if let next = SidebarRows.row(from: current, offset: 1, in: rows), next.depth > row.depth {
            go(to: next)
        }
    }

    // MARK: Picking several

    private func clearSelection() {
        guard !state.sidebarSelection.isEmpty || state.selectionAnchor != nil else { return }
        state.sidebarSelection = []
        state.selectionAnchor = nil
    }

    /// ⇧-click: every row from where the selection started (or the keyboard's
    /// place) to this one.
    private func extendSelection(to row: SidebarRow) {
        let rows = geometry.rows
        let anchor = state.selectionAnchor ?? cursor(in: rows) ?? row.id
        state.selectionAnchor = anchor
        state.sidebarSelection = Self.range(from: anchor, to: row.id, in: rows)
        state.sidebarCursor = row.id
    }

    /// ⇧↑ / ⇧↓: the selection grows (or shrinks) a row at a time; nothing opens.
    private func extendSelection(by offset: Int, in rows: [SidebarRow]) {
        let current = state.sidebarCursor.flatMap { id in rows.contains { $0.id == id } ? id : nil } ?? cursor(in: rows)
        guard let next = SidebarRows.row(from: current, offset: offset, in: rows) else { return }
        let anchor = state.selectionAnchor ?? current ?? next.id
        state.selectionAnchor = anchor
        state.sidebarSelection = Self.range(from: anchor, to: next.id, in: rows)
        state.sidebarCursor = next.id
    }

    private static func range(from anchor: String, to end: String, in rows: [SidebarRow]) -> Set<String> {
        let picked = rows.filter { if case .section = $0 { false } else { true } }
        guard let a = picked.firstIndex(where: { $0.id == anchor }), let b = picked.firstIndex(where: { $0.id == end }) else {
            return [end]
        }
        return Set(picked[min(a, b)...max(a, b)].map(\.id))
    }

    /// The picked rows as library items, in the list's order.
    private func selectedItems() -> [LibraryEntry] {
        geometry.rows.compactMap { row in
            guard state.sidebarSelection.contains(row.id) else { return nil }
            switch row {
            case .note(let note, _, _): return .note(note.id)
            case .folder(let path, _, _, _): return .folder(path)
            case .section: return nil
            }
        }
    }

    private func moveSelection(to folder: FolderPath) {
        let items = selectedItems()
        clearSelection()
        Task { await library.moveItems(items, to: folder, undoManager: undoManager) }
    }

    /// ⌫ or the menu: the picked rows to the Trash, asking first when folders
    /// with notes in them go along.
    private func trashSelection() {
        let items = library.outermost(selectedItems())
        guard !items.isEmpty else { return }
        Task { @MainActor in
            var inFolders = 0
            for case .folder(let path) in items { inFolders += await library.contentsCount(of: path).notes }
            if inFolders > 0 {
                let alert = NSAlert()
                alert.messageText = "Move \(items.count) items to the Trash?"
                alert.informativeText = "The folders hold \(inFolders == 1 ? "a note" : "\(inFolders) notes"), which go along. ⌘Z puts everything back."
                alert.addButton(withTitle: "Move to Trash")
                alert.addButton(withTitle: "Cancel")
                guard alert.runModal() == .alertFirstButtonReturn else { return }
            }
            clearSelection()
            await library.trashItems(items, undoManager: undoManager)
        }
    }

    private func isDragged(_ row: SidebarRow) -> Bool {
        guard let drag, !drag.isCancelled else { return false }
        return drag.rowID == row.id || drag.group?.contains(row.id) == true
    }

    /// Several rows let go together: they move into the folder the drop is in.
    private func performGroup(_ drop: SidebarDrop, moving ids: Set<String>) {
        let folder: FolderPath = switch drop.target {
        case .into(let folder): folder
        case .at(let folder, _): folder
        }
        let items = geometry.rows.compactMap { row -> LibraryEntry? in
            guard ids.contains(row.id) else { return nil }
            switch row {
            case .note(let note, _, _): return .note(note.id)
            case .folder(let path, _, _, _): return .folder(path)
            case .section: return nil
            }
        }
        clearSelection()
        Task { await library.moveItems(items, to: folder, undoManager: undoManager) }
    }

    private func go(to row: SidebarRow) {
        switch row {
        case .note(let note, _, _):
            state.sidebarCursor = nil
            guard note.id != selectedID else { return }
            workspace.open(note: note.id, focus: false)
            keepBrowsing(note.id)
        case .folder:
            state.sidebarCursor = row.id
        case .section:
            break
        }
    }

    /// The note may already be open in another window: its list takes the
    /// keyboard, so ↑/↓ go on from there.
    private func keepBrowsing(_ id: Note.ID) {
        guard let editor = library.editor(showing: id) as? EditorCoordinator, let window = editor.tab?.window,
              window.state !== state else { return }
        window.state.sidebarFocusRequest += 1
    }

    private func toggle(_ folder: FolderPath) {
        preferences.toggle(folder)
    }

    private func rename(_ folder: FolderPath, to name: String?) {
        guard state.renamingFolder == folder else { return }
        state.renamingFolder = nil
        guard let name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name != folder.name else { return }
        Task { await library.renameFolder(folder, to: name) }
    }

    private func trash(_ id: Note.ID) {
        library.moveToTrash(id, undoManager: undoManager, actionName: "Move to Trash")
    }

    private func trashFolder(_ folder: FolderPath) {
        Task { @MainActor in
            let contents = await library.contentsCount(of: folder)
            if contents.notes + contents.others > 0 {
                let alert = NSAlert()
                let name = folder.name ?? ""
                alert.messageText = contents.notes > 0
                    ? "Move “\(name)” and its \(contents.notes == 1 ? "note" : "\(contents.notes) notes") to the Trash?"
                    : "Move “\(name)” to the Trash?"
                if contents.others > 0 {
                    alert.informativeText = "It also holds \(contents.others == 1 ? "another file" : "\(contents.others) other files"), which go along."
                }
                alert.addButton(withTitle: "Move to Trash")
                alert.addButton(withTitle: "Cancel")
                guard alert.runModal() == .alertFirstButtonReturn else { return }
            }
            await library.trashFolder(folder, undoManager: undoManager)
        }
    }

    // MARK: Menus

    /// What a right-click at a point (window coordinates) offers: the menu of
    /// the row under it, the list's own below the rows, nothing outside the list.
    private func menuItems(at point: CGPoint) -> [ChromeMenuItem]? {
        guard geometry.listFrame.contains(point), !library.isLibraryLocked else { return nil }
        let local = CGPoint(x: point.x - geometry.rowsOrigin.x, y: point.y - geometry.rowsOrigin.y)
        let row = geometry.rows.first { geometry.frames[$0.id]?.contains(local) == true }
        if let row, state.sidebarSelection.count > 1, state.sidebarSelection.contains(row.id) {
            return groupItems()
        }
        if !state.sidebarSelection.isEmpty { clearSelection() }
        switch row {
        case .note(let note, _, _):
            hoveredRow = row?.id
            return noteItems(note)
        case .folder(let folder, _, _, _):
            hoveredRow = row?.id
            return folderItems(folder)
        case .section, nil:
            return emptySpaceItems
        }
    }

    /// The menu for several picked rows: move them together, or trash them.
    private func groupItems() -> [ChromeMenuItem] {
        let items = selectedItems()
        let count = library.outermost(items).count
        let folders = items.compactMap { if case .folder(let path) = $0 { path } else { nil } }
        var targets: [ChromeMenuItem] = [
            .action("Notes", systemImage: "tray.full") { moveSelection(to: .root) },
        ]
        for folder in library.folders {
            let blocked = folders.contains { $0.contains(folder) }
            targets.append(.action(folder.name ?? "", systemImage: "folder", enabled: !blocked, indent: folder.depth - 1) {
                moveSelection(to: folder)
            })
        }
        targets += [.divider, .action("New Folder…", systemImage: "folder.badge.plus") {
            Task { @MainActor in
                guard let folder = await library.newFolder(in: state.scope) else { return }
                moveSelection(to: folder)
                preferences.reveal(folder)
                state.renamingFolder = folder
            }
        }]
        return [
            .submenu("Move \(count) Items to", systemImage: "arrow.right.doc.on.clipboard", targets),
            .divider,
            .action("Move \(count) Items to Trash", systemImage: "trash") { trashSelection() },
            .divider,
            .action("Deselect", systemImage: "xmark", detail: "esc") { clearSelection() },
        ]
    }

    private func noteItems(_ note: Note) -> [ChromeMenuItem] {
        var items: [ChromeMenuItem] = [
            .action("Open in New Tab", systemImage: "plus.square.on.square") {
                workspace.open(note: note.id, newTab: true, focus: false)
            },
            .divider,
            .action("Rename…", systemImage: "pencil", enabled: !note.isBlankDraft) { state.renaming = note },
            .action("Duplicate", systemImage: "plus.square.on.square", enabled: !note.isDraft) {
                Task { await library.duplicate(note.id) }
            },
            moveToItem(current: note.folder) { folder in
                Task { await library.moveNote(note.id, to: folder, undoManager: undoManager) }
            } newFolder: {
                Task { @MainActor in
                    guard let folder = await library.newFolder(in: note.folder) else { return }
                    await library.moveNote(note.id, to: folder, undoManager: undoManager)
                    preferences.reveal(folder)
                    state.renamingFolder = folder
                }
            },
        ]
        if note.isLocked {
            items.append(.action("Remove Lock", systemImage: "lock.open",
                                 enabled: !note.isSealed && library.lockScope != .library) { workspace.removeLock(note.id) })
        } else {
            items.append(.action("Lock Note", systemImage: "lock", enabled: !note.isBlankDraft) { workspace.lockNote(note.id, in: state) })
        }
        items += [
            .action("Show in Finder", systemImage: "folder", enabled: !note.isDraft) {
                if let url = note.fileURL { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            },
            .divider,
            .action("Move to Trash", systemImage: "trash", destructive: true) { trash(note.id) },
        ]
        return items
    }

    private func folderItems(_ folder: FolderPath) -> [ChromeMenuItem] {
        [
            .action("New Note", systemImage: "square.and.pencil") { workspace.newNote(in: folder) },
            .action("New Folder", systemImage: "folder.badge.plus") { workspace.newFolder(in: folder, window: workspace.window(for: state)) },
            .divider,
            .action("Rename", systemImage: "pencil") { state.renamingFolder = folder },
            .action("Show Only This Folder", systemImage: "scope") { state.scope = folder },
            sortItem(folder),
            moveToItem(current: folder.parent ?? .root, moving: folder) { parent in
                Task { await library.moveFolder(folder, into: parent, undoManager: undoManager) }
            } newFolder: {
                Task { @MainActor in
                    guard let parent = await library.newFolder(in: folder.parent ?? .root) else { return }
                    await library.moveFolder(folder, into: parent, undoManager: undoManager)
                    preferences.reveal(parent)
                    state.renamingFolder = parent
                }
            },
            .action("Show in Finder", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([library.url(of: folder)]) },
            .divider,
            .action("Move to Trash", systemImage: "trash", destructive: true) { trashFolder(folder) },
        ]
    }

    private var emptySpaceItems: [ChromeMenuItem] {
        [
            .action("New Note", systemImage: "square.and.pencil", detail: "⌘N") { workspace.newNote(in: state.scope) },
            .action("New Folder", systemImage: "folder.badge.plus", detail: "⇧⌘N") {
                workspace.newFolder(in: state.scope, window: workspace.window(for: state))
            },
        ]
    }

    /// "Move to ▸": the library's folders, the current one disabled (and, for
    /// a folder, itself and what's below it), and a new folder.
    private func moveToItem(current: FolderPath, moving: FolderPath? = nil, move: @escaping (FolderPath) -> Void,
                            newFolder: @escaping () -> Void) -> ChromeMenuItem {
        var items: [ChromeMenuItem] = [
            .action("Notes", systemImage: "tray.full", checked: current.isRoot, enabled: !current.isRoot) { move(.root) },
        ]
        for folder in library.folders {
            let blocked = folder == current || moving?.contains(folder) == true
            items.append(.action(folder.name ?? "", systemImage: "folder", checked: folder == current, enabled: !blocked,
                                 indent: folder.depth - 1) { move(folder) })
        }
        items += [.divider, .action("New Folder…", systemImage: "folder.badge.plus", newFolder)]
        return .submenu("Move to", systemImage: "arrow.right.doc.on.clipboard", items)
    }

    /// "Sort By ▸" for a folder: following the folder above, or its own.
    private func sortItem(_ folder: FolderPath) -> ChromeMenuItem {
        let own = library.folderSettings[folder]?.ownOrder
        let current = library.sortOrder(of: folder)
        var items: [ChromeMenuItem] = []
        if let parent = folder.parent {
            items += [
                .action("Same as “\(parent.name ?? "Notes")”", checked: own == nil) { library.setSort(nil, for: folder) },
                .divider,
            ]
        }
        for sort in NoteSort.allCases {
            items.append(.action(sort.displayName, checked: own?.sort == sort) {
                library.setSort(SortOrder(sort, reversed: sort == .manual ? false : current.reversed), for: folder)
            })
        }
        items += [
            .divider,
            .action("Reverse Order", checked: current.reversed, enabled: current.sort != .manual) {
                library.setSort(SortOrder(current.sort, reversed: !current.reversed), for: folder)
            },
        ]
        return .submenu("Sort By", systemImage: "arrow.up.arrow.down", detail: own?.sort.displayName ?? current.sort.displayName, items)
    }
}

/// A folder: a chevron that turns, its name, the notes inside (at every
/// level) or, under the pointer, a "+" making a note there.
struct FolderRow: View {
    let path: FolderPath
    let depth: Int
    let count: Int
    let isOpen: Bool
    let palette: EditorPalette
    var isHovered = false
    var isDropTarget = false
    /// The keyboard's cursor is on it.
    var isKeyboardCursor = false
    /// Picked with Shift, with other rows.
    var isPicked = false
    var showsCount = true
    var isRenaming = false
    var onToggle: () -> Void = {}
    var onNewNote: () -> Void = {}
    /// The new name, or nil for a rename given up.
    var onRename: (String?) -> Void = { _ in }
    @ViewState private var name = ""
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .rotationEffect(.degrees(isOpen ? 90 : 0))
                .frame(width: 12)
                .foregroundStyle(Color(nsColor: palette.syntax))
            Image(systemName: isOpen ? "folder" : "folder.fill")
                .font(.system(size: 11.5))
                .foregroundStyle(Color(nsColor: palette.quote))
                .frame(width: SidebarMetrics.iconWidth)
            if isRenaming {
                TextField("", text: $name)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color(nsColor: palette.text))
                    .padding(.horizontal, 6)
                    .frame(height: 22)
                    .background {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Color(nsColor: palette.background))
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .strokeBorder(Color(nsColor: palette.text).opacity(0.3))
                    }
                    .padding(.leading, -6)
                    .focused($isFieldFocused)
                    .onSubmit { onRename(name) }
                    .onExitCommand { onRename(nil) }
                    .onChange(of: isFieldFocused) { _, focused in
                        if !focused { onRename(name) }
                    }
                    .onAppear {
                        name = path.name ?? ""
                        isFieldFocused = true
                    }
            } else {
                Text(path.name ?? "")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color(nsColor: palette.text))
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if isHovered && !isRenaming {
                Button(action: onNewNote) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(ChromeButtonStyle(palette: palette, cornerRadius: 5, size: 20))
                .help("New Note in “\(path.name ?? "")”")
                .accessibilityLabel("New Note in \(path.name ?? "")")
            } else if showsCount && count > 0 {
                Text("\(count)")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(Color(nsColor: palette.syntax))
                    .padding(.trailing, 4)
            }
        }
        .padding(.leading, 6 + CGFloat(depth) * SidebarMetrics.indent)
        .padding(.trailing, 6)
        .frame(height: SidebarMetrics.rowHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if isDropTarget || isKeyboardCursor || isPicked {
                RoundedRectangle(cornerRadius: SidebarMetrics.rowCornerRadius, style: .continuous)
                    .fill(Color(nsColor: palette.sidebarSelection))
            } else if isHovered {
                RoundedRectangle(cornerRadius: SidebarMetrics.rowCornerRadius, style: .continuous)
                    .fill(palette.hoverFill)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { if !isRenaming { onToggle() } }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(path.name ?? ""), folder, \(count) notes")
        .accessibilityValue(isOpen ? "Open" : "Closed")
        .accessibilityAction(named: isOpen ? "Close" : "Open", onToggle)
    }
}

/// A heading in a list grouped by date.
struct SectionHeader: View {
    let title: String
    let palette: EditorPalette

    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Color(nsColor: palette.syntax))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 2)
            .accessibilityAddTraits(.isHeader)
    }
}

/// One note: a single line, as tall as a folder's, with the note's icon in
/// the folder icons' column (in the tree), its title, and its date.
struct NoteRow: View {
    let note: Note
    let palette: EditorPalette
    var isSelected = false
    var isHovered = false
    var depth = 0
    /// The note's folder, in flat lists.
    var folderLabel: FolderPath? = nil
    var showsDate = true
    /// In the tree, the title lines up with the folder names above it.
    var isTree = true

    var body: some View {
        HStack(spacing: 5) {
            if isTree {
                // Where a folder's chevron is.
                Color.clear.frame(width: 12, height: 1)
            }
            Image(systemName: note.isLocked ? (note.isSealed ? "lock.fill" : "lock.open.fill") : "doc.text")
                .font(.system(size: note.isLocked ? 10.5 : 11.5))
                .foregroundStyle(Color(nsColor: isSelected ? palette.quote : palette.syntax))
                .frame(width: SidebarMetrics.iconWidth)
                .accessibilityLabel(note.isLocked ? (note.isSealed ? "Locked" : "Unlocked") : "")
            Text(note.displayTitle)
                .font(.system(size: 13, weight: isSelected ? .medium : .regular))
                .foregroundStyle(Color(nsColor: note.title.isEmpty ? palette.syntax : palette.text))
                .lineLimit(1)
            if let folderLabel, !folderLabel.isRoot {
                Text(folderLabel.string)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color(nsColor: palette.syntax))
                    .lineLimit(1)
                    .truncationMode(.head)
                    .layoutPriority(-1)
            }
            Spacer(minLength: 6)
            if showsDate {
                Text(NoteDateText.string(for: note.modified))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(Color(nsColor: palette.syntax))
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .padding(.leading, 6 + CGFloat(depth) * SidebarMetrics.indent)
        .padding(.trailing, 8)
        .frame(height: SidebarMetrics.rowHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: SidebarMetrics.rowCornerRadius, style: .continuous)
                    .fill(Color(nsColor: palette.sidebarSelection))
            } else if isHovered {
                RoundedRectangle(cornerRadius: SidebarMetrics.rowCornerRadius, style: .continuous)
                    .fill(palette.hoverFill)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// A drag in the sidebar, while it lasts.
struct SidebarDragState: Equatable {
    var item: SidebarDragItem
    var rowID: String
    var drop: SidebarDrop?
    /// The insertion line, in the rows' coordinates.
    var lineY: CGFloat?
    var lineDepth = 0
    /// Escape was pressed: nothing happens when it's let go.
    var isCancelled = false
    /// The picked rows dragged along with this one.
    var group: Set<String>?
}

/// Where the sidebar's rows are, for dragging: kept out of SwiftUI's state,
/// so laying out and scrolling don't redraw the list.
final class SidebarGeometry {
    static let verticalPadding: CGFloat = 6
    /// How near the list's edge the pointer makes it scroll.
    static let edge: CGFloat = 28

    var frames: [String: CGRect] = [:]
    var rows: [SidebarRow] = []
    /// The rows' top left in the window, from its top left.
    var rowsOrigin: CGPoint = .zero
    /// The list's frame in the window: where a right-click is the list's.
    var listFrame: CGRect = .zero
    /// The part of the list on screen, in the scroll view's content.
    var visible: CGRect = .zero
    var pointer: CGPoint = .zero
    var proxy: ScrollViewProxy?
    var autoScroll: Task<Void, Never>?
    private var opening: (folder: FolderPath, task: Task<Void, Never>)?

    /// -1 near the top edge, 1 near the bottom, 0 elsewhere.
    var edgeDirection: Int {
        // The rows start below the list's padding.
        let y = pointer.y + Self.verticalPadding - visible.minY
        if y < Self.edge && visible.minY > 0 { return -1 }
        if y > visible.height - Self.edge { return 1 }
        return 0
    }

    /// Scrolls so the row just past the visible part comes into view.
    func scrollOneRow(_ direction: Int) {
        let top = visible.minY - Self.verticalPadding
        let bottom = top + visible.height
        let ordered = rows.filter { frames[$0.id] != nil }
        let target = direction < 0
            ? ordered.last { (frames[$0.id]?.minY ?? 0) < top - 1 }
            : ordered.first { (frames[$0.id]?.maxY ?? 0) > bottom + 1 }
        guard let target else { return }
        withAnimation(.linear(duration: 0.06)) {
            proxy?.scrollTo(target.id, anchor: direction < 0 ? .top : .bottom)
        }
    }

    /// Opens `folder` after a moment of being held over (nil: nothing to open).
    func scheduleOpening(_ folder: FolderPath?, open: @escaping @MainActor (FolderPath) -> Void) {
        guard opening?.folder != folder else { return }
        opening?.task.cancel()
        opening = folder.map { folder in
            (folder, Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(600))
                guard !Task.isCancelled else { return }
                open(folder)
            })
        }
    }

    func stopTimers() {
        autoScroll?.cancel()
        autoScroll = nil
        opening?.task.cancel()
        opening = nil
    }
}
