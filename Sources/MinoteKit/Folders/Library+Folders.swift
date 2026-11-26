import Foundation

/// What changed in the library's organisation, for the app to follow.
public enum OrganisationChange: Sendable, Equatable {
    /// A folder was renamed or moved: everything under `from` is under `to` now.
    case folderMoved(from: FolderPath, to: FolderPath)
    /// A folder went to the Trash.
    case folderRemoved(FolderPath)
    /// A note went to another folder.
    case noteMoved
}

/// What's needed to undo moving a folder to the Trash.
public struct FolderTrashReceipt: Sendable {
    public let trashedURL: URL
    public let folder: FolderPath
    /// Where it stood in its parent's manual order.
    let orderIndex: Int?
}

/// Folders: making, renaming, moving and trashing them, moving notes between
/// them, and each folder's order. Every command waits for, and holds, the
/// notes it touches (their pending edits are written first), and runs after
/// every earlier folder command.
extension Library {
    /// Folder commands queue behind each other under this ID.
    static let organiseQueueID = UUID()

    /// How the folders' children are ordered now.
    public var ordering: FolderOrdering {
        FolderOrdering(notes: notes, folders: folders, settings: folderSettings)
    }

    /// The order the folder uses (its own, or inherited).
    public func sortOrder(of folder: FolderPath) -> SortOrder {
        ordering.sortOrder(of: folder)
    }

    /// Where a folder is on disk (for Show in Finder).
    public func url(of folder: FolderPath) -> URL {
        store.folderURL(folder)
    }

    /// Every note in the folder and below it.
    public func notes(under folder: FolderPath) -> [Note] {
        notes.filter { folder.contains($0.folder) }
    }

    /// How many notes, and other files, trashing the folder takes along.
    public func contentsCount(of folder: FolderPath) async -> (notes: Int, others: Int) {
        await store.contentsCount(of: folder)
    }

    // MARK: Folders

    /// Makes a new folder in `parent` ("New Folder", "New Folder 2"…).
    @discardableResult
    public func newFolder(in parent: FolderPath = .root, named name: String = NoteNaming.newFolder) async -> FolderPath? {
        guard !isSingleFile else { return nil }
        return await organise(holding: []) { [self] in
            do {
                let folder = try await store.createFolder(named: name, in: parent)
                folders = (folders + [folder]).sorted()
                return folder
            } catch {
                report("Couldn't make the folder", error)
                return nil
            }
        }
    }

    /// Renames a folder. Open notes inside keep their tabs, carets and edits.
    @discardableResult
    public func renameFolder(_ folder: FolderPath, to name: String) async -> FolderPath? {
        guard !isSingleFile, !folder.isRoot else { return nil }
        let inside = notes(under: folder)
        return await organise(holding: inside) { [self] in
            let held = await settle(folder, holding: inside).notes
            do {
                let renamed = try await store.renameFolder(folder, to: name)
                guard renamed != folder else { return folder }
                if let parent = folder.parent, let old = folder.name, let new = renamed.name {
                    renameOrderKey(in: parent, from: FolderSettings.key(forFolder: old), to: FolderSettings.key(forFolder: new), isFolder: true)
                }
                rebase(folder, onto: renamed, also: held)
                return renamed
            } catch {
                report("Couldn't rename “\(folder.name ?? "")”", error)
                return nil
            }
        }
    }

    /// Moves a folder, with everything in it, into `parent`; at `index` among
    /// its children when that folder is ordered by hand. Within its own
    /// folder, it's a reorder.
    @discardableResult
    public func moveFolder(_ folder: FolderPath, into parent: FolderPath, at index: Int? = nil,
                           undoManager: UndoManager? = nil) async -> FolderPath? {
        guard !isSingleFile, !folder.isRoot, let oldParent = folder.parent else { return nil }
        if oldParent == parent {
            if let index { await place(.folder(folder), in: parent, at: index, undoManager: undoManager) }
            return folder
        }
        let before = settingsSnapshot([oldParent, parent])
        let inside = notes(under: folder)
        let moved: FolderPath? = await organise(holding: inside) { [self] in
            let held = await settle(folder, holding: inside).notes
            do {
                let moved = try await store.moveFolder(folder, into: parent)
                removeOrderKey(folder.name.map(FolderSettings.key(forFolder:)), from: oldParent)
                rebase(folder, onto: moved, also: held)
                insertOrderKey(moved.name.map(FolderSettings.key(forFolder:)), into: parent, at: index)
                return moved
            } catch {
                report("Couldn't move “\(folder.name ?? "")”", error)
                return nil
            }
        }
        if let moved, let undoManager {
            undoManager.registerUndo(withTarget: self) { library in
                Task { @MainActor in
                    await library.moveFolder(moved, into: oldParent)
                    library.restoreSettings(before)
                }
            }
            undoManager.setActionName("Move Folder")
        }
        return moved
    }

    /// Moves a folder to the Trash with everything in it. Its notes leave the
    /// list (their tabs close).
    @discardableResult
    public func trashFolder(_ folder: FolderPath, undoManager: UndoManager? = nil) async -> FolderTrashReceipt? {
        guard !isSingleFile, !folder.isRoot, let parent = folder.parent else { return nil }
        let inside = notes(under: folder)
        let orderIndex = folderSettings[parent]?.order.firstIndex { FolderOrdering.normalized($0) == FolderOrdering.normalized(FolderSettings.key(forFolder: folder.name ?? "")) }
        let receipt: FolderTrashReceipt? = await organise(holding: inside) { [self] in
            // Written first, so undoing brings back the latest text. Edits
            // that can't be written (a failing disk, a note locked meanwhile)
            // keep the folder where it is: they exist nowhere else.
            guard await settle(folder, holding: inside).allSaved else {
                presentedError = LibraryError(
                    title: "“\(folder.name ?? "")” stays where it is",
                    message: "Some of its notes have changes Minote couldn't save yet. They're still in their windows; try again once they're saved."
                )
                return nil
            }
            do {
                let trashed = try await store.trashFolder(folder)
                // Gone from the folder either way; without a place in the Trash there's nothing to undo.
                for note in notes(under: folder) { remove(note) }
                folders.removeAll { folder.contains($0) }
                for key in folderSettings.keys where folder.contains(key) { folderSettings[key] = nil }
                removeOrderKey(folder.name.map(FolderSettings.key(forFolder:)), from: parent)
                organisationHandler?(.folderRemoved(folder))
                return trashed.map { FolderTrashReceipt(trashedURL: $0, folder: folder, orderIndex: orderIndex) }
            } catch {
                report("Couldn't move “\(folder.name ?? "")” to the Trash", error)
                return nil
            }
        }
        if let receipt, let undoManager {
            undoManager.registerUndo(withTarget: self) { library in
                Task { @MainActor in await library.restoreFolder(receipt) }
            }
            undoManager.setActionName("Move to Trash")
        }
        return receipt
    }

    /// Puts a trashed folder back where it was.
    public func restoreFolder(_ receipt: FolderTrashReceipt) async {
        guard let parent = receipt.folder.parent, let name = receipt.folder.name else { return }
        let restored: FolderPath? = await organise(holding: []) { [self] in
            do {
                return try await store.restoreFolder(receipt.trashedURL, named: name, in: parent)
            } catch {
                report("Couldn't put the folder back", error)
                return nil
            }
        }
        guard let restored else { return }
        await settledRescan()
        if let index = receipt.orderIndex, let key = restored.name.map(FolderSettings.key(forFolder:)) {
            insertOrderKey(key, into: parent, at: index, asStored: true)
        }
    }

    // MARK: Notes

    /// Moves a note into another folder; at `index` among its children when
    /// that folder is ordered by hand (otherwise where its sort puts it).
    /// Within its own folder, it's a reorder. Its tab, caret and edits stay.
    @discardableResult
    public func moveNote(_ id: Note.ID, to folder: FolderPath, at index: Int? = nil, undoManager: UndoManager? = nil) async -> Bool {
        guard !isSingleFile, let note = note(with: id) else { return false }
        let oldFolder = note.folder
        if oldFolder == folder {
            if let index { await place(.note(note), in: folder, at: index, undoManager: undoManager) }
            return index != nil
        }
        let before = settingsSnapshot([oldFolder, folder])
        let moved: Bool = await organise(holding: [note]) { [self] in
            guard contains(note) else { return false }
            if note.isDraft && note.fileURL == nil {
                note.folder = folder
                return true
            }
            await savePending([note])
            guard let url = note.fileURL else {
                note.folder = folder
                return true
            }
            do {
                let oldStem = note.fileStem
                let newURL = try await store.moveNote(url, to: folder)
                removeOrderKey(oldStem.map(FolderSettings.key(forNote:)), from: oldFolder)
                note.fileURL = newURL
                note.folder = folder
                if note.isAutoNamed, oldStem != note.fileStem { note.autoNameTag = note.fileStem }
                note.refreshAutoNamed()
                note.updateDerived()
                insertOrderKey(note.fileStem.map(FolderSettings.key(forNote:)), into: folder, at: index)
                if selectedID == note.id { persistSelection() }
                organisationHandler?(.noteMoved)
                return true
            } catch {
                report("Couldn't move “\(note.displayTitle)”", error)
                return false
            }
        }
        if moved, let undoManager {
            undoManager.registerUndo(withTarget: self) { library in
                Task { @MainActor in
                    await library.moveNote(id, to: oldFolder)
                    library.restoreSettings(before)
                }
            }
            undoManager.setActionName("Move Note")
        }
        return moved
    }

    // MARK: Order

    /// Puts a folder's child at `index` among the folder's children (counted
    /// before it leaves its place). A folder not ordered by hand becomes
    /// Manual, starting from the order it was showing.
    public func place(_ child: FolderChild, in folder: FolderPath, at index: Int, undoManager: UndoManager? = nil) async {
        let before = settingsSnapshot([folder])
        var children = ordering.children(of: folder)
        guard let current = children.firstIndex(of: child) else { return }
        children.remove(at: current)
        let target = min(max(index > current ? index - 1 : index, 0), children.count)
        children.insert(child, at: target)
        var settings = folderSettings[folder] ?? FolderSettings()
        settings.order = children.compactMap(\.orderKey)
        if sortOrder(of: folder).sort != .manual {
            settings.sort = .manual
            settings.reversed = nil
        }
        writeSettings(settings, for: folder)
        if let undoManager {
            undoManager.registerUndo(withTarget: self) { library in
                library.restoreSettings(before)
            }
            undoManager.setActionName("Reorder")
        }
        await waitForSettings()
    }

    /// Gives a folder its own sort, or (nil) lets it follow the folder above.
    /// The manual order is kept either way.
    public func setSort(_ order: SortOrder?, for folder: FolderPath) {
        var settings = folderSettings[folder] ?? FolderSettings()
        settings.sort = order?.sort
        settings.reversed = order?.reversed == true ? true : nil
        writeSettings(settings, for: folder)
    }

    // MARK: Helpers

    /// Runs a folder command after earlier ones, holding `notes` meanwhile.
    func organise<T: Sendable>(holding notes: [Note], _ body: @escaping @MainActor () async -> T) async -> T {
        await enqueue(holding: [Self.organiseQueueID] + notes.map(\.id), body).value
    }

    /// Writes the pending edits of these notes now (inside a command that holds them).
    /// Returns whether every one of them is on disk.
    @discardableResult
    private func savePending(_ notes: [Note]) async -> Bool {
        for note in notes where contains(note) {
            captureEditorText(of: note)
            if note.hasUnsavedChanges || saveTimers[note.id] != nil {
                await performSave(note, rename: .whenNotEditingTitle)
            }
        }
        return notes.allSatisfy { !contains($0) || !$0.hasUnsavedChanges }
    }

    /// Inside a command on `folder` that holds `held`: notes that came into
    /// the folder after the command was queued (a draft started meanwhile, a
    /// note moved in) have their disk work finished too, then everyone's
    /// pending edits are written. Returns every note concerned.
    private func settle(_ folder: FolderPath, holding held: [Note]) async -> (notes: [Note], allSaved: Bool) {
        let late = notes(under: folder).filter { note in !held.contains { $0 === note } }
        for note in late {
            if let pending = operations[note.id]?.done { await pending.value }
        }
        let all = held + late
        return (all, await savePending(all))
    }

    /// Everything under `old` is under `new` now: notes (their URLs too),
    /// folders and their settings.
    private func rebase(_ old: FolderPath, onto new: FolderPath, also held: [Note] = []) {
        // Held notes too: one trashed meanwhile still has its trashing queued
        // behind this command, and must find its file where it is now.
        var concerned = notes
        for note in held where !concerned.contains(where: { $0 === note }) { concerned.append(note) }
        for note in concerned where old.contains(note.folder) {
            let folder = old.rebasing(note.folder, onto: new)
            note.folder = folder
            if let url = note.fileURL {
                note.fileURL = store.fileURL(named: url.lastPathComponent, in: store.folderURL(folder))
            }
        }
        folders = folders.map { old.rebasing($0, onto: new) }.sorted()
        folderSettings = Dictionary(folderSettings.map { (old.rebasing($0.key, onto: new), $0.value) }, uniquingKeysWith: { a, _ in a })
        unreadableSettings = Set(unreadableSettings.map { old.rebasing($0, onto: new) })
        // Order changes queued during the command were addressed to the old
        // place: write what's known now where the folders are now.
        for (folder, settings) in folderSettings where new.contains(folder) && !unreadableSettings.contains(folder) {
            writeSettings(settings, for: folder)
        }
        if let selected = selectedNote, new.contains(selected.folder) { persistSelection() }
        organisationHandler?(.folderMoved(from: old, to: new))
    }

    /// A child of `folder` changed its name: its place in the manual order stays.
    func renameOrderKey(in folder: FolderPath, from old: String?, to new: String?, isFolder: Bool = false) {
        guard let old, let new, old != new, !unreadableSettings.contains(folder), var settings = folderSettings[folder] else { return }
        let oldKey = isFolder ? old : FolderSettings.key(forNote: old)
        let newKey = isFolder ? new : FolderSettings.key(forNote: new)
        guard let index = settings.order.firstIndex(where: { FolderOrdering.normalized($0) == FolderOrdering.normalized(oldKey) }) else { return }
        settings.order[index] = newKey
        writeSettings(settings, for: folder)
    }

    private func removeOrderKey(_ key: String?, from folder: FolderPath) {
        guard let key, !unreadableSettings.contains(folder), var settings = folderSettings[folder] else { return }
        let before = settings.order.count
        settings.order.removeAll { FolderOrdering.normalized($0) == FolderOrdering.normalized(key) }
        if settings.order.count != before { writeSettings(settings, for: folder) }
    }

    /// A newcomer to a folder ordered by hand goes at `index` among its
    /// children (at the top without one); `asStored` takes `index` as a place
    /// in the stored order instead.
    /// A folder whose settings file can't be read (newer, damaged, or not
    /// downloaded yet) is left alone: its order isn't known to add to.
    private func insertOrderKey(_ key: String?, into folder: FolderPath, at index: Int?, asStored: Bool = false) {
        guard let key, !unreadableSettings.contains(folder), sortOrder(of: folder).sort == .manual else { return }
        var settings = folderSettings[folder] ?? FolderSettings()
        var order: [String]
        if asStored {
            order = settings.order
        } else {
            // The order as shown, so a place on screen is a place in the order.
            order = ordering.children(of: folder).compactMap(\.orderKey)
        }
        order.removeAll { FolderOrdering.normalized($0) == FolderOrdering.normalized(key) }
        let draftCount = asStored ? 0 : ordering.children(of: folder).prefix { $0.orderKey == nil }.count
        let position = min(max((index ?? 0) - draftCount, 0), order.count)
        order.insert(key, at: position)
        settings.order = order
        writeSettings(settings, for: folder)
    }

    private func settingsSnapshot(_ folders: [FolderPath]) -> [FolderPath: FolderSettings?] {
        Dictionary(folders.map { ($0, folderSettings[$0]) }, uniquingKeysWith: { a, _ in a })
    }

    private func restoreSettings(_ snapshot: [FolderPath: FolderSettings?]) {
        for (folder, settings) in snapshot { writeSettings(settings, for: folder) }
    }

    /// Takes the settings now and writes them in the background, after
    /// earlier folder commands.
    func writeSettings(_ settings: FolderSettings?, for folder: FolderPath) {
        let kept = settings.flatMap { $0.isEmpty ? nil : $0 }
        if folderSettings[folder] != kept { folderSettings[folder] = kept }
        unreadableSettings.remove(folder)
        enqueue(holding: [Self.organiseQueueID]) { [self] in
            do {
                try await store.writeFolderSettings(kept, for: folder)
            } catch {
                logger.error("Couldn't write a folder's settings: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func waitForSettings() async {
        await enqueue(holding: [Self.organiseQueueID]) {}.value
    }
}

// MARK: Several at once

/// A note or a folder of the library, as a selection holds it.
public enum LibraryEntry: Hashable, Sendable {
    case note(Note.ID)
    case folder(FolderPath)
}

extension Library {
    /// The items without those inside a folder that's also in the list: a
    /// folder moved or trashed takes them along.
    public func outermost(_ items: [LibraryEntry]) -> [LibraryEntry] {
        let folders = items.compactMap { if case .folder(let path) = $0 { path } else { nil } }
        var seen = Set<LibraryEntry>()
        return items.filter { item in
            guard seen.insert(item).inserted else { return false }
            switch item {
            case .note(let id):
                guard let note = note(with: id) else { return false }
                return !folders.contains { $0.contains(note.folder) }
            case .folder(let path):
                return !folders.contains { $0 != path && $0.isAncestor(of: path) }
            }
        }
    }

    /// Moves notes and folders into `folder` (each where its sort puts it, at
    /// the top in Manual). Folders that can't go there (into themselves, onto
    /// a name that's taken) stay, with the reason reported once. One undo
    /// puts everything that moved back.
    @discardableResult
    public func moveItems(_ items: [LibraryEntry], to folder: FolderPath, undoManager: UndoManager? = nil) async -> Int {
        var undo: [(item: LibraryEntry, back: FolderPath)] = []
        var intoThemselves: [String] = []
        for item in outermost(items) {
            switch item {
            case .note(let id):
                guard let note = note(with: id), note.folder != folder else { continue }
                let old = note.folder
                if await moveNote(id, to: folder) { undo.append((.note(id), old)) }
            case .folder(let path):
                guard let parent = path.parent, parent != folder else { continue }
                guard !path.contains(folder) else {
                    intoThemselves.append("“\(path.name ?? "")”")
                    continue
                }
                if let moved = await moveFolder(path, into: folder) { undo.append((.folder(moved), parent)) }
            }
        }
        if !intoThemselves.isEmpty {
            presentedError = LibraryError(
                title: intoThemselves.count == 1 ? "\(intoThemselves[0]) stayed where it was" : "\(intoThemselves.count) folders stayed where they were",
                message: "A folder can't go inside itself: \(intoThemselves.joined(separator: ", ")). Everything else moved."
            )
        }
        if !undo.isEmpty, let undoManager {
            undoManager.registerUndo(withTarget: self) { library in
                Task { @MainActor in
                    for (item, back) in undo.reversed() {
                        switch item {
                        case .note(let id): await library.moveNote(id, to: back)
                        case .folder(let path): await library.moveFolder(path, into: back)
                        }
                    }
                }
            }
            undoManager.setActionName(undo.count == 1 ? "Move" : "Move \(undo.count) Items")
        }
        return undo.count
    }

    /// Moves notes and folders to the Trash. One undo brings them all back.
    @discardableResult
    public func trashItems(_ items: [LibraryEntry], undoManager: UndoManager? = nil) async -> Int {
        var notes: [TrashReceipt] = []
        var folders: [FolderTrashReceipt] = []
        var count = 0
        for item in outermost(items) {
            switch item {
            case .note(let id):
                guard let note = note(with: id) else { continue }
                let receipt = await moveToTrash(id)
                // A draft has nothing to put back; a note still listed didn't go.
                guard !contains(note) else { continue }
                count += 1
                if let receipt { notes.append(receipt) }
            case .folder(let path):
                if let receipt = await trashFolder(path) {
                    folders.append(receipt)
                    count += 1
                }
            }
        }
        if !notes.isEmpty || !folders.isEmpty, let undoManager {
            undoManager.registerUndo(withTarget: self) { library in
                Task { @MainActor in
                    for receipt in folders.reversed() { await library.restoreFolder(receipt) }
                    for receipt in notes.reversed() { await library.restore(receipt) }
                }
            }
            undoManager.setActionName(count == 1 ? "Move to Trash" : "Move \(count) Items to Trash")
        }
        return count
    }
}
