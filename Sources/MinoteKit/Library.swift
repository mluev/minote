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
    /// These notes were just locked: drop anything kept of their text, such
    /// as undo history, even for notes this editor isn't showing now.
    func forgetText(of ids: Set<Note.ID>)
}

extension NoteEditor {
    public func forgetText(of ids: Set<Note.ID>) {}
}

/// Notifies the library when something in its folder changes on disk.
@MainActor
public protocol LibraryWatching: AnyObject {
    func start(onChange: @escaping @MainActor () -> Void)
    func stop()
    /// The library's folders now (the library folder first): a watcher that
    /// can't see into folders below the one it watches follows each of them.
    func watch(folders: [URL])
}

extension LibraryWatching {
    public func watch(folders: [URL]) {}
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
    /// The library folder it was in; it goes back there.
    public let folder: FolderPath
}

/// A problem worth telling the user about.
public struct LibraryError: Identifiable, Sendable {
    public let id = UUID()
    public let title: String
    public let message: String

    public init(title: String, message: String) {
        self.title = title
        self.message = message
    }
}

/// The list of notes and everything that keeps it in sync with the folder:
/// drafts, autosave, file naming, trash, and changes made by other apps.
@MainActor
@Observable
public final class Library {
    /// Drafts first, then newest first.
    public private(set) var notes: [Note] = []
    /// Every folder under the library folder, empty ones too (not the
    /// library folder itself).
    public internal(set) var folders: [FolderPath] = []
    /// What each folder remembers about its order (the library folder's
    /// under `.root`), from its `.minote-folder` file.
    public internal(set) var folderSettings: [FolderPath: FolderSettings] = [:]
    /// Folders whose settings file this build can't read: left alone until
    /// the writer orders that folder again.
    @ObservationIgnored var unreadableSettings: Set<FolderPath> = []
    /// Told when folders are renamed, moved or removed, or notes moved, so the
    /// app can follow (tabs kept by path, folders kept closed).
    @ObservationIgnored public var organisationHandler: ((OrganisationChange) -> Void)?
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

    /// Notes matching the search field. A sealed note matches by title only.
    public var visibleNotes: [Note] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return notes }
        return notes.filter {
            $0.title.localizedStandardContains(query) || $0.text?.localizedStandardContains(query) == true
        }
    }

    // MARK: Lock state

    /// The library's password record and lock mode, or nil while no password is set.
    public private(set) var vault: VaultRecord?
    /// Whether locked notes are open: their key is in memory.
    public private(set) var isUnlocked = false
    public var hasPassword: Bool { vault != nil }
    public var lockScope: LockScope { vault?.scope ?? .notes }
    /// The whole library is locked and not unlocked: the app shows its lock screen.
    public var isLibraryLocked: Bool { lockScope == .library && !isUnlocked }
    /// The key while unlocked, for the app to keep with Touch ID.
    public var unlockedKey: LibraryKey? { sealer?.current }
    /// Whether any note is locked.
    public var hasLockedNotes: Bool { notes.contains(where: \.isLocked) }
    /// A first password can be set: the library is read, and its folder is
    /// known to have none. Not while a vault is still downloading or can't be
    /// read: a new one would replace it.
    public var canSetPassword: Bool {
        isLoaded && !isSingleFile && vault == nil && vaultIsMissing && !notes.contains { $0.lockRecord != nil }
    }

    /// The editor in front. The Mac has one editor per tab and several can show
    /// this library's notes at once; `selectedID` is the note in this one.
    @ObservationIgnored public private(set) weak var editor: (any NoteEditor)?
    /// Opens a note on the user's behalf (a link, Duplicate, undoing Move to
    /// Trash, New Note). The Mac routes it to a tab; without one, the note is
    /// selected.
    @ObservationIgnored public var openHandler: ((Note.ID) -> Void)?
    /// Asked for each editor showing a note that was removed (trashed, or
    /// deleted elsewhere). Returns true if that editor goes away (its tab
    /// closes); otherwise it shows a neighbor, or a new draft.
    @ObservationIgnored public var shownNoteRemovedHandler: ((any NoteEditor) -> Bool)?

    /// Every attached editor, least recently in front first.
    @ObservationIgnored private var editors: [WeakEditor] = []
    /// Set while the library moves `selectedID` itself (the front editor
    /// changed), so the change isn't taken for a request to show a note.
    @ObservationIgnored private var isSyncingSelection = false

    @ObservationIgnored private(set) var store: NoteFileStore
    @ObservationIgnored private var watcher: (any LibraryWatching)?
    @ObservationIgnored private let timing: LibraryTiming
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored let logger = Logger(subsystem: "com.mlutfullaev.minote", category: "Library")

    @ObservationIgnored private(set) var saveTimers: [Note.ID: Task<Void, Never>] = [:]
    @ObservationIgnored private var firstUnsavedEdit: [Note.ID: ContinuousClock.Instant] = [:]
    @ObservationIgnored private(set) var operations: [Note.ID: (token: UUID, done: Task<Void, Never>)] = [:]
    @ObservationIgnored private var inFlight = 0
    /// Bumped whenever a disk operation starts or ends, so a scan that raced
    /// with our own writes is thrown away instead of misread as outside changes.
    @ObservationIgnored private var mutationCounter = 0
    @ObservationIgnored private var rescanTask: Task<Void, Never>?
    @ObservationIgnored private var rescanPending = false
    @ObservationIgnored private var retryAttempts: [Note.ID: Int] = [:]
    @ObservationIgnored private var suddenTerminationDisabled = false
    @ObservationIgnored private var isTerminating = false

    /// Seals and opens locked notes; only there while unlocked.
    @ObservationIgnored private var sealer: NoteSealer?
    /// Bumped on every lock and unlock. Work started before it changed (opening
    /// a note, a scan) is thrown away rather than applied to the wrong state.
    @ObservationIgnored private var lockEpoch = 0
    /// Whether `vault` was read from the folder (or written there), rather than
    /// taken from this device's copy while the folder has none.
    @ObservationIgnored private var vaultFromFile = false
    /// The vault exactly as the folder has it. `vault` can lock more while
    /// the folder's asks to lock less than this device knew (see `applyVault`).
    @ObservationIgnored private var folderVault: VaultRecord?
    /// The last read found no vault at all (not one still downloading, nor an
    /// unreadable one): only then may a first password be set.
    private var vaultIsMissing = false
    /// Locked notes with edits that can't be saved until the library is unlocked.
    @ObservationIgnored private var awaitingUnlock: Set<Note.ID> = []
    /// Sealed notes the key couldn't open (damaged): not tried again until the next unlock.
    @ObservationIgnored private var unopenable: Set<Note.ID> = []
    /// Rebuilding a missing vault, or writing it signed again (see `writeVaultLater`).
    @ObservationIgnored private var vaultWrite: Task<Void, Never>?
    @ObservationIgnored private var vaultWriteToken: UUID?
    @ObservationIgnored private let passwordRounds: Int
    @ObservationIgnored private let mirror: VaultMirror

    static let selectionKey = "LastOpenedNote"

    public init(
        store: NoteFileStore,
        watcher: (any LibraryWatching)? = nil,
        timing: LibraryTiming = .standard,
        defaults: UserDefaults = .standard,
        passwordRounds: Int = PasswordKey.defaultRounds
    ) {
        self.store = store
        self.watcher = watcher
        self.timing = timing
        self.defaults = defaults
        self.passwordRounds = passwordRounds
        self.mirror = VaultMirror(defaults: defaults)
    }

    public func note(with id: Note.ID) -> Note? {
        notes.first { $0.id == id }
    }

    /// The note whose file is at `path` in the library ("Work/Ideas.md"). A
    /// bare name, as earlier builds saved it, is a note at the top.
    public func note(atPath path: String) -> Note? {
        notes.first { $0.relativePath == path }
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
            if let lastPath = defaults.string(forKey: Self.selectionKey), let restored = note(atPath: lastPath) {
                selectedID = restored.id
            } else if let first = notes.first {
                selectedID = first.id
            } else {
                selectNewDraft()
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
        // Each editor shows the same file again afterwards; the front one last,
        // so it stays in front.
        var shown: [(editor: any NoteEditor, name: String?)] = []
        if isLoaded {
            await saveNow()
            shown = liveEditors.map { ($0, $0.displayedNoteID.flatMap(note(with:))?.relativePath) }
            for (editor, _) in shown { show(nil, in: editor) }
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
        // The new folder's vault decides; the key stays if it's the same password.
        vaultFromFile = false
        awaitingUnlock.removeAll()
        // Loading selects a note; the editors are given theirs below.
        editor = nil
        await load()
        let loaded = selectedID
        for (editor, name) in shown where editors.contains(where: { $0.value === editor }) {
            if let name, let note = note(atPath: name), show(note.id, in: editor) {
                continue
            }
            if editor === shown.last?.editor, let loaded, show(loaded, in: editor) { continue }
            replaceRemovedNote(in: editor, neighbor: nil)
        }
        if let problem {
            logger.error("\(problem.title, privacy: .public): \(problem.message, privacy: .public)")
            presentedError = problem
        }
    }

    // MARK: Editor

    /// Adds an editor in front, showing the selected note (or nothing, if
    /// another editor already shows it).
    public func attach(_ editor: any NoteEditor) {
        if !show(selectedID, in: editor) { show(nil, in: editor) }
    }

    /// Shows a note in `editor`, attaching it if needed, and brings that editor
    /// to the front. The note it showed before is wrapped up (see
    /// `endSession`) once no editor shows it. Returns false, changing nothing,
    /// if another editor shows the note: two editors on one file would
    /// overwrite each other.
    @discardableResult
    public func show(_ id: Note.ID?, in editor: any NoteEditor) -> Bool {
        if let id {
            guard note(with: id) != nil else { return false }
            if let other = self.editor(showing: id), other !== editor { return false }
        }
        let isNew = !editors.contains { $0.value === editor }
        let previous = editor.displayedNoteID.flatMap(note(with:))
        if isNew || editor.displayedNoteID != id {
            if let previous { captureEditorText(of: previous) }
            editor.display(id.flatMap(note(with:)))
        }
        bringToFront(editor)
        let deselected = moveSelection(to: id)
        wrapUpIfClosed([previous, deselected])
        return true
    }

    /// The editor's window came forward: the selection follows its note.
    public func activate(_ editor: any NoteEditor) {
        guard editors.contains(where: { $0.value === editor }) else { return }
        bringToFront(editor)
        wrapUpIfClosed([moveSelection(to: editor.displayedNoteID)])
    }

    /// The editor is going away (its tab or window closed). Keeps its text,
    /// saves, and wraps its note up unless another editor still shows it.
    public func detach(_ editor: any NoteEditor) {
        guard let index = editors.firstIndex(where: { $0.value === editor }) else { return }
        let shown = editor.displayedNoteID.flatMap(note(with:))
        if let shown { captureEditorText(of: shown) }
        editors.remove(at: index)
        var deselected: Note?
        if self.editor === editor {
            self.editor = liveEditors.last
            if let front = self.editor { deselected = moveSelection(to: front.displayedNoteID) }
        }
        wrapUpIfClosed([shown, deselected])
        Task { await saveNow() }
    }

    /// The editor showing the note, if any.
    public func editor(showing id: Note.ID) -> (any NoteEditor)? {
        liveEditors.first { $0.displayedNoteID == id }
    }

    /// Called by the editor after every edit, with the first
    /// `NoteNaming.prefixLength` characters (enough for title and excerpt).
    public func editorDidChange(noteID: Note.ID, prefix: some StringProtocol) {
        // A sealed note's page is read-only; anything reported for it is ignored.
        guard let note = note(with: noteID), !note.isSealed else { return }
        note.revision += 1
        note.updateDerived(from: prefix)
        updateSuddenTermination()
        scheduleSave(note)
    }

    // MARK: Commands

    /// Starts a new draft at the top and focuses the editor. Nothing is written
    /// until the draft has text; reuses the current draft if it's still empty.
    public func newNote(locked: Bool = false, in folder: FolderPath = .root) {
        guard !isSingleFile, !isLibraryLocked else { return }
        searchText = ""
        if let current = selectedNote, current.isDraft, current.isLocked == (locked || lockScope == .library),
           editorText(of: current)?.isBlank == true {
            current.folder = folder
            editor?.focus()
            return
        }
        open(insertDraft(locked: locked, in: folder).id)
        editor?.focus()
    }

    /// A new, empty draft at the top of the list, not shown anywhere yet: for
    /// an editor of its own (File ▸ New Tab). None while the whole library is
    /// locked: a note written behind the lock screen would have no key.
    public func makeDraft(locked: Bool = false, in folder: FolderPath = .root) -> Note.ID? {
        guard !isSingleFile, !isLibraryLocked else { return nil }
        searchText = ""
        return insertDraft(locked: locked, in: folder).id
    }

    /// Opens a note on the user's behalf: through `openHandler` when there is
    /// one, otherwise by selecting it.
    public func open(_ id: Note.ID) {
        if let openHandler {
            openHandler(id)
        } else {
            selectedID = id
        }
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
            if note.hasUnsavedChanges, let payload = self.payload(for: note) {
                _ = try? await self.store.write(payload, to: url, autoNameTag: nil, noteID: note.id, revision: note.revision)
            }
            do {
                guard let trashed = try await self.store.trash(url) else { return nil }
                return TrashReceipt(trashedURL: trashed, originalName: url.lastPathComponent, folder: note.folder)
            } catch {
                self.report("Couldn't move “\(note.title)” to the Trash", error)
                self.notes.append(note)
                self.sortNotes()
                return nil
            }
        }.value
    }

    /// Moves the note to the Trash and lets `undoManager` put it back.
    public func moveToTrash(_ id: Note.ID, undoManager: UndoManager?, actionName: String) {
        Task {
            guard let receipt = await moveToTrash(id), let undoManager else { return }
            undoManager.registerUndo(withTarget: self) { library in
                Task { @MainActor in await library.restore(receipt) }
            }
            undoManager.setActionName(actionName)
        }
    }

    /// Puts a trashed note back and selects it.
    public func restore(_ receipt: TrashReceipt) async {
        let url: URL
        do {
            url = try await store.restore(receipt.trashedURL, preferredName: receipt.originalName, in: receipt.folder)
        } catch {
            report("Couldn't put the note back", error)
            return
        }
        await settledRescan()
        if let note = notes.first(where: { $0.fileURL == url }) {
            open(note.id)
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
                let oldStem = note.fileStem
                let renamed = try await self.store.renameManually(url, to: stem)
                note.fileURL = renamed
                self.renameOrderKey(in: note.folder, from: oldStem, to: note.fileStem)
                note.autoNameTag = nil
                note.refreshAutoNamed()
                note.updateDerived()
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
                open(duplicate.id)
            }
        } catch {
            report("Couldn't duplicate the note", error)
        }
    }

    /// Saves every note with pending edits and renames the open note if its
    /// first line changed. Returns once those writes have landed (or failed).
    /// Used when the app is deactivated, the window closes, or the app quits.
    public func saveNow() async {
        for note in notes { captureEditorText(of: note) }
        var writes: [Task<Void?, Never>] = []
        for note in notes where note.hasUnsavedChanges || saveTimers[note.id] != nil || isOpen(note) {
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
        for note in notes where note.isAutoNamed && !note.isDraft && !note.isSealed && note.isKnownBlank {
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
            let ops = operations.values.map(\.done) + [vaultWrite].compactMap { $0 }
            let rescan = rescanTask
            if timers.isEmpty && ops.isEmpty && rescan == nil { return }
            for timer in timers { await timer.value }
            for op in ops { await op.value }
            await rescan?.value
            if rescanTask == rescan { rescanTask = nil }
        }
    }

    // MARK: Locking

    /// Sets the first password and unlocks. Returns the recovery key, which
    /// the user must keep: it's never stored, nor shown again. Takes a moment
    /// (the password is stretched into a key off the main thread).
    @discardableResult
    public func setPassword(_ password: String, hint: String?) async throws -> RecoveryCode {
        guard canSetPassword else { throw hasPassword ? LockError.notUnlocked : LockError.notReady }
        try PasswordPolicy.check(password: password, hint: hint)
        let rounds = passwordRounds
        let code = RecoveryCode.generate()
        let key = try await Task.detached(priority: .userInitiated) {
            try LibraryKey.create(password: password, hint: hint, rounds: rounds, recoveryCode: code)
        }.value
        let record = VaultRecord(key: key.record, scope: .notes, revision: 0, signedWith: key)
        try await store.writeVault(record)
        applyVault(record, fromFile: true)
        install(NoteSealer(key))
        return code
    }

    /// Opens every locked note with the password, until `lockNow`. Also opens
    /// notes still sealed with an earlier password, when that's the one given.
    /// Throws `LockError.wrongPassword`.
    public func unlock(password: String) async throws {
        // While the vault can't be read yet, the locked notes' own records stand in.
        guard let current = vault?.key ?? notes.lazy.compactMap(\.lockRecord).first else { throw LockError.noPassword }
        if sealer != nil { reopenSealedNotes() }
        var records: [KeyRecord] = []
        if sealer == nil { records.append(current) }
        for note in notes where note.isSealed {
            guard let record = note.lockRecord, sealer?.canOpen(record.keyID) != true,
                  !records.contains(where: { $0.keyID == record.keyID }) else { continue }
            records.append(record)
        }
        guard !records.isEmpty else { return }
        let keys = await Task.detached(priority: .userInitiated) {
            records.compactMap { try? LibraryKey.unlock($0, password: password) }
        }.value
        var unlocked: NoteSealer
        if let sealer {
            unlocked = sealer
        } else if let key = keys.first(where: { $0.keyID == current.keyID }) {
            unlocked = NoteSealer(key)
        } else {
            throw LockError.wrongPassword
        }
        let earlier = keys.filter { $0.keyID != unlocked.keyID }
        if sealer != nil && earlier.isEmpty { throw LockError.wrongPassword }
        for key in earlier { unlocked = unlocked.reading(key) }
        install(unlocked)
    }

    /// Opens every locked note with a key recovered without the password
    /// (Touch ID). False when it isn't the library's current key.
    @discardableResult
    public func unlock(with key: LibraryKey) -> Bool {
        guard let vault, key.keyID == vault.key.keyID else { return false }
        if sealer?.keyID != key.keyID { install(NoteSealer(key)) }
        return true
    }

    /// Locks now: every locked note's text leaves memory at once. Edits not on
    /// disk yet are sealed first and written as they are, which needs no key.
    /// Synchronous, so nothing can read or change a note halfway.
    public func lockNow() {
        guard let sealer else { return }
        for note in notes where note.isLocked && !note.isSealed {
            captureEditorText(of: note)
            let text = note.text ?? ""
            var pending: SealedText?
            if note.hasUnsavedChanges && !(note.isDraft && text.isBlank), let data = try? sealer.seal(text) {
                pending = SealedText(data: data, isBlank: text.isBlank)
            } else {
                note.savedRevision = note.revision // Nothing worth writing.
            }
            seal(note, pending: pending)
        }
        let sealed = Set(notes.filter(\.isSealed).map(\.id))
        for editor in liveEditors { editor.forgetText(of: sealed) }
        self.sealer = nil
        isUnlocked = false
        lockEpoch += 1
        mutationCounter += 1
        for note in notes where note.isSealed && note.hasUnsavedChanges {
            saveTimers.removeValue(forKey: note.id)?.cancel()
            enqueue(note.id) { [weak self] in await self?.performSave(note, rename: .always) }
        }
        updateSuddenTermination()
    }

    /// Locks one note: from now on its file holds only sealed text. A draft
    /// is sealed when it's first written. Needs the library unlocked.
    public func lock(_ id: Note.ID) async throws {
        guard !isSingleFile, let note = note(with: id), !note.isLocked else { return }
        guard let sealer else { throw hasPassword ? LockError.notUnlocked : LockError.noPassword }
        if note.isDraft {
            note.lockOnCreate = true
            note.updateDerived()
            return
        }
        let result = await enqueue(id) { [weak self] () -> Result<Void, any Error> in
            guard let self, self.contains(note), !note.isLocked, let url = note.fileURL else { return .success(()) }
            self.captureEditorText(of: note)
            guard let text = note.text else { return .success(()) }
            let revision = note.revision
            do {
                let saved = try await self.store.convert(url, to: .sealed(try sealer.seal(text), isBlank: text.isBlank))
                self.moved(note, to: saved, revision: revision)
                note.lockRecord = sealer.current.record
                note.updateDerived()
                // Locked meanwhile (Lock Now, sleep): `lockNow` passed this note
                // by, still plain then. Seal it now, edits typed since included.
                if self.sealer == nil { self.sealLate(note, with: sealer) }
                try await self.writeVaultIfNeeded()
                return .success(())
            } catch {
                return .failure(error)
            }
        }.value
        try result.get()
    }

    /// Unlocks one note for good: its file holds plain text again. Not in
    /// Whole library mode, where every note stays locked.
    public func removeLock(_ id: Note.ID) async throws {
        guard !isSingleFile, lockScope == .notes, let note = note(with: id), note.isLocked else { return }
        guard let sealer, !note.isSealed else { throw LockError.notUnlocked }
        if note.isDraft {
            note.lockOnCreate = false
            note.updateDerived()
            return
        }
        let result = await enqueue(id) { [weak self] () -> Result<Void, any Error> in
            guard let self, self.contains(note), note.isLocked, let url = note.fileURL else { return .success(()) }
            self.captureEditorText(of: note)
            guard let text = note.text else { return .failure(LockError.notUnlocked) }
            let revision = note.revision
            do {
                let saved = try await self.store.convert(url, to: .plain(text))
                // Sealed meanwhile (Lock Now): it's a plain note now, so its
                // text comes back, with any edits sealed at locking time.
                if case .sealed(let pending) = note.content {
                    let latest = pending.flatMap { try? sealer.open($0.data).text } ?? text
                    note.content = .plain(latest)
                    self.editor(showing: note.id)?.display(note)
                }
                self.moved(note, to: saved, revision: revision)
                note.lockRecord = nil
                note.updateDerived()
                return .success(())
            } catch {
                return .failure(error)
            }
        }.value
        try result.get()
    }

    /// Replaces the password. Every locked note is sealed again with a new key,
    /// so the old password opens nothing written from now on. Returns the new
    /// recovery key (the old one stops working too). Throws
    /// `LockError.wrongPassword` when `old` isn't the current password.
    @discardableResult
    public func changePassword(from old: String, to new: String, hint: String?) async throws -> RecoveryCode {
        guard let vault else { throw LockError.noPassword }
        try PasswordPolicy.check(password: new, hint: hint)
        let oldKey = try await Task.detached(priority: .userInitiated) {
            try LibraryKey.unlock(vault.key, password: old)
        }.value
        return try await changePassword(with: oldKey, to: new, hint: hint)
    }

    /// Replaces the password, proving it's the user with the current key
    /// rather than the password: recovered by Touch ID, or by the recovery
    /// key when the password is forgotten. Unlocks.
    @discardableResult
    public func changePassword(with oldKey: LibraryKey, to new: String, hint: String?) async throws -> RecoveryCode {
        guard let vault else { throw LockError.noPassword }
        guard oldKey.keyID == vault.key.keyID else { throw LockError.lockedWithAnotherPassword }
        try PasswordPolicy.check(password: new, hint: hint)
        let rounds = passwordRounds
        let code = RecoveryCode.generate()
        let newKey = try await Task.detached(priority: .userInitiated) {
            try LibraryKey.create(password: new, hint: hint, rounds: rounds, recoveryCode: code)
        }.value
        // No scan reads the folder while it's half changed.
        beginDiskWork()
        defer { endDiskWork() }
        // The vault first: if writing it fails, nothing has changed. If Minote
        // stops after it, notes still on the old key open with that one
        // ("earlier password") and are sealed again then. The lock mode is
        // the one the old key vouches for, not whatever the file says now.
        let previous = folderVault ?? vault
        let record = VaultRecord(key: newKey.record, scope: trustedScope(of: previous, with: oldKey),
                                 revision: previous.revision + 1, signedWith: newKey)
        try await store.writeVault(record)
        install(NoteSealer(newKey).reading(oldKey))
        applyVault(record, fromFile: true)
        await resealLockedNotes { $0.lockRecord?.keyID != newKey.keyID }
        let left = notes.filter { $0.isLocked && !$0.isDraft && $0.lockRecord?.keyID != newKey.keyID }
        if !left.isEmpty {
            let names = left.prefix(3).map { "“\($0.displayTitle)”" }.joined(separator: ", ")
            presentedError = LibraryError(
                title: "Some notes still use an earlier password",
                message: "\(names)\(left.count > 3 ? " and \(left.count - 3) more" : "") couldn't be locked with the new password yet. Minote will try again when they're unlocked."
            )
        }
        return code
    }

    /// The library key, opened with the recovery key instead of the password
    /// (to set a new password). Throws `LockError.wrongRecoveryKey`.
    public func key(recoveryCode code: RecoveryCode) async throws -> LibraryKey {
        guard let current = vault?.key ?? notes.lazy.compactMap(\.lockRecord).first else { throw LockError.noPassword }
        // A vault without one (edited, or older) may still have it in the notes' own headers.
        let record = current.recovery != nil ? current
            : notes.lazy.compactMap(\.lockRecord).first { $0.keyID == current.keyID && $0.recovery != nil } ?? current
        return try await Task.detached(priority: .userInitiated) {
            try LibraryKey.unlock(record, recoveryCode: code)
        }.value
    }

    /// A new recovery key for the current password; the old one stops
    /// working once every locked note is sealed again, which happens now.
    /// Needs the library unlocked.
    public func makeRecoveryCode() async throws -> RecoveryCode {
        guard let vault else { throw LockError.noPassword }
        guard let current = sealer?.current else { throw LockError.notUnlocked }
        let code = RecoveryCode.generate()
        let key = try await Task.detached(priority: .userInitiated) { try current.withRecoveryCode(code) }.value
        guard let sealer, sealer.keyID == key.keyID else { throw LockError.notUnlocked } // Locked meanwhile.
        beginDiskWork()
        defer { endDiskWork() }
        let previous = folderVault ?? vault
        let record = VaultRecord(key: key.record, scope: trustedScope(of: previous, with: key),
                                 revision: previous.revision, signedWith: key)
        try await store.writeVault(record)
        self.sealer = sealer.replacingRecord(with: key)
        applyVault(record, fromFile: true)
        await resealLockedNotes { $0.lockRecord != key.record }
        return code
    }

    /// Locks the whole library, or goes back to locking notes one by one.
    /// Whole library locks every note now, and every new note from then on.
    public func setScope(_ scope: LockScope) async throws {
        guard let current = vault else { throw LockError.noPassword }
        guard let sealer else { throw LockError.notUnlocked }
        if current.scope != scope {
            let previous = folderVault ?? current
            let record = VaultRecord(key: current.key, scope: scope, revision: max(previous.revision, current.revision) + 1,
                                     signedWith: sealer.current)
            try await store.writeVault(record)
            applyVault(record, fromFile: true)
        }
        if scope == .library { try await lockEveryNote() }
    }

    /// Writes every open locked note again with the current key and record
    /// (a new password, or a new recovery key). Sealed ones are written once
    /// they're opened (see `unseal`).
    private func resealLockedNotes(where needed: (Note) -> Bool) async {
        var writes: [Task<Void?, Never>] = []
        for note in notes where note.isLocked && !note.isDraft && needed(note) {
            if !note.isSealed { note.revision += 1 }
            saveTimers.removeValue(forKey: note.id)?.cancel()
            writes.append(enqueue(note.id) { [weak self] in await self?.performSave(note, rename: .whenNotEditingTitle) })
        }
        for write in writes { await write.value }
    }

    /// Takes the lock off every note (back to plain files).
    public func removeAllLocks() async throws {
        guard lockScope == .notes else { return }
        var firstError: (any Error)?
        for note in notes where note.isLocked {
            do { try await removeLock(note.id) } catch { firstError = firstError ?? error }
        }
        if let firstError { throw firstError }
    }

    /// Forgets the password, once nothing is locked.
    public func removePassword() async throws {
        guard vault != nil, lockScope == .notes, !hasLockedNotes else { return }
        try await store.writeVault(nil)
        forgetVault()
    }

    private func lockEveryNote() async throws {
        var firstError: (any Error)?
        for note in notes where !note.isLocked {
            do { try await lock(note.id) } catch { firstError = firstError ?? error }
        }
        if let firstError { throw firstError }
    }

    /// Puts the key in memory and opens every sealed note with it.
    private func install(_ newSealer: NoteSealer) {
        sealer = newSealer
        unopenable.removeAll()
        if !isUnlocked { isUnlocked = true }
        // With the key at hand, the folder's lock mode can be checked.
        confirmScope()
        lockEpoch += 1
        mutationCounter += 1
        let epoch = lockEpoch
        for note in notes where note.isSealed {
            enqueue(note.id) { [weak self] in await self?.unseal(note, epoch: epoch) }
        }
        // Edits that waited for the key (see `payload(sealing:)`).
        for id in awaitingUnlock {
            if let note = note(with: id) { scheduleSave(note) }
        }
        // Plain files that turned up in a locked library (put there by another app).
        if lockScope == .library, notes.contains(where: { !$0.isLocked }) {
            Task { try? await lockEveryNote() }
        }
    }

    private func unseal(_ note: Note, epoch: Int) async {
        guard epoch == lockEpoch, let sealer, contains(note), case .sealed(let pending) = note.content else { return }
        let opened: (text: String, keyID: UUID)
        do {
            if let pending {
                opened = try sealer.open(pending.data)
            } else if let url = note.fileURL {
                if let record = note.lockRecord, !sealer.canOpen(record.keyID) { return }
                opened = try await store.openLocked(at: url, with: sealer)
            } else {
                opened = ("", sealer.keyID) // An empty draft made while locked.
            }
        } catch LockError.lockedWithAnotherPassword {
            return // Stays shut until its own password is given.
        } catch {
            unopenable.insert(note.id)
            report("Couldn't open “\(note.displayTitle)”", error)
            return
        }
        // Locked again while the file was being read.
        guard epoch == lockEpoch, case .sealed = note.content else { return }
        note.content = .plain(opened.text)
        note.updateDerived()
        editor(showing: note.id)?.display(note)
        if opened.keyID != sealer.keyID {
            // Sealed with an earlier password: seal it again with the current one.
            note.revision += 1
            scheduleSave(note)
        }
    }

    /// Seals a note that became locked after `lockNow` ran: what's in its
    /// editor is sealed with the key it was locked with, then written.
    private func sealLate(_ note: Note, with sealer: NoteSealer) {
        captureEditorText(of: note)
        let text = note.text ?? ""
        var pending: SealedText?
        if note.hasUnsavedChanges, let data = try? sealer.seal(text) {
            pending = SealedText(data: data, isBlank: text.isBlank)
        } else {
            note.savedRevision = note.revision
        }
        seal(note, pending: pending)
        for editor in liveEditors { editor.forgetText(of: [note.id]) }
        if pending != nil { scheduleSave(note) }
    }

    /// Opens sealed notes the key now holds, which stayed shut (a read that
    /// failed, or a note sealed again elsewhere with this key).
    private func reopenSealedNotes() {
        guard let sealer else { return }
        let epoch = lockEpoch
        for note in notes where note.isSealed && note.lockRecord.map({ sealer.canOpen($0.keyID) }) != false {
            guard operations[note.id] == nil, !unopenable.contains(note.id) else { continue }
            enqueue(note.id) { [weak self] in await self?.unseal(note, epoch: epoch) }
        }
    }

    /// Points a note at the file it was converted into.
    private func moved(_ note: Note, to saved: SavedFile, revision: Int) {
        let wasAutoNamed = note.isAutoNamed
        let oldStem = note.fileStem
        note.fileURL = saved.url
        renameOrderKey(in: note.folder, from: oldStem, to: note.fileStem)
        note.stamp = saved.stamp
        note.modified = saved.stamp.modified
        if wasAutoNamed { note.autoNameTag = note.fileStem }
        note.refreshAutoNamed()
        note.savedRevision = max(note.savedRevision, revision)
        updateSuddenTermination()
        if selectedID == note.id { persistSelection() }
    }

    /// Takes in what the folder says about the password.
    private func reconcileVault(_ read: VaultRead) {
        guard !isSingleFile else { return }
        vaultIsMissing = read == .missing
        switch read {
        case .found(let record):
            applyVault(record, fromFile: true)
        case .pending, .unreadable:
            // Can't be read yet: this device's copy, or a locked note's record,
            // stands in (in memory only: nothing is written over the real one).
            if vault == nil {
                if let copy = mirror.record {
                    applyVault(copy, fromFile: false)
                } else if let record = notes.lazy.compactMap(\.lockRecord).first {
                    applyVault(VaultRecord(key: record, scope: .notes), fromFile: false)
                }
            }
        case .missing:
            let lockedRecords = notes.compactMap(\.lockRecord)
            if lockedRecords.isEmpty {
                if vaultFromFile {
                    forgetVault() // Removed on another device, with nothing locked.
                } else if vault == nil, let copy = mirror.record {
                    // A folder without one, such as the notes on this device while iCloud is off.
                    applyVault(copy, fromFile: false)
                }
                return
            }
            // Locked notes but no vault: it was deleted, or didn't come along.
            // Rebuilt from what's known, so the password and mode live on.
            let known = [vault, mirror.record].compactMap { $0 }.first { known in
                lockedRecords.contains { $0.keyID == known.key.keyID }
            }
            let rebuilt = known ?? VaultRecord(key: lockedRecords[0], scope: .notes)
            applyVault(rebuilt, fromFile: false)
            guard vaultWrite == nil else { return }
            writeVaultLater(rebuilt, isCurrent: { true }) { [weak self] in
                guard let self, self.vault == rebuilt else { return }
                self.vaultFromFile = true
                self.folderVault = rebuilt
            }
        }
    }

    /// Writes the vault off to the side (rebuilt, or signed again), each
    /// write after the one before; `waitUntilIdle` waits for them. Skipped
    /// when `isCurrent` says another record was written meanwhile.
    private func writeVaultLater(_ record: VaultRecord, isCurrent: @escaping @MainActor () -> Bool,
                                 written: @escaping @MainActor () -> Void = {}) {
        let previous = vaultWrite
        let token = UUID()
        vaultWriteToken = token
        beginDiskWork()
        vaultWrite = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            if isCurrent() {
                do {
                    try await self.store.writeVault(record)
                    written()
                } catch {
                    self.logger.error("Couldn't write the vault: \(error.localizedDescription, privacy: .public)")
                }
            }
            if self.vaultWriteToken == token { self.vaultWrite = nil }
            self.endDiskWork()
        }
    }

    private func applyVault(_ record: VaultRecord, fromFile: Bool) {
        // The password was changed on another device: this key opens nothing new.
        if let sealer, sealer.keyID != record.key.keyID { lockNow() }
        var applied = record
        // The folder asks to lock less than this device last knew. Anything
        // can edit that file, so the stronger mode holds until unlocking
        // shows Minote itself changed it (see `confirmScope`).
        let held = sealer == nil && record.scope == .notes && mirror.record?.scope == .library
        if held { applied.scope = .library }
        if vault != applied { vault = applied }
        if fromFile {
            vaultFromFile = true
            folderVault = record
            if !held, mirror.record != record { mirror.record = record }
        }
        if sealer != nil { confirmScope() }
    }

    private func forgetVault() {
        lockNow()
        sealer = nil
        isUnlocked = false
        vault = nil
        vaultFromFile = false
        folderVault = nil
        mirror.record = nil
    }

    /// Writes the vault into the folder when it came from this device's copy:
    /// the folder now holds locked notes, which need it.
    private func writeVaultIfNeeded() async throws {
        guard let vault, !vaultFromFile else { return }
        try await store.writeVault(vault)
        vaultFromFile = true
        folderVault = vault
    }

    /// The lock mode `key` vouches for: the folder's if Minote signed it, or
    /// this device's own copy's if that's signed and newer (an old copy of
    /// the file put back). With no signature to go by, Whole Library wins if
    /// either side says so, or if the folder's signature is there but wrong
    /// (edited after Minote wrote it). A record that was never signed (rebuilt
    /// from a note's header, or written before signing) keeps "notes".
    private func trustedScope(of folder: VaultRecord, with key: LibraryKey) -> LockScope {
        let signedFolder = folder.isSigned(by: key) ? folder : nil
        let signedCopy = mirror.record.flatMap { $0.isSigned(by: key) ? $0 : nil }
        switch (signedFolder, signedCopy) {
        case let (folder?, copy?): return copy.revision > folder.revision ? copy.scope : folder.scope
        case let (folder?, nil): return folder.scope
        case let (nil, copy?): return copy.scope
        case (nil, nil):
            if folder.scope == .library || mirror.record?.scope == .library { return .library }
            return folder.scopeCheck == nil ? .notes : .library
        }
    }

    /// Unlocked: believes the folder's lock mode only if the key vouches for
    /// it. Otherwise (edited outside Minote, an old copy put back, or written
    /// before records were signed) the trusted mode is signed and written
    /// back, so the edit doesn't spread to other devices either.
    private func confirmScope() {
        guard let key = sealer?.current, vaultFromFile, let folder = folderVault, folder.key.keyID == key.keyID else { return }
        let scope = trustedScope(of: folder, with: key)
        if folder.isSigned(by: key) && folder.scope == scope {
            if vault != folder { vault = folder }
            if mirror.record != folder { mirror.record = folder }
            return
        }
        let revision = max(folder.revision, mirror.record.map(\.revision) ?? 0)
        let signed = VaultRecord(key: folder.key, scope: scope, revision: revision, signedWith: key)
        vault = signed
        folderVault = signed
        mirror.record = signed
        if folder.scope != scope {
            logger.notice("The vault asked to lock less than Minote set; keeping Whole Library")
            presentedError = LibraryError(
                title: "Whole Library lock stays on",
                message: "Minote's lock settings were changed outside Minote, to lock less. They were put back. If you meant to lock only some notes, choose Selected Notes in Settings."
            )
            if notes.contains(where: { !$0.isLocked }) { Task { try? await lockEveryNote() } }
        }
        writeVaultLater(signed, isCurrent: { [weak self] in self?.folderVault == signed })
    }

    // MARK: Links

    /// The note a relative link points to. Read as a real path from the
    /// linking note's folder first (`Sub/Note.md`, `../Note.md`); when nothing
    /// is there, by name anywhere, as links written before folders expect:
    /// `Other note.md`, `Other note` or `../Notes/Other note.md` find the note
    /// whose file is "Other note.md", preferring the linking note's folder,
    /// then the one nearest the top.
    public func note(linkedAs path: String, from origin: Note? = nil) -> Note? {
        let name = (path as NSString).lastPathComponent
        guard !name.isEmpty else { return nil }
        let stem = NoteNaming.isNoteFile(URL(fileURLWithPath: name)) ? (name as NSString).deletingPathExtension : name
        let base = origin?.folder ?? .root

        // The path itself, from the linking note's folder.
        var components = base.components
        var escaped = false
        for part in (path as NSString).deletingLastPathComponent.split(separator: "/") {
            switch part {
            case ".": continue
            case "..": if components.isEmpty { escaped = true } else { components.removeLast() }
            default: components.append(String(part))
            }
        }
        if !escaped {
            let folder = FolderPath(components)
            let inFolder = notes.filter { $0.folder.components.map { $0.lowercased() } == folder.components.map { $0.lowercased() } }
            if let found = inFolder.first(where: { $0.fileURL?.lastPathComponent.caseInsensitiveCompare(name) == .orderedSame })
                ?? inFolder.first(where: { $0.fileStem?.caseInsensitiveCompare(stem) == .orderedSame }) {
                return found
            }
        }

        // By name, anywhere.
        let nearest: (Note, Note) -> Bool = { a, b in
            let aHere = a.folder == base, bHere = b.folder == base
            if aHere != bHere { return aHere }
            return a.folder.depth < b.folder.depth
        }
        return notes.filter { $0.fileURL?.lastPathComponent.caseInsensitiveCompare(name) == .orderedSame }.min(by: nearest)
            ?? notes.filter { $0.fileStem?.caseInsensitiveCompare(stem) == .orderedSame }.min(by: nearest)
            ?? notes.filter { $0.title.caseInsensitiveCompare(stem) == .orderedSame }.min(by: nearest)
    }

    /// Follows a relative link in the open note: shows the note it names, or
    /// returns the file, next to the open note, for another app to open.
    public func followLink(to path: String) -> URL? {
        if let note = note(linkedAs: path, from: selectedNote) {
            open(note.id)
            return nil
        }
        return selectedNote?.fileURL.map { URL(fileURLWithPath: path, relativeTo: $0.deletingLastPathComponent()) }
    }

    // MARK: Selection

    /// Someone set `selectedID`: the front editor shows that note, or, if
    /// another editor already shows it, that editor comes to the front.
    private func selectionDidChange(from oldID: Note.ID?) {
        guard !isSyncingSelection else { return }
        var left: Note?
        if let front = editor {
            if let id = selectedID, let other = editor(showing: id), other !== front {
                bringToFront(other)
            } else {
                left = front.displayedNoteID.flatMap(note(with:))
                if let left { captureEditorText(of: left) }
                front.display(selectedNote)
            }
        }
        persistSelection()
        wrapUpIfClosed([oldID.flatMap(note(with:)), left])
    }

    /// Moves `selectedID` without showing anything (the editors already show
    /// what they should). Returns the note that was selected before.
    private func moveSelection(to id: Note.ID?) -> Note? {
        guard selectedID != id else { return nil }
        let old = selectedID.flatMap(note(with:))
        isSyncingSelection = true
        selectedID = id
        isSyncingSelection = false
        persistSelection()
        return old
    }

    /// Whether the note is open: selected, or shown by some editor.
    private func isOpen(_ note: Note) -> Bool {
        selectedID == note.id || editor(showing: note.id) != nil
    }

    /// Wraps up each of these notes that is no longer open (once each).
    private func wrapUpIfClosed(_ candidates: [Note?]) {
        var done = Set<Note.ID>()
        for case let note? in candidates where !done.contains(note.id) {
            done.insert(note.id)
            if contains(note), !isOpen(note) { endSession(note) }
        }
    }

    private var liveEditors: [any NoteEditor] {
        editors.removeAll { $0.value == nil }
        return editors.compactMap(\.value)
    }

    private func bringToFront(_ editor: any NoteEditor) {
        editors.removeAll { $0.value == nil || $0.value === editor }
        editors.append(WeakEditor(value: editor))
        self.editor = editor
    }

    func persistSelection() {
        // The library's last opened note isn't an opened file's business.
        guard !isSingleFile else { return }
        defaults.set(selectedNote?.relativePath, forKey: Self.selectionKey)
    }

    /// Wraps up a note the user just left (no editor shows it any more):
    /// drops it if it's an empty draft, saves it, renames it to follow its
    /// first line, and trashes it quietly if the user emptied an auto-named file.
    private func endSession(_ note: Note) {
        enqueue(note.id) { [weak self] in
            guard let self, self.contains(note) else { return }
            if note.isDraft && note.isKnownBlank {
                if !self.isOpen(note) { self.remove(note) }
                note.savedRevision = note.revision
                self.updateSuddenTermination()
                return
            }
            await self.performSave(note, rename: .always)
            if !self.isOpen(note) {
                await self.trashIfEmptied(note)
            }
        }
    }

    /// An auto-named note the user emptied has nothing left to keep: it goes to
    /// the Trash quietly instead of lingering as an empty file.
    private func trashIfEmptied(_ note: Note) async {
        // A sealed note's text is unknown: never take it for empty.
        guard contains(note), note.isAutoNamed, !note.hasUnsavedChanges, !note.isSealed, note.isKnownBlank,
              let url = note.fileURL else { return }
        do {
            _ = try await store.trash(url)
            remove(note)
        } catch {
            logger.error("Couldn't trash empty note: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Saving

    enum RenamePolicy {
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

    func performSave(_ note: Note, rename: RenamePolicy) async {
        guard contains(note) else { return }
        saveTimers.removeValue(forKey: note.id)?.cancel()
        firstUnsavedEdit[note.id] = nil
        captureEditorText(of: note)
        let revision = note.revision
        guard note.hasUnsavedChanges || note.fileURL == nil else {
            return await finishSave(note, revision: revision, rename: rename)
        }
        let payload: NotePayload
        do {
            guard let made = try self.payload(sealing: note) else { return }
            payload = made
        } catch {
            saveFailed(note, error)
            return
        }

        if let url = note.fileURL {
            do {
                let tag = note.isAutoNamed ? note.autoNameTag : nil
                if let stamp = try await store.write(payload, to: url, autoNameTag: tag, noteID: note.id, revision: revision) {
                    note.stamp = stamp
                    note.modified = stamp.modified
                }
            } catch {
                saveFailed(note, error)
                return
            }
        } else if !payload.isBlank {
            // A draft gets its file once it has something in it: a locked
            // note's sealed from the first byte.
            do {
                let title = note.text.map { NoteNaming.title(of: $0.prefix(NoteNaming.prefixLength)) } ?? note.title
                let saved = try await store.create(payload, base: NoteNaming.fileStem(forTitle: title), in: note.folder)
                note.fileURL = saved.url
                note.stamp = saved.stamp
                note.modified = saved.stamp.modified
                note.autoNameTag = note.fileStem
                note.refreshAutoNamed()
                if selectedID == note.id { persistSelection() }
            } catch {
                saveFailed(note, error)
                return
            }
        }
        if case .sealed(let data, _) = payload { note.lockRecord = try? LockedNoteFile.record(of: data) }
        await finishSave(note, revision: revision, rename: rename)
    }

    private func finishSave(_ note: Note, revision: Int, rename: RenamePolicy) async {
        note.savedRevision = max(note.savedRevision, revision)
        retryAttempts[note.id] = nil
        // Sealed edits are on disk now: nothing of them needs to stay in memory.
        if case .sealed(.some) = note.content, !note.hasUnsavedChanges {
            note.content = .sealed(pending: nil)
        }

        let editingTitle = editor(showing: note.id)?.isCaretInTitleLine == true
        if rename == .always || !editingTitle {
            await renameIfNeeded(note)
        }
        sortNotes()
        updateSuddenTermination()
    }

    /// What to write for a note: its text, sealed when the note is locked, or
    /// the sealed edits it was locked with. Nil when there's nothing to write:
    /// a sealed note without edits, or a locked note's text while the library
    /// is locked (edited here while it was locked on another device), which
    /// waits for the key rather than go to disk in the clear.
    private func payload(sealing note: Note) throws -> NotePayload? {
        switch note.content {
        case .sealed(let pending):
            return pending.map { .sealed($0.data, isBlank: $0.isBlank) }
        case .plain(let text):
            guard note.isLocked else { return .plain(text) }
            guard let sealer else {
                if awaitingUnlock.insert(note.id).inserted {
                    presentedError = LibraryError(
                        title: "“\(note.displayTitle)” is locked",
                        message: "It was locked on another device while you were editing it. Unlock your locked notes to save your latest changes."
                    )
                }
                return nil
            }
            awaitingUnlock.remove(note.id)
            return .sealed(try sealer.seal(text), isBlank: text.isBlank)
        }
    }

    /// `payload(sealing:)` for paths that can't report an error.
    private func payload(for note: Note) -> NotePayload? {
        try? payload(sealing: note)
    }

    private func renameIfNeeded(_ note: Note) async {
        // A sealed note keeps its name until it's unlocked: its first line is unknown.
        guard note.isAutoNamed, let text = note.text, let url = note.fileURL, let stem = note.fileStem else { return }
        let title = NoteNaming.title(of: text.prefix(NoteNaming.prefixLength))
        // An emptied note keeps its name; it's trashed when the user leaves it.
        guard !title.isEmpty else { return }
        let desired = NoteNaming.fileStem(forTitle: title)
        if desired == stem { return }
        do {
            let newURL = try await store.rename(url, toBase: desired)
            guard newURL != url else { return }
            note.fileURL = newURL
            renameOrderKey(in: note.folder, from: stem, to: note.fileStem)
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
            presentedError = LibraryError(
                title: "Couldn't save “\(note.displayTitle)”",
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

    /// Runs `operation` after every earlier operation on any of these notes,
    /// holding all of them until it's done: nothing is written to a note
    /// while its folder moves.
    @discardableResult
    func enqueue<T: Sendable>(holding ids: [Note.ID], _ operation: @escaping @MainActor () async -> T) -> Task<T, Never> {
        let previous = ids.compactMap { operations[$0]?.done }
        let token = UUID()
        beginDiskWork()
        let task = Task { @MainActor [weak self] () -> T in
            for earlier in previous { await earlier.value }
            let result = await operation()
            if let self {
                for id in ids where self.operations[id]?.token == token { self.operations[id] = nil }
                self.endDiskWork()
            }
            return result
        }
        let done = Task { _ = await task.value }
        for id in ids { operations[id] = (token, done) }
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
        let vaultRead = await store.readVault()
        let files: ScanResult
        do {
            files = try await store.scanTree(known: knownStamps(), sealer: sealer)
        } catch {
            logger.error("Scan failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        // Also thrown away when the library was locked or unlocked meanwhile:
        // the scan opened notes with the key it had then.
        guard inFlight == 0, generation == mutationCounter else {
            rescanPending = true
            if inFlight == 0 { scheduleRescan() }
            return
        }
        reconcile(files)
        reconcileVault(vaultRead)
    }

    /// Waits for our own disk operations to finish, then rescans; retries if
    /// another operation slipped in while scanning.
    func settledRescan() async {
        for _ in 0..<5 {
            while let pending = operations.values.first?.done { await pending.value }
            let generation = mutationCounter
            let vaultRead = await store.readVault()
            guard let files = try? await store.scanTree(known: knownStamps(), sealer: sealer) else { return }
            if inFlight == 0 && generation == mutationCounter {
                reconcile(files)
                reconcileVault(vaultRead)
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

    private func reconcile(_ scan: ScanResult) {
        let files = scan.files
        let scannedFolders = scan.folders.map(\.path).sorted()
        if scannedFolders != folders { folders = scannedFolders }
        // Every time: folder commands change `folders` themselves, and a
        // watcher that can only see one folder must follow each of them.
        watcher?.watch(folders: [store.directory] + scannedFolders.map(store.folderURL))
        var settings: [FolderPath: FolderSettings] = [:]
        var unreadable = Set<FolderPath>()
        for (folder, read) in scan.settings {
            switch read {
            case .found(let found): if !found.isEmpty { settings[folder] = found }
            case .unreadable: unreadable.insert(folder)
            }
        }
        if settings != folderSettings { folderSettings = settings }
        unreadableSettings = unreadable
        var byURL: [URL: Note] = [:]
        for note in notes {
            if let url = note.fileURL { byURL[url] = note }
        }

        var seen = Set<URL>()
        var added: [Note] = []
        for file in files {
            seen.insert(file.url)
            guard let note = byURL[file.url] else {
                if let content = file.content { added.append(Note(file: file, content: content)) }
                continue
            }
            if note.autoNameTag != file.autoNameTag {
                note.autoNameTag = file.autoNameTag
                note.refreshAutoNamed()
            }
            // The file says where the note is.
            if note.folder != file.folder { note.folder = file.folder }
            guard let content = file.content else { continue }
            note.stamp = file.stamp
            if case .locked(let record, _) = content { note.lockRecord = record }
            guard let text = file.text else {
                // A locked note this library can't open now.
                if note.modified != file.stamp.modified { note.modified = file.stamp.modified }
                if !note.isSealed, !note.hasUnsavedChanges, saveTimers[note.id] == nil {
                    // Sealed with a password changed on another device: it stays shut until that one is given.
                    seal(note, pending: nil)
                }
                continue
            }
            // A sealed note never gets its text from a scan: only unlocking opens it.
            if note.isSealed { continue }
            if text == note.text {
                if note.modified != file.stamp.modified { note.modified = file.stamp.modified }
                continue
            }
            if note.hasUnsavedChanges || saveTimers[note.id] != nil {
                // Both sides changed. The local edits win and will overwrite the file.
                logger.notice("\(file.url.lastPathComponent, privacy: .public) changed on disk while it had unsaved edits; keeping the edits")
                continue
            }
            note.content = .plain(text)
            note.modified = file.stamp.modified
            note.updateDerived()
            editor(showing: note.id)?.reloadText(text)
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
            // Locked or unlocked on another device: "Ideas.md" became
            // "Ideas.mdlock" (or back). Same note, same tab, same edits.
            if let index = added.firstIndex(where: { isConversion(of: url, to: $0.fileURL) }) {
                adopt(added.remove(at: index), into: note)
                continue
            }
            // Moved to another folder (by Finder, another app or device): the
            // same file under the same name, unchanged. Only when exactly one
            // file fits; otherwise it's a note removed and another added.
            let moves = added.indices.filter { isMove(of: note, to: added[$0]) }
            if moves.count == 1 {
                adopt(added.remove(at: moves[0]), into: note)
                continue
            }
            if note.hasUnsavedChanges {
                // Deleted elsewhere while the user was typing: keep the text and
                // write it again as a new file rather than lose it (sealed, if
                // the note was locked).
                note.lockOnCreate = note.isLocked
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
        // Locked notes that turned up, or changed, while unlocked open too.
        if sealer != nil { reopenSealedNotes() }
        // An opened file that couldn't be read at first shows up once it can.
        if isSingleFile, isLoaded, selectedID == nil, let first = notes.first {
            selectedID = first.id
        }
    }

    // MARK: Helpers

    func contains(_ note: Note) -> Bool {
        notes.contains { $0 === note }
    }

    /// Removes a note from the list. An editor showing it goes away or shows
    /// its neighbor; if it was selected without an editor, the neighbor is
    /// selected. With no notes left, a new draft takes its place.
    func remove(_ note: Note) {
        let visible = visibleNotes
        var neighbor: Note?
        if let index = visible.firstIndex(where: { $0 === note }) {
            neighbor = visible.indices.contains(index + 1) ? visible[index + 1] : (index > 0 ? visible[index - 1] : nil)
        }
        let showing = liveEditors.filter { $0.displayedNoteID == note.id }
        notes.removeAll { $0 === note }
        saveTimers.removeValue(forKey: note.id)?.cancel()
        firstUnsavedEdit[note.id] = nil
        retryAttempts[note.id] = nil
        for editor in showing where shownNoteRemovedHandler?(editor) != true {
            replaceRemovedNote(in: editor, neighbor: neighbor)
        }
        if selectedID == note.id {
            if let neighbor {
                selectedID = neighbor.id
            } else if let first = notes.first {
                selectedID = first.id
            } else {
                selectNewDraft()
            }
        }
        updateSuddenTermination()
    }

    /// Shows something else in an editor whose note is gone: the neighbor, or
    /// the first note no editor shows, or a new draft.
    private func replaceRemovedNote(in editor: any NoteEditor, neighbor: Note?) {
        if let neighbor, self.editor(showing: neighbor.id) == nil, show(neighbor.id, in: editor) { return }
        if let free = notes.first(where: { self.editor(showing: $0.id) == nil }), show(free.id, in: editor) { return }
        searchText = ""
        show(insertDraft().id, in: editor)
        editor.focus()
    }

    /// The library is empty: a new draft, selected and ready for typing.
    private func selectNewDraft() {
        searchText = ""
        selectedID = insertDraft().id
        editor?.focus()
    }

    private func insertDraft(locked: Bool = false, in folder: FolderPath = .root) -> Note {
        let note = Note(draftCreatedAt: Date(), in: folder)
        if (locked && hasPassword) || lockScope == .library {
            note.lockOnCreate = true
            // Behind the lock: nothing can be typed into it until it's unlocked.
            if sealer == nil { note.content = .sealed(pending: nil) }
        }
        notes.insert(note, at: 0)
        return note
    }

    /// Whether `old` vanishing and `new` appearing is one note locked or
    /// unlocked elsewhere: same name, one plain, one locked.
    private func isConversion(of old: URL, to new: URL?) -> Bool {
        guard let new else { return false }
        return old.deletingLastPathComponent() == new.deletingLastPathComponent()
            && NoteNaming.stemsMatch(old.deletingPathExtension().lastPathComponent, new.deletingPathExtension().lastPathComponent)
            && NoteNaming.isLockedFile(old) != NoteNaming.isLockedFile(new)
    }

    /// Whether `scanned` is `note`'s file, moved to another folder elsewhere:
    /// the same name and the same size and modification date.
    private func isMove(of note: Note, to scanned: Note) -> Bool {
        guard let old = note.fileURL, let new = scanned.fileURL, let stamp = note.stamp else { return false }
        return note.folder != scanned.folder
            && old.lastPathComponent == new.lastPathComponent
            && scanned.stamp == stamp
    }

    /// Moves `note` onto the file another device converted it into. Edits not
    /// on disk yet win, as with any outside change, and are saved into the new
    /// file: sealed if it's locked.
    private func adopt(_ scanned: Note, into note: Note) {
        let wasAutoNamed = note.isAutoNamed
        note.fileURL = scanned.fileURL
        note.folder = scanned.folder
        note.stamp = scanned.stamp
        note.modified = scanned.modified
        note.created = scanned.created
        note.autoNameTag = scanned.autoNameTag ?? (wasAutoNamed ? scanned.fileStem : nil)
        note.lockRecord = scanned.lockRecord
        note.refreshAutoNamed()
        if selectedID == note.id { persistSelection() }
        if note.hasUnsavedChanges || saveTimers[note.id] != nil {
            scheduleSave(note)
            return
        }
        switch scanned.content {
        case .plain(let text):
            // Moved, or unlocked elsewhere with the same text: the editor
            // keeps its caret, scroll and undo.
            let changed = note.text != text
            note.content = .plain(text)
            note.updateDerived()
            if changed { editor(showing: note.id)?.display(note) }
        case .sealed:
            seal(note, pending: nil)
        }
    }

    /// Takes a note's text out of memory and shows it locked.
    private func seal(_ note: Note, pending: SealedText?) {
        note.content = .sealed(pending: pending)
        note.updateDerived()
        editor(showing: note.id)?.display(note)
    }

    private func sortNotes() {
        let sorted = notes.sorted { a, b in
            if a.isDraft != b.isDraft { return a.isDraft }
            if a.modified != b.modified { return a.modified > b.modified }
            let nameA = a.relativePath ?? ""
            let nameB = b.relativePath ?? ""
            return nameA.localizedStandardCompare(nameB) == .orderedAscending
        }
        if !sorted.elementsEqual(notes, by: ===) { notes = sorted }
    }

    /// Copies the live text of the editor showing the note, if it has edits.
    /// Never from a sealed note's editor: it shows nothing, which isn't the text.
    func captureEditorText(of note: Note) {
        guard note.hasUnsavedChanges, !note.isSealed, let editor = editor(showing: note.id) else { return }
        note.content = .plain(editor.currentText())
    }

    /// The live text, or nil for a sealed note.
    private func editorText(of note: Note) -> String? {
        guard !note.isSealed else { return nil }
        return editor(showing: note.id)?.currentText() ?? note.text
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

    func report(_ title: String, _ error: any Error) {
        logger.error("\(title, privacy: .public): \(error.localizedDescription, privacy: .public)")
        presentedError = LibraryError(title: title, message: error.localizedDescription)
    }
}

/// Editors are owned by their windows; the library only points at them.
@MainActor
private struct WeakEditor {
    weak var value: (any NoteEditor)?
}
