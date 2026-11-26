import Foundation
import Testing
@testable import MinoteKit

@MainActor
@Suite("Locked notes")
struct LibraryLockTests {
    private let password = "correct horse"
    /// Must never be found on disk once its note is locked.
    private let marker = "ZEBRA-4242"

    private func makeLibrary(_ folder: TemporaryLibrary, timing: LibraryTiming = .fast,
                             defaults: UserDefaults = freshDefaults()) async -> (Library, FakeEditor) {
        let library = Library(store: folder.makeStore(), timing: timing, defaults: defaults, passwordRounds: testRounds)
        let editor = FakeEditor()
        library.attach(editor)
        await library.load()
        return (library, editor)
    }

    private func note(_ stem: String, in library: Library) throws -> Note {
        try #require(library.notes.first { $0.fileStem == stem || $0.title == stem })
    }

    /// Every file under the test folder (notes, hidden files, Trash, backups)
    /// whose bytes contain `text`.
    private func files(containing text: String, under root: URL) -> [String] {
        let needle = Data(text.utf8)
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        return walker.compactMap { $0 as? URL }.filter {
            (try? Data(contentsOf: $0))?.range(of: needle) != nil
        }.map(\.lastPathComponent)
    }

    // MARK: Locking a note

    @Test func lockingANoteSealsItsFileAndDeletesThePlainOne() async throws {
        let folder = try TemporaryLibrary()
        try folder.write("Secret \(marker)\nbody", to: "Secret.md")
        let (library, editor) = await makeLibrary(folder)
        let secret = try note("Secret", in: library)

        try await library.setPassword(password, hint: "a horse")
        #expect(library.isUnlocked)
        #expect(folder.fileNames == ["Secret.md"])
        try await library.lock(secret.id)

        #expect(folder.fileNames == ["Secret.mdlock"])
        #expect(files(containing: marker, under: folder.root).isEmpty)
        #expect(secret.isLocked)
        #expect(secret.text == "Secret \(marker)\nbody")
        #expect(secret.excerpt.isEmpty)
        #expect(editor.displayedNoteID == secret.id)
        #expect(folder.trashedCount == 0)
    }

    @Test func lockingNeedsAPasswordAndAnUnlockedLibrary() async throws {
        let folder = try TemporaryLibrary()
        try folder.write("Plain", to: "Plain.md")
        let (library, _) = await makeLibrary(folder)
        let plain = try note("Plain", in: library)

        await #expect(throws: LockError.noPassword) { try await library.lock(plain.id) }
        try await library.setPassword(password, hint: nil)
        library.lockNow()
        await #expect(throws: LockError.notUnlocked) { try await library.lock(plain.id) }
        #expect(folder.fileNames == ["Plain.md"])
    }

    @Test("Nothing of a locked note's text is ever on disk in the clear")
    func noPlainTextAnywhere() async throws {
        let folder = try TemporaryLibrary()
        try folder.write("Diary \(marker)\nfirst entry", to: "Diary.md")
        try folder.write("Other\nnote", to: "Other.md")
        let defaults = freshDefaults()
        let (library, editor) = await makeLibrary(folder, defaults: defaults)
        let diary = try note("Diary", in: library)
        library.selectedID = diary.id

        // Emptied before it was locked: a plain backup is kept, and must go.
        editor.type("", in: library)
        await library.waitUntilIdle()
        #expect(!files(containing: "first entry", under: folder.backups).isEmpty)
        editor.type("Diary \(marker)\nsecond entry \(marker)", in: library)
        await library.waitUntilIdle()

        try await library.setPassword(password, hint: nil)
        try await library.lock(diary.id)
        #expect(files(containing: "first entry", under: folder.root).isEmpty)

        // Autosave, wrap-up on leaving, locking with unsaved edits, unlocking again.
        editor.type("Diary \(marker)\nthird entry \(marker)", in: library)
        await library.waitUntilIdle()
        editor.type("Diary \(marker)\nfourth entry \(marker)", in: library)
        library.lockNow()
        await library.waitUntilIdle()
        try await library.unlock(password: password)
        await library.waitUntilIdle()
        #expect(diary.text == "Diary \(marker)\nfourth entry \(marker)")
        library.selectedID = try note("Other", in: library).id
        await library.waitUntilIdle()
        library.selectedID = diary.id

        // Duplicate, rename, empty (backup), trash.
        await library.duplicate(diary.id)
        await library.waitUntilIdle()
        let copy = try #require(library.notes.first { $0.fileStem == "Diary copy" })
        #expect(copy.isLocked)
        await library.rename(diary.id, to: "Renamed")
        library.selectedID = diary.id
        editor.type("", in: library)
        await library.waitUntilIdle()
        await library.moveToTrash(copy.id)
        await library.waitUntilIdle()

        #expect(folder.trashedCount == 1)
        #expect(folder.fileNames == ["Other.md", "Renamed.mdlock"])
        #expect(files(containing: marker, under: folder.root).isEmpty)
        #expect(files(containing: "entry", under: folder.root).isEmpty)
        #expect(!"\(defaults.dictionaryRepresentation())".contains(marker))
    }

    // MARK: Lock and unlock

    @Test func lockNowSealsUnsavedEditsAndWritesThemWithoutTheKey() async throws {
        let folder = try TemporaryLibrary()
        try folder.write("Plan\nv1", to: "Plan.md")
        let (library, editor) = await makeLibrary(folder, timing: .manual)
        let plan = try note("Plan", in: library)
        library.selectedID = plan.id
        try await library.setPassword(password, hint: nil)
        try await library.lock(plan.id)
        let key = try #require(library.unlockedKey)

        editor.type("Plan\nv2 typed just before locking", in: library)
        library.lockNow()

        #expect(!library.isUnlocked)
        #expect(plan.isSealed)
        #expect(plan.text == nil)
        #expect(editor.isShowingSealed)
        #expect(editor.text.isEmpty)
        #expect(editor.displayedNoteID == plan.id)
        await library.waitUntilIdle()
        #expect(!plan.hasUnsavedChanges)
        let store = folder.makeStore()
        let saved = try await store.openLocked(at: folder.notes.appendingPathComponent("Plan.mdlock"), with: NoteSealer(key))
        #expect(saved.text == "Plan\nv2 typed just before locking")

        try await library.unlock(password: password)
        await library.waitUntilIdle()
        #expect(plan.text == "Plan\nv2 typed just before locking")
        #expect(editor.text == "Plan\nv2 typed just before locking")
        #expect(!editor.isShowingSealed)
    }

    @Test func aWriteThatFailsWhileLockedIsRetriedWithoutTheKey() async throws {
        let folder = try TemporaryLibrary()
        try folder.write("Retry\nv1", to: "Retry.md")
        let (library, editor) = await makeLibrary(folder, timing: .manual)
        let retry = try note("Retry", in: library)
        library.selectedID = retry.id
        try await library.setPassword(password, hint: nil)
        try await library.lock(retry.id)
        let key = try #require(library.unlockedKey)

        // The folder refuses writes: the save made when locking fails.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.notes.path)
        editor.type("Retry\nv2", in: library)
        library.lockNow()
        await library.waitUntilIdle()
        #expect(retry.hasUnsavedChanges)
        library.presentedError = nil

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.notes.path)
        for _ in 0..<100 where retry.hasUnsavedChanges { try await Task.sleep(for: .milliseconds(20)) }
        #expect(!retry.hasUnsavedChanges)
        let saved = try await folder.makeStore().openLocked(at: folder.notes.appendingPathComponent("Retry.mdlock"), with: NoteSealer(key))
        #expect(saved.text == "Retry\nv2")
    }

    @Test func typingIntoASealedNoteChangesNothing() async throws {
        let folder = try TemporaryLibrary()
        try folder.write("Kept\nas is", to: "Kept.md")
        let (library, editor) = await makeLibrary(folder)
        let kept = try note("Kept", in: library)
        library.selectedID = kept.id
        try await library.setPassword(password, hint: nil)
        try await library.lock(kept.id)
        library.lockNow()
        await library.waitUntilIdle()

        editor.type("x", in: library)
        #expect(!kept.hasUnsavedChanges)
        await library.waitUntilIdle()
        try await library.unlock(password: password)
        await library.waitUntilIdle()
        #expect(kept.text == "Kept\nas is")
    }

    @Test func aWrongPasswordUnlocksNothing() async throws {
        let folder = try TemporaryLibrary()
        try folder.write("Hidden", to: "Hidden.md")
        let (library, _) = await makeLibrary(folder)
        let hidden = try note("Hidden", in: library)
        try await library.setPassword(password, hint: "a horse")
        try await library.lock(hidden.id)
        library.lockNow()

        await #expect(throws: LockError.wrongPassword) { try await library.unlock(password: "wrong") }
        #expect(!library.isUnlocked)
        #expect(hidden.isSealed)
        #expect(library.vault?.key.hint == "a horse")
    }

    @Test func aSealedNoteIsNeverEmptiedOrTrashed() async throws {
        let folder = try TemporaryLibrary()
        let (library, editor) = await makeLibrary(folder)
        editor.type("Auto named\nbody", in: library)
        await library.waitUntilIdle()
        let note = try #require(library.selectedNote)
        #expect(note.isAutoNamed)
        try await library.setPassword(password, hint: nil)
        try await library.lock(note.id)
        library.lockNow()

        // Leaving it, closing its editor and quitting all wrap a note up.
        library.newNote()
        library.detach(editor)
        await library.prepareForTermination()
        #expect(folder.fileNames == ["Auto named.mdlock"])
        #expect(folder.trashedCount == 0)
        #expect(!library.hasUnsavedChanges)
    }

    @Test func aSealedNoteMatchesSearchByTitleOnly() async throws {
        let folder = try TemporaryLibrary()
        try folder.write("Recipes\nsaffron rice", to: "Recipes.md")
        let (library, _) = await makeLibrary(folder)
        let recipes = try note("Recipes", in: library)
        try await library.setPassword(password, hint: nil)
        try await library.lock(recipes.id)

        library.searchText = "saffron"
        #expect(library.visibleNotes.map(\.id) == [recipes.id])
        library.lockNow()
        #expect(library.visibleNotes.isEmpty)
        library.searchText = "recipes"
        #expect(library.visibleNotes.map(\.id) == [recipes.id])
    }

    @Test func aScanNeverHandsTextToASealedNote() async throws {
        let folder = try TemporaryLibrary()
        try folder.write("Watched\nv1", to: "Watched.md")
        let (library, editor) = await makeLibrary(folder)
        let watched = try note("Watched", in: library)
        library.selectedID = watched.id
        try await library.setPassword(password, hint: nil)
        try await library.lock(watched.id)
        let sealer = NoteSealer(try #require(library.unlockedKey))
        library.lockNow()
        await library.waitUntilIdle()

        // Another device edits it.
        try sealer.seal("Watched\nv2 from elsewhere").write(to: folder.notes.appendingPathComponent("Watched.mdlock"))
        await library.rescanNow()
        #expect(watched.isSealed)
        #expect(editor.text.isEmpty)

        try await library.unlock(password: password)
        await library.waitUntilIdle()
        #expect(watched.text == "Watched\nv2 from elsewhere")
    }

    @Test func removingTheLockBringsThePlainFileBack() async throws {
        let folder = try TemporaryLibrary()
        try folder.write("Open\nagain", to: "Open.md")
        let (library, _) = await makeLibrary(folder)
        let open = try note("Open", in: library)
        try await library.setPassword(password, hint: nil)
        try await library.lock(open.id)
        try await library.removeLock(open.id)

        #expect(folder.fileNames == ["Open.md"])
        #expect(folder.contents(of: "Open.md") == "Open\nagain")
        #expect(!open.isLocked)
        #expect(open.excerpt == "again")
    }

    // MARK: Other devices

    @Test("Locked on another device: the tab keeps its note")
    func aLockMadeElsewhereKeepsTheTab() async throws {
        let folder = try TemporaryLibrary()
        try folder.write("Shared\ntext", to: "Shared.md")
        let (library, editor) = await makeLibrary(folder)
        let shared = try note("Shared", in: library)
        library.selectedID = shared.id
        try await library.setPassword(password, hint: nil)
        let sealer = NoteSealer(try #require(library.unlockedKey))

        try sealer.seal("Shared\ntext").write(to: folder.notes.appendingPathComponent("Shared.mdlock"))
        try FileManager.default.removeItem(at: folder.notes.appendingPathComponent("Shared.md"))
        await library.rescanNow()

        #expect(library.notes.count == 1)
        #expect(shared.fileURL?.lastPathComponent == "Shared.mdlock")
        #expect(shared.text == "Shared\ntext")
        #expect(editor.displayedNoteID == shared.id)
    }

    @Test func changingThePasswordSealsEveryNoteAgain() async throws {
        let folder = try TemporaryLibrary()
        try folder.write("One", to: "One.md")
        try folder.write("Two", to: "Two.md")
        let (library, _) = await makeLibrary(folder)
        try await library.setPassword(password, hint: nil)
        for note in library.notes { try await library.lock(note.id) }
        let oldKeyID = try #require(library.vault?.key.keyID)
        library.lockNow()

        try await library.changePassword(from: password, to: "a brand new password", hint: nil)
        await library.waitUntilIdle()
        let store = folder.makeStore()
        for name in ["One.mdlock", "Two.mdlock"] {
            let record = try await store.lockedRecord(at: folder.notes.appendingPathComponent(name))
            #expect(record.keyID != oldKeyID)
            #expect(record.keyID == library.vault?.key.keyID)
        }
        library.lockNow()
        await #expect(throws: LockError.wrongPassword) { try await library.unlock(password: password) }
        try await library.unlock(password: "a brand new password")
        await library.waitUntilIdle()
        #expect(library.notes.map(\.text).sorted { ($0 ?? "") < ($1 ?? "") } == ["One", "Two"])
    }

    @Test func aMissingVaultIsRebuiltFromTheNotes() async throws {
        let folder = try TemporaryLibrary()
        try folder.write("Kept", to: "Kept.md")
        let (library, _) = await makeLibrary(folder)
        try await library.setPassword(password, hint: nil)
        try await library.lock(try note("Kept", in: library).id)
        let vaultURL = folder.notes.appendingPathComponent(VaultRecord.fileName)
        try FileManager.default.removeItem(at: vaultURL)

        // Another device, which never saw the vault.
        let (other, _) = await makeLibrary(folder)
        await other.waitUntilIdle()
        #expect(other.hasPassword)
        #expect(FileManager.default.fileExists(atPath: vaultURL.path))
        try await other.unlock(password: password)
        await other.waitUntilIdle()
        #expect(try note("Kept", in: other).text == "Kept")
    }

    // MARK: Whole library

    @Test func wholeLibraryModeLocksEveryNoteAndEveryNewOne() async throws {
        let folder = try TemporaryLibrary()
        try folder.write("A", to: "A.md")
        try folder.write("B", to: "B.md")
        let (library, editor) = await makeLibrary(folder)
        try await library.setPassword(password, hint: nil)
        try await library.setScope(.library)
        #expect(folder.fileNames == ["A.mdlock", "B.mdlock"])

        library.newNote()
        editor.type("Fresh \(marker)", in: library)
        await library.waitUntilIdle()
        #expect(folder.fileNames == ["A.mdlock", "B.mdlock", "Fresh \(marker).mdlock"])
        #expect(files(containing: "Fresh", under: folder.root).isEmpty)

        library.lockNow()
        #expect(library.isLibraryLocked)
        #expect(library.makeDraft() == nil)
        let count = library.notes.count
        library.newNote()
        #expect(library.notes.count == count)
    }

    @Test("Whole library mode holds on this device even where the folder has no vault")
    func theDevicesCopyKeepsWholeLibraryMode() async throws {
        let defaults = freshDefaults()
        let folder = try TemporaryLibrary()
        let (library, _) = await makeLibrary(folder, defaults: defaults)
        try await library.setPassword(password, hint: nil)
        try await library.setScope(.library)

        // The notes on this device, while iCloud is off: an empty folder.
        let local = try TemporaryLibrary()
        let (fallback, _) = await makeLibrary(local, defaults: defaults)
        #expect(fallback.isLibraryLocked)
        #expect(fallback.makeDraft() == nil)
        try await fallback.unlock(password: password)
        #expect(fallback.makeDraft() != nil)
    }

    @Test func thePasswordCanBeRemovedOnceNothingIsLocked() async throws {
        let folder = try TemporaryLibrary()
        try folder.write("Note", to: "Note.md")
        let (library, _) = await makeLibrary(folder)
        try await library.setPassword(password, hint: nil)
        try await library.lock(try note("Note", in: library).id)
        try await library.removePassword()
        #expect(library.hasPassword)

        try await library.removeAllLocks()
        try await library.removePassword()
        #expect(!library.hasPassword)
        #expect(folder.fileNames == ["Note.md"])
        #expect(!FileManager.default.fileExists(atPath: folder.notes.appendingPathComponent(VaultRecord.fileName).path))
    }
}

@Suite("File store: locked notes")
struct NoteFileStoreLockTests {
    @Test func aLockedNoteIsNeverReadAsText() async throws {
        let library = try TemporaryLibrary()
        let sealer = NoteSealer(try LibraryKey.create(password: "pw", hint: nil, rounds: testRounds))
        // Even renamed to .md by someone, it isn't decoded as Latin-1 garbage.
        try sealer.seal("secret").write(to: library.notes.appendingPathComponent("Renamed.md"))
        let store = library.makeStore()
        await #expect(throws: LockError.lockedNote) { try await store.readText(at: library.notes.appendingPathComponent("Renamed.md")) }
        #expect(try await store.scan(known: [:]).isEmpty)
    }

    @Test func plainTextNeverGoesIntoALockedFileNorSealedBytesIntoAPlainOne() async throws {
        let library = try TemporaryLibrary()
        let sealer = NoteSealer(try LibraryKey.create(password: "pw", hint: nil, rounds: testRounds))
        let store = library.makeStore()
        let locked = try await store.create(.sealed(try sealer.seal("x"), isBlank: false), base: "Locked")
        #expect(locked.url.lastPathComponent == "Locked.mdlock")
        await #expect(throws: LockError.notUnlocked) {
            try await store.write(.plain("leak"), to: locked.url, autoNameTag: nil, noteID: UUID(), revision: 1)
        }
        let plain = try await store.create(text: "plain", base: "Plain")
        await #expect(throws: LockError.lockedNote) {
            try await store.write(.sealed(try sealer.seal("x"), isBlank: false), to: plain.url, autoNameTag: nil, noteID: UUID(), revision: 1)
        }
    }

    @Test func namesAreUniqueAcrossPlainAndLockedNotes() async throws {
        let library = try TemporaryLibrary()
        let sealer = NoteSealer(try LibraryKey.create(password: "pw", hint: nil, rounds: testRounds))
        try sealer.seal("x").write(to: library.notes.appendingPathComponent("Ideas.mdlock"))
        let store = library.makeStore()
        #expect(try await store.create(text: "Ideas", base: "Ideas").url.lastPathComponent == "Ideas 2.md")

        let plain = library.notes.appendingPathComponent("Ideas 2.md")
        let converted = try await store.convert(plain, to: .sealed(try sealer.seal("Ideas"), isBlank: false))
        #expect(converted.url.lastPathComponent == "Ideas 2.mdlock")
        #expect(library.fileNames == ["Ideas 2.mdlock", "Ideas.mdlock"])
    }

    @Test func aLockedNoteScansSealedWithoutItsKeyAndOpenWithIt() async throws {
        let library = try TemporaryLibrary()
        let key = try LibraryKey.create(password: "pw", hint: nil, rounds: testRounds)
        try NoteSealer(key).seal("inside").write(to: library.notes.appendingPathComponent("Box.mdlock"))
        let store = library.makeStore()

        let sealed = try #require(try await store.scan(known: [:]).first)
        #expect(sealed.text == nil)
        guard case .locked(let record, nil)? = sealed.content else { Issue.record("not locked"); return }
        #expect(record.keyID == key.keyID)
        #expect(try await store.scan(known: [:], sealer: NoteSealer(key)).first?.text == "inside")
    }
}

@MainActor
@Suite("Locked notes: races and edge cases")
struct LibraryLockRaceTests {
    private let password = "correct horse"

    private func makeLibrary(_ folder: TemporaryLibrary, defaults: UserDefaults = freshDefaults()) async -> (Library, FakeEditor) {
        let library = Library(store: folder.makeStore(), timing: .fast, defaults: defaults, passwordRounds: testRounds)
        let editor = FakeEditor()
        library.attach(editor)
        await library.load()
        return (library, editor)
    }

    @Test("Lock Now while a note is being locked: it ends up sealed, never open")
    func lockNowDuringLocking() async throws {
        for yields in 0..<8 {
            let folder = try TemporaryLibrary()
            try folder.write("Race \(yields)\ntext", to: "Race.md")
            let (library, editor) = await makeLibrary(folder)
            let note = try #require(library.notes.first)
            library.selectedID = note.id
            try await library.setPassword(password, hint: nil)

            let locking = Task { try await library.lock(note.id) }
            for _ in 0..<yields { await Task.yield() }
            library.lockNow()
            _ = try? await locking.value
            await library.waitUntilIdle()

            if note.isLocked {
                #expect(note.isSealed, "yields \(yields)")
                #expect(editor.isShowingSealed, "yields \(yields)")
                #expect(folder.fileNames == ["Race.mdlock"])
            } else {
                #expect(folder.fileNames == ["Race.md"])
            }
            try await library.unlock(password: password)
            await library.waitUntilIdle()
            #expect(note.text == "Race \(yields)\ntext", "yields \(yields)")
        }
    }

    @Test("Lock Now while a lock is being removed: the note comes out plain and open")
    func lockNowDuringRemovingTheLock() async throws {
        for yields in 0..<8 {
            let folder = try TemporaryLibrary()
            try folder.write("Open \(yields)\ntext", to: "Open.md")
            let (library, _) = await makeLibrary(folder)
            let note = try #require(library.notes.first)
            try await library.setPassword(password, hint: nil)
            try await library.lock(note.id)

            let removing = Task { try await library.removeLock(note.id) }
            for _ in 0..<yields { await Task.yield() }
            library.lockNow()
            _ = try? await removing.value
            await library.waitUntilIdle()

            if note.isLocked {
                #expect(note.isSealed, "yields \(yields)")
            } else {
                #expect(!note.isSealed, "yields \(yields)")
                #expect(note.text == "Open \(yields)\ntext", "yields \(yields)")
                #expect(folder.contents(of: "Open.md") == "Open \(yields)\ntext")
            }
            #expect(library.presentedError == nil, "yields \(yields)")
        }
    }

    @Test("Backups made under an earlier name go when the note is locked")
    func backupsFollowRenames() async throws {
        let folder = try TemporaryLibrary()
        try folder.write("Bank PINs 1234", to: "Bank.md")
        let (library, editor) = await makeLibrary(folder)
        let note = try #require(library.notes.first)
        library.selectedID = note.id
        editor.type("", in: library)
        await library.waitUntilIdle()
        editor.type("Accounts", in: library)
        await library.waitUntilIdle()
        await library.rename(note.id, to: "Accounts")
        #expect(FileManager.default.fileExists(atPath: folder.backups.path))

        try await library.setPassword(password, hint: nil)
        try await library.lock(note.id)
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: folder.backups.path)) ?? []
        #expect(leftovers.isEmpty, "\(leftovers)")
    }

    @Test("No new password while the folder's vault can't be read: it would replace it")
    func noPasswordOverAnUnreadableVault() async throws {
        let folder = try TemporaryLibrary()
        let key = try LibraryKey.create(password: password, hint: nil, rounds: testRounds)
        try NoteSealer(key).seal("Kept\nsafe").write(to: folder.notes.appendingPathComponent("Kept.mdlock"))
        try Data("not a vault".utf8).write(to: folder.notes.appendingPathComponent(VaultRecord.fileName))
        let (library, _) = await makeLibrary(folder)

        #expect(!library.canSetPassword)
        await #expect(throws: (any Error).self) { try await library.setPassword("another", hint: nil) }
        #expect(try String(contentsOf: folder.notes.appendingPathComponent(VaultRecord.fileName), encoding: .utf8) == "not a vault")
        // The note's own record still opens it.
        try await library.unlock(password: password)
        await library.waitUntilIdle()
        #expect(library.notes.first?.text == "Kept\nsafe")
    }

    @Test func aPlantedRecordCantMakeUnlockingHang() throws {
        let key = try LibraryKey.create(password: password, hint: nil, rounds: testRounds)
        let json = try JSONEncoder().encode(key.record)
        var object = try #require(try JSONSerialization.jsonObject(with: json) as? [String: Any])
        object["rounds"] = Int(UInt32.max)
        let planted = try JSONDecoder().decode(KeyRecord.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(throws: LockError.damaged) { try LibraryKey.unlock(planted, password: password) }
    }
}
