import Foundation
import Observation
import os

/// The editor as the library sees it. The editor holds the live text of the
/// note it displays; the library pulls that text when it saves.
@MainActor
public protocol NoteEditor: AnyObject {
    var displayedNoteID: Note.ID? { get }
    /// Shows `note`'s text, or an empty, read-only page for nil.
    func display(_ note: Note?)
    func currentText() -> String
    /// Whether the caret sits on the line the title is derived from.
    var isCaretInTitleLine: Bool { get }
    /// The displayed note changed on disk; replace the text, keep the caret.
    func reloadText(_ text: String)
    func focus()
}

/// Notifies the library when something in its folder changes on disk.
@MainActor
public protocol LibraryWatching: AnyObject {
    func start(onChange: @escaping @MainActor () -> Void)
    func stop()
}

public struct LibraryTiming: Sendable {
    /// Quiet time after the last keystroke before saving.
    public var saveDebounce: Duration
    /// Longest a continuously edited note goes unsaved.
    public var maxSaveLatency: Duration
    public var rescanDebounce: Duration
    /// First delay before retrying a failed save; grows linearly.
    public var retryDelay: Duration

    public init(saveDebounce: Duration, maxSaveLatency: Duration, rescanDebounce: Duration, retryDelay: Duration) {
        self.saveDebounce = saveDebounce
        self.maxSaveLatency = maxSaveLatency
        self.rescanDebounce = rescanDebounce
        self.retryDelay = retryDelay
    }

    public static let standard = LibraryTiming(
        saveDebounce: .milliseconds(600),
        maxSaveLatency: .seconds(3),
        rescanDebounce: .milliseconds(150),
        retryDelay: .seconds(2)
    )
}

/// What's needed to undo a Move to Trash.
public struct TrashReceipt: Sendable {
    public let trashedURL: URL
    public let originalName: String
}

/// A problem worth telling the user about.
public struct LibraryError: Identifiable, Sendable {
    public let id = UUID()
    public let title: String
    public let message: String
}

/// The list of notes and everything that keeps it in sync with the folder:
/// drafts, autosave, file naming, trash, and changes made by other apps.
@MainActor
@Observable
public final class Library {
    /// Drafts first, then newest first.
    public private(set) var notes: [Note] = []
    public var selectedID: Note.ID? {
        didSet {
            if oldValue != selectedID { selectionDidChange(from: oldValue) }
        }
    }
    public var searchText = ""
    public var presentedError: LibraryError?
    public private(set) var isLoaded = false

    public var directory: URL { store.directory }
    /// Whether the library is in iCloud Drive.
    public var isInICloud: Bool { store.isUbiquitous }
    /// Whether this is one file opened from elsewhere, in its own window,
    /// rather than the library folder. It holds exactly that file's note:
    /// no drafts, and nothing is renamed, duplicated or trashed.
    public var isSingleFile: Bool { store.singleFile != nil }

    public var selectedNote: Note? { selectedID.flatMap(note(with:)) }

    /// Notes matching the search field.
    public var visibleNotes: [Note] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return notes }
        return notes.filter {
            $0.title.localizedStandardContains(query) || $0.text.localizedStandardContains(query)
        }
    }

    @ObservationIgnored public private(set) weak var editor: (any NoteEditor)?

    @ObservationIgnored private var store: NoteFileStore
    @ObservationIgnored private var watcher: (any LibraryWatching)?
    @ObservationIgnored private let timing: LibraryTiming
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let logger = Logger(subsystem: "com.mlutfullaev.minote", category: "Library")

    @ObservationIgnored private var saveTimers: [Note.ID: Task<Void, Never>] = [:]
    @ObservationIgnored private var firstUnsavedEdit: [Note.ID: ContinuousClock.Instant] = [:]
    @ObservationIgnored private var operations: [Note.ID: (token: UUID, done: Task<Void, Never>)] = [:]
    @ObservationIgnored private var inFlight = 0
    /// Bumped whenever a disk operation starts or ends, so a scan that raced
    /// with our own writes is thrown away instead of misread as outside changes.
    @ObservationIgnored private var mutationCounter = 0
    @ObservationIgnored private var rescanTask: Task<Void, Never>?
    @ObservationIgnored private var rescanPending = false
    @ObservationIgnored private var retryAttempts: [Note.ID: Int] = [:]
    @ObservationIgnored private var suddenTerminationDisabled = false
    @ObservationIgnored private var isTerminating = false

    static let selectionKey = "LastOpenedNote"

    public init(
        store: NoteFileStore,
        watcher: (any LibraryWatching)? = nil,
        timing: LibraryTiming = .standard,
        defaults: UserDefaults = .standard
    ) {
        self.store = store
        self.watcher = watcher
        self.timing = timing
        self.defaults = defaults
    }

    public func note(with id: Note.ID) -> Note? {
        notes.first { $0.id == id }
    }

    // MARK: Loading

    /// Reads the folder, restores the last opened note and starts watching for changes.
    public func load() async {
        guard !isLoaded else { return }
        do {
            try await store.prepare()
        } catch {
            report("Minote can't open its library folder", error)
        }
        await rescanNow()

        if let file = store.singleFile {
            if let note = notes.first {
                selectedID = note.id
            } else {
                presentedError = LibraryError(
                    title: "Couldn't open “\(file.lastPathComponent)”",
                    message: "It may have been moved or deleted, or Minote isn't allowed to read it."
                )
            }
        } else {
            let lastName = defaults.string(forKey: Self.selectionKey)
            if let restored = notes.first(where: { $0.fileURL?.lastPathComponent == lastName }) {
                selectedID = restored.id
            } else if let first = notes.first {
                selectedID = first.id
            } else {
                newNote()
            }
        }
        watcher?.start { [weak self] in self?.scheduleRescan() }
        isLoaded = true
    }

    // MARK: Location

    /// Switches the library to another folder (e.g. into iCloud Drive). Saves
    /// everything first; with `movingNotes`, brings the notes along.
    public func relocate(to newStore: NoteFileStore, watcher newWatcher: (any LibraryWatching)?, movingNotes: Bool) async {
        let oldDirectory = store.directory
        if isLoaded {
            await saveNow()
            selectedID = nil
            await waitUntilIdle()
            watcher?.stop()
        }
        var problem: LibraryError?
        if movingNotes {
            let destination = newStore.directory
            let intoICloud = newStore.isUbiquitous
            do {
                let moved = try await Task.detached(priority: .userInitiated) {
                    try await LibraryLocation.moveNotes(from: oldDirectory, to: destination, intoICloud: intoICloud)
                }.value
                if !moved.leftBehind.isEmpty {
                    let names = moved.leftBehind.prefix(5).map { "“\($0)”" }.joined(separator: ", ")
                    let more = moved.leftBehind.count > 5 ? " and \(moved.leftBehind.count - 5) more" : ""
                    problem = LibraryError(
                        title: "Couldn't move every note",
                        message: "\(names)\(more) stayed where they were. They're safe: switch back to see them, or try again later."
                            + (moved.firstError.map { "\n\n\($0)" } ?? "")
                    )
                }
            } catch {
                problem = LibraryError(title: "Couldn't move the notes", message: error.localizedDescription)
            }
        }
        notes.removeAll()
        store = newStore
        watcher = newWatcher
        isLoaded = false
        isTerminating = false
        await load()
        if let problem {
            logger.error("\(problem.title, privacy: .public): \(problem.message, privacy: .public)")
            presentedError = problem
        }
    }

    // MARK: Editor

    public func attach(_ editor: any NoteEditor) {
        self.editor = editor
        editor.display(selectedNote)
    }

    /// The editor is going away (window closed). Keeps its text and saves.
    public func detach(_ editor: any NoteEditor) {
        guard self.editor === editor else { return }
        if let note = selectedNote { captureEditorText(of: note) }
        self.editor = nil
        Task { await saveNow() }
    }

    /// Called by the editor after every edit, with the first
    /// `NoteNaming.prefixLength` characters (enough for title and excerpt).
    public func editorDidChange(noteID: Note.ID, prefix: some StringProtocol) {
        guard let note = note(with: noteID) else { return }
        note.revision += 1
        note.updateDerived(from: prefix)
        updateSuddenTermination()
        scheduleSave(note)
    }

    // MARK: Commands

    /// Starts a new draft at the top and focuses the editor. Nothing is written
    /// until the draft has text; reuses the current draft if it's still empty.
    public func newNote() {
        guard !isSingleFile else { return }
        searchText = ""
        if let current = selectedNote, current.isDraft, editorText(of: current).isBlank {
            editor?.focus()
            return
        }
        let note = Note(draftCreatedAt: Date())
        notes.insert(note, at: 0)
        selectedID = note.id
        editor?.focus()
    }

    /// Moves the note's file to the Trash (drafts are just dropped).
    /// Returns what's needed to undo, or nil if there's nothing to restore.
    @discardableResult
    public func moveToTrash(_ id: Note.ID) async -> TrashReceipt? {
        guard !isSingleFile, let note = note(with: id) else { return nil }
        captureEditorText(of: note)
        remove(note)
        guard note.fileURL != nil else { return nil }

        return await enqueue(id) { [weak self] () -> TrashReceipt? in
            guard let self, let url = note.fileURL else { return nil }
            // Write pending edits first, so undo brings back the latest text.
            if note.hasUnsavedChanges {
                _ = try? await self.store.write(note.text, to: url, autoNameTag: nil, noteID: note.id, revision: note.revision)
            }
            do {
                guard let trashed = try await self.store.trash(url) else { return nil }
                return TrashReceipt(trashedURL: trashed, originalName: url.lastPathComponent)
            } catch {
                self.report("Couldn't move “\(note.title)” to the Trash", error)
                self.notes.append(note)
                self.sortNotes()
                return nil
            }
        }.value
    }

    /// Puts a trashed note back and selects it.
    public func restore(_ receipt: TrashReceipt) async {
        let url: URL
        do {
            url = try await store.restore(receipt.trashedURL, preferredName: receipt.originalName)
        } catch {
            report("Couldn't put the note back", error)
            return
        }
        await settledRescan()
        if let note = notes.first(where: { $0.fileURL == url }) {
            selectedID = note.id
        }
    }

    /// Gives the note a name of the user's choosing. From then on the file
    /// keeps that name instead of following its first line.
    public func rename(_ id: Note.ID, to newName: String) async {
        guard !isSingleFile, let note = note(with: id) else { return }
        // "Ideas.md" names the file Ideas.md, not Ideas.md.md.
        var name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        if NoteNaming.isNoteFile(URL(fileURLWithPath: name)), (name as NSString).deletingPathExtension.isEmpty == false {
            name = (name as NSString).deletingPathExtension
        }
        let stem = NoteNaming.fileStem(forTitle: name)
        if note.isDraft {
            // Write the draft first so there's a file to name.
            await enqueue(id) { [weak self] in await self?.performSave(note, rename: .always) }.value
        }
        await enqueue(id) { [weak self] in
            guard let self, let url = note.fileURL else { return }
            do {
                let renamed = try await self.store.renameManually(url, to: stem)
                note.fileURL = renamed
                note.autoNameTag = nil
                note.refreshAutoNamed()
                note.updateDerived(from: note.text.prefix(NoteNaming.prefixLength))
                if self.selectedID == note.id { self.persistSelection() }
            } catch {
                self.report("Couldn't rename the note to “\(stem)”", error)
            }
        }.value
    }

    /// Copies the note next to the original and opens the copy.
    public func duplicate(_ id: Note.ID) async {
        guard !isSingleFile, let note = note(with: id) else { return }
        await enqueue(id) { [weak self] in await self?.performSave(note, rename: .always) }.value
        guard let url = note.fileURL else { return }
        do {
            let copy = try await store.duplicate(url)
            await settledRescan()
            if let duplicate = notes.first(where: { $0.fileURL == copy }) {
                selectedID = duplicate.id
            }
        } catch {
            report("Couldn't duplicate the note", error)
        }
    }

    /// Saves every note with pending edits and renames the open note if its
    /// first line changed. Returns once those writes have landed (or failed).
    /// Used when the app is deactivated, the window closes, or the app quits.
    public func saveNow() async {
        if let current = selectedNote { captureEditorText(of: current) }
        var writes: [Task<Void?, Never>] = []
        for note in notes where note.hasUnsavedChanges || saveTimers[note.id] != nil || note.id == selectedID {
            saveTimers.removeValue(forKey: note.id)?.cancel()
            writes.append(enqueue(note.id) { [weak self] in await self?.performSave(note, rename: .always) })
        }
        for write in writes { await write.value }
    }

    /// Stops watching and retrying, then flushes everything. Call before the app
    /// terminates; afterwards `hasUnsavedChanges` tells whether anything failed.
    public func prepareForTermination() async {
        isTerminating = true
        watcher?.stop()
        rescanTask?.cancel()
        await saveNow()
        for note in notes where note.isAutoNamed && !note.isDraft && note.text.isBlank {
            await enqueue(note.id) { [weak self] in await self?.trashIfEmptied(note) }.value
        }
    }

    /// The user chose not to quit after a failed save: resume watching and retrying.
    public func cancelTermination() {
        isTerminating = false
        watcher?.start { [weak self] in self?.scheduleRescan() }
        for note in notes where note.hasUnsavedChanges {
            scheduleSave(note)
        }
    }

    /// True if some note's latest text isn't on disk.
    public var hasUnsavedChanges: Bool {
        notes.contains(where: \.hasUnsavedChanges)
    }

    /// Waits for pending saves, disk operations and rescans to finish. Retries
    /// of failed saves are not waited for.
    public func waitUntilIdle() async {
        while true {
            let timers = saveTimers.filter { retryAttempts[$0.key] == nil }.map(\.value)
            let ops = operations.values.map(\.done)
            let rescan = rescanTask
            if timers.isEmpty && ops.isEmpty && rescan == nil { return }
            for timer in timers { await timer.value }
            for op in ops { await op.value }
            await rescan?.value
            if rescanTask == rescan { rescanTask = nil }
        }
    }

    // MARK: Selection

    private func selectionDidChange(from oldID: Note.ID?) {
        if let oldID, let old = note(with: oldID) {
            captureEditorText(of: old)
            endSession(old)
        }
        editor?.display(selectedNote)
        persistSelection()
    }

    private func persistSelection() {
        // The library's last opened note isn't an opened file's business.
        guard !isSingleFile else { return }
        defaults.set(selectedNote?.fileURL?.lastPathComponent, forKey: Self.selectionKey)
    }

    /// Wraps up a note the user just left: drops it if it's an empty draft,
    /// saves it, renames it to follow its first line, and trashes it quietly
    /// if the user emptied an auto-named file.
    private func endSession(_ note: Note) {
        enqueue(note.id) { [weak self] in
            guard let self, self.contains(note) else { return }
            let isCurrent = self.selectedID == note.id
            if note.isDraft && note.text.isBlank {
                if !isCurrent { self.remove(note) }
                note.savedRevision = note.revision
                self.updateSuddenTermination()
                return
            }
            await self.performSave(note, rename: .always)
            if !isCurrent, self.selectedID != note.id {
                await self.trashIfEmptied(note)
            }
        }
    }

    /// An auto-named note the user emptied has nothing left to keep: it goes to
    /// the Trash quietly instead of lingering as an empty file.
    private func trashIfEmptied(_ note: Note) async {
        guard contains(note), note.isAutoNamed, !note.hasUnsavedChanges, note.text.isBlank,
              let url = note.fileURL else { return }
        do {
            _ = try await store.trash(url)
            remove(note)
        } catch {
            logger.error("Couldn't trash empty note: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Saving

    private enum RenamePolicy {
        /// Rename only if the caret isn't on the title line (user isn't mid-title).
        case whenNotEditingTitle
        case always
    }

    private func scheduleSave(_ note: Note) {
        let now = ContinuousClock.now
        let first = firstUnsavedEdit[note.id] ?? now
        firstUnsavedEdit[note.id] = first
        let deadline = min(now.advanced(by: timing.saveDebounce), first.advanced(by: timing.maxSaveLatency))
        schedule(note, at: deadline)
    }

    private func schedule(_ note: Note, at deadline: ContinuousClock.Instant) {
        let id = note.id
        saveTimers[id]?.cancel()
        saveTimers[id] = Task { [weak self] in
            do {
                try await Task.sleep(until: deadline, clock: .continuous)
            } catch {
                return // Superseded by a newer schedule or an explicit save.
            }
            guard let self else { return }
            self.saveTimers[id] = nil
            self.enqueue(id) { [weak self] in await self?.performSave(note, rename: .whenNotEditingTitle) }
        }
    }

    private func performSave(_ note: Note, rename: RenamePolicy) async {
        guard contains(note) else { return }
        saveTimers.removeValue(forKey: note.id)?.cancel()
        firstUnsavedEdit[note.id] = nil
        captureEditorText(of: note)
        let text = note.text
        let revision = note.revision

        if let url = note.fileURL {
            if note.hasUnsavedChanges {
                do {
                    let tag = note.isAutoNamed ? note.autoNameTag : nil
                    if let stamp = try await store.write(text, to: url, autoNameTag: tag, noteID: note.id, revision: revision) {
                        note.stamp = stamp
                        note.modified = stamp.modified
                    }
                    note.savedRevision = max(note.savedRevision, revision)
                    retryAttempts[note.id] = nil
                } catch {
                    saveFailed(note, error)
                    return
                }
            }
        } else {
            guard !text.isBlank else {
                // Nothing worth a file yet.
                note.savedRevision = max(note.savedRevision, revision)
                updateSuddenTermination()
                return
            }
            do {
                let base = NoteNaming.fileStem(forTitle: NoteNaming.title(of: text.prefix(NoteNaming.prefixLength)))
                let saved = try await store.create(text: text, base: base)
                note.fileURL = saved.url
                note.stamp = saved.stamp
                note.modified = saved.stamp.modified
                note.autoNameTag = note.fileStem
                note.refreshAutoNamed()
                note.savedRevision = max(note.savedRevision, revision)
                retryAttempts[note.id] = nil
                if selectedID == note.id { persistSelection() }
            } catch {
                saveFailed(note, error)
                return
            }
        }

        let editingTitle = editor?.displayedNoteID == note.id && editor?.isCaretInTitleLine == true
        if rename == .always || !editingTitle {
            await renameIfNeeded(note)
        }
        sortNotes()
        updateSuddenTermination()
    }

    private func renameIfNeeded(_ note: Note) async {
        guard note.isAutoNamed, let url = note.fileURL, let stem = note.fileStem else { return }
        let title = NoteNaming.title(of: note.text.prefix(NoteNaming.prefixLength))
        // An emptied note keeps its name; it's trashed when the user leaves it.
        guard !title.isEmpty else { return }
        let desired = NoteNaming.fileStem(forTitle: title)
        if desired == stem { return }
        do {
            let newURL = try await store.rename(url, toBase: desired)
            guard newURL != url else { return }
            note.fileURL = newURL
            note.autoNameTag = note.fileStem
            note.refreshAutoNamed()
            if selectedID == note.id { persistSelection() }
        } catch {
            logger.error("Rename failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func saveFailed(_ note: Note, _ error: any Error) {
        let attempts = (retryAttempts[note.id] ?? 0) + 1
        retryAttempts[note.id] = attempts
        logger.error("Save failed (attempt \(attempts)): \(error.localizedDescription, privacy: .public)")
        if attempts == 1 && !isTerminating {
            let name = note.title.isEmpty ? "New Note" : note.title
            presentedError = LibraryError(
                title: "Couldn't save “\(name)”",
                message: "\(error.localizedDescription)\n\nYour text is still in the window. Minote will keep trying to save it."
            )
        }
        if !isTerminating {
            schedule(note, at: ContinuousClock.now.advanced(by: timing.retryDelay * min(attempts, 15)))
        }
        updateSuddenTermination()
    }

    // MARK: Disk operations

    /// Runs `operation` after every earlier operation on the same note, so a
    /// note is never created twice or renamed while it's being written.
    @discardableResult
    private func enqueue<T: Sendable>(_ id: Note.ID, _ operation: @escaping @MainActor () async -> T) -> Task<T, Never> {
        let previous = operations[id]?.done
        let token = UUID()
        beginDiskWork()
        let task = Task { @MainActor [weak self] () -> T in
            await previous?.value
            let result = await operation()
            self?.operationFinished(id, token: token)
            return result
        }
        operations[id] = (token, Task { _ = await task.value })
        return task
    }

    private func operationFinished(_ id: Note.ID, token: UUID) {
        if operations[id]?.token == token { operations[id] = nil }
        endDiskWork()
    }

    private func beginDiskWork() {
        inFlight += 1
        mutationCounter += 1
    }

    private func endDiskWork() {
        inFlight -= 1
        mutationCounter += 1
        updateSuddenTermination()
        if inFlight == 0 && rescanPending {
            rescanPending = false
            scheduleRescan()
        }
    }

    // MARK: Outside changes

    /// Debounced rescan, triggered by the folder watcher.
    public func scheduleRescan() {
        rescanTask?.cancel()
        rescanTask = Task { [weak self, timing] in
            do {
                try await Task.sleep(for: timing.rescanDebounce)
            } catch {
                return
            }
            await self?.rescanNow()
        }
    }

    /// Re-reads the folder and merges what changed. Our own writes are
    /// recognized and ignored; a scan that overlapped them is retried.
    public func rescanNow() async {
        guard inFlight == 0 else {
            rescanPending = true
            return
        }
        let generation = mutationCounter
        let files: [ScannedFile]
        do {
            files = try await store.scan(known: knownStamps())
        } catch {
            logger.error("Scan failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        guard inFlight == 0, generation == mutationCounter else {
            rescanPending = true
            if inFlight == 0 { scheduleRescan() }
            return
        }
        reconcile(files)
    }

    /// Waits for our own disk operations to finish, then rescans; retries if
    /// another operation slipped in while scanning.
    private func settledRescan() async {
        for _ in 0..<5 {
            while let pending = operations.values.first?.done { await pending.value }
            let generation = mutationCounter
            guard let files = try? await store.scan(known: knownStamps()) else { return }
            if inFlight == 0 && generation == mutationCounter {
                reconcile(files)
                return
            }
        }
        scheduleRescan()
    }

    private func knownStamps() -> [URL: FileStamp] {
        var stamps: [URL: FileStamp] = [:]
        for note in notes {
            if let url = note.fileURL, let stamp = note.stamp { stamps[url] = stamp }
        }
        return stamps
    }

    private func reconcile(_ files: [ScannedFile]) {
        var byURL: [URL: Note] = [:]
        for note in notes {
            if let url = note.fileURL { byURL[url] = note }
        }

        var seen = Set<URL>()
        var added: [Note] = []
        for file in files {
            seen.insert(file.url)
            guard let note = byURL[file.url] else {
                if let text = file.text { added.append(Note(file: file, text: text)) }
                continue
            }
            if note.autoNameTag != file.autoNameTag {
                note.autoNameTag = file.autoNameTag
                note.refreshAutoNamed()
            }
            guard let text = file.text else { continue }
            note.stamp = file.stamp
            if text == note.text {
                if note.modified != file.stamp.modified { note.modified = file.stamp.modified }
                continue
            }
            if note.hasUnsavedChanges || saveTimers[note.id] != nil {
                // Both sides changed. The local edits win and will overwrite the file.
                logger.notice("\(file.url.lastPathComponent, privacy: .public) changed on disk while it had unsaved edits; keeping the edits")
                continue
            }
            note.text = text
            note.modified = file.stamp.modified
            note.updateDerived(from: text.prefix(NoteNaming.prefixLength))
            if let editor, editor.displayedNoteID == note.id {
                editor.reloadText(text)
            }
        }

        for note in notes {
            guard let url = note.fileURL, !seen.contains(url) else { continue }
            if isSingleFile {
                // An opened file's window keeps its text; edits are written
                // back where the file was, never into a library folder.
                note.stamp = nil
                if note.hasUnsavedChanges { scheduleSave(note) }
                continue
            }
            if note.hasUnsavedChanges {
                // Deleted elsewhere while the user was typing: keep the text and
                // write it again as a new file rather than lose it.
                note.fileURL = nil
                note.stamp = nil
                note.autoNameTag = nil
                note.refreshAutoNamed()
                scheduleSave(note)
            } else {
                remove(note)
            }
        }

        notes.append(contentsOf: added)
        sortNotes()
        // An opened file that couldn't be read at first shows up once it can.
        if isSingleFile, isLoaded, selectedID == nil, let first = notes.first {
            selectedID = first.id
        }
    }

    // MARK: Helpers

    private func contains(_ note: Note) -> Bool {
        notes.contains { $0 === note }
    }

    /// Removes a note from the list. If it was selected, selects its neighbor,
    /// or starts a new draft when the library is empty.
    private func remove(_ note: Note) {
        let visible = visibleNotes
        var neighbor: Note?
        if let index = visible.firstIndex(where: { $0 === note }) {
            neighbor = visible.indices.contains(index + 1) ? visible[index + 1] : (index > 0 ? visible[index - 1] : nil)
        }
        notes.removeAll { $0 === note }
        saveTimers.removeValue(forKey: note.id)?.cancel()
        firstUnsavedEdit[note.id] = nil
        retryAttempts[note.id] = nil
        if selectedID == note.id {
            if let neighbor {
                selectedID = neighbor.id
            } else if let first = notes.first {
                selectedID = first.id
            } else {
                newNote()
            }
        }
        updateSuddenTermination()
    }

    private func sortNotes() {
        let sorted = notes.sorted { a, b in
            if a.isDraft != b.isDraft { return a.isDraft }
            if a.modified != b.modified { return a.modified > b.modified }
            let nameA = a.fileURL?.lastPathComponent ?? ""
            let nameB = b.fileURL?.lastPathComponent ?? ""
            return nameA.localizedStandardCompare(nameB) == .orderedAscending
        }
        if !sorted.elementsEqual(notes, by: ===) { notes = sorted }
    }

    /// Copies the editor's live text into the note, if it's the one displayed and has edits.
    private func captureEditorText(of note: Note) {
        guard note.hasUnsavedChanges, let editor, editor.displayedNoteID == note.id else { return }
        note.text = editor.currentText()
    }

    private func editorText(of note: Note) -> String {
        if let editor, editor.displayedNoteID == note.id { return editor.currentText() }
        return note.text
    }

    private func updateSuddenTermination() {
        let needsProtection = inFlight > 0 || notes.contains(where: \.hasUnsavedChanges)
        guard needsProtection != suddenTerminationDisabled else { return }
        suddenTerminationDisabled = needsProtection
        #if os(macOS)
        if needsProtection {
            ProcessInfo.processInfo.disableSuddenTermination()
        } else {
            ProcessInfo.processInfo.enableSuddenTermination()
        }
        #endif
    }

    private func report(_ title: String, _ error: any Error) {
        logger.error("\(title, privacy: .public): \(error.localizedDescription, privacy: .public)")
        presentedError = LibraryError(title: title, message: error.localizedDescription)
    }
}
