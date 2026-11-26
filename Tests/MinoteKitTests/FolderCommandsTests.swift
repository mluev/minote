import Foundation
import Testing
@testable import MinoteKit

@MainActor
@Suite("Folder commands")
struct FolderCommandsTests {
    private func makeLibrary(_ folder: TemporaryLibrary, timing: LibraryTiming = .fast,
                             defaults: UserDefaults = freshDefaults()) async -> (Library, FakeEditor) {
        let library = Library(store: folder.makeStore(), timing: timing, defaults: defaults, passwordRounds: testRounds)
        let editor = FakeEditor()
        library.attach(editor)
        await library.load()
        return (library, editor)
    }

    private func note(_ path: String, in library: Library) throws -> Note {
        try #require(library.note(atPath: path))
    }

    private func settingsFile(_ folder: TemporaryLibrary, _ path: String = "") -> FolderSettings? {
        let url = folder.notes.appendingPathComponent(path).appendingPathComponent(FolderSettings.fileName)
        guard let data = try? Data(contentsOf: url), case .found(let settings) = FolderSettings.decode(data) else { return nil }
        return settings
    }

    // MARK: Settings file

    @Test func settingsRoundTripAndRefuseUnknownVersions() throws {
        let settings = FolderSettings(sort: .title, reversed: true, order: ["Clients/", "Plan"])
        #expect(FolderSettings.decode(try settings.encoded()) == .found(settings))
        #expect(FolderSettings.decode(Data(#"{"version": 2, "order": []}"#.utf8)) == .unreadable)
        #expect(FolderSettings.decode(Data("nonsense".utf8)) == .unreadable)
        // A sort this build doesn't know reads as none, keeping the order.
        #expect(FolderSettings.decode(Data(#"{"version": 1, "sort": "colour", "order": ["A"]}"#.utf8)) == .found(FolderSettings(order: ["A"])))
    }

    @Test func sortIsInheritedFromTheFolderAbove() async throws {
        let folder = try TemporaryLibrary()
        try folder.write("x", to: "Work/Clients/X.md")
        let (library, _) = await makeLibrary(folder)
        #expect(library.sortOrder(of: FolderPath(string: "Work/Clients")) == .standard)

        library.setSort(SortOrder(.title, reversed: true), for: .root)
        #expect(library.sortOrder(of: FolderPath(string: "Work/Clients")) == SortOrder(.title, reversed: true))
        library.setSort(SortOrder(.created), for: FolderPath(string: "Work"))
        #expect(library.sortOrder(of: FolderPath(string: "Work/Clients")) == SortOrder(.created))
        library.setSort(nil, for: FolderPath(string: "Work"))
        #expect(library.sortOrder(of: FolderPath(string: "Work/Clients")) == SortOrder(.title, reversed: true))

        await library.waitUntilIdle()
        #expect(settingsFile(folder)?.sort == .title)
        #expect(settingsFile(folder, "Work") == nil) // nothing left to keep: no file
        await library.rescanNow()
        #expect(library.sortOrder(of: FolderPath(string: "Work")) == SortOrder(.title, reversed: true))
    }

    @Test func unreadableSettingsAreLeftAlone() async throws {
        let folder = try TemporaryLibrary()
        try folder.write("A", to: "Work/A.md")
        let file = folder.notes.appendingPathComponent("Work/\(FolderSettings.fileName)")
        try Data(#"{"version": 9}"#.utf8).write(to: file)
        let (library, _) = await makeLibrary(folder)
        #expect(library.folderSettings[FolderPath(string: "Work")] == nil)
        #expect(library.sortOrder(of: FolderPath(string: "Work")) == .standard)
        try await library.rename(note("Work/A.md", in: library).id, to: "B")
        await library.waitUntilIdle()
        #expect(try String(contentsOf: file, encoding: .utf8) == #"{"version": 9}"#)
    }

    // MARK: Folders

    @Test func newFolderTakesAFreeName() async throws {
        let folder = try TemporaryLibrary()
        let (library, _) = await makeLibrary(folder)
        #expect(await library.newFolder() == FolderPath(string: "New Folder"))
        #expect(await library.newFolder() == FolderPath(string: "New Folder 2"))
        #expect(await library.newFolder(in: FolderPath(string: "New Folder"), named: "a/b: c") == FolderPath(string: "New Folder/a-b- c"))
        #expect(library.folders.map(\.string) == ["New Folder", "New Folder/a-b- c", "New Folder 2"])
    }

    @Test func renamingAFolderKeepsOpenEditedAndLockedNotes() async throws {
        let folder = try TemporaryLibrary()
        try folder.write("Open\nbody", to: "Work/Open.md")
        try folder.write("Locked\nsecret", to: "Work/Sub/Locked.md")
        try folder.write("Taken", to: "Taken/Other.md")
        let (library, editor) = await makeLibrary(folder, timing: .manual)
        let open = try note("Work/Open.md", in: library)
        let locked = try note("Work/Sub/Locked.md", in: library)
        try await library.setPassword("correct horse battery", hint: nil)
        try await library.lock(locked.id)
        library.selectedID = open.id
        editor.type("Open\nbody, unsaved", in: library)

        #expect(await library.renameFolder(FolderPath(string: "Work"), to: "Taken") == nil) // refused
        #expect(library.presentedError != nil)
        library.presentedError = nil

        let renamed = await library.renameFolder(FolderPath(string: "Work"), to: "Jobs")
        #expect(renamed == FolderPath(string: "Jobs"))
        #expect(open.relativePath == "Jobs/Open.md")
        #expect(locked.relativePath == "Jobs/Sub/Locked.mdlock")
        #expect(editor.displayedNoteID == open.id)
        #expect(folder.contents(of: "Jobs/Open.md") == "Open\nbody, unsaved")
        #expect(library.folders.map(\.string) == ["Jobs", "Jobs/Sub", "Taken"])

        // Saves after the rename land in the new place.
        editor.type("Open\nbody, later", in: library)
        await library.saveNow()
        #expect(folder.contents(of: "Jobs/Open.md") == "Open\nbody, later")
        await library.rescanNow()
        #expect(library.note(atPath: "Jobs/Open.md") === open)
        #expect(library.notes.count == 3)
    }

    @Test func movingAFolderIntoItselfOrOntoANameIsRefused() async throws {
        let folder = try TemporaryLibrary()
        try folder.write("A", to: "Work/Clients/A.md")
        try folder.makeFolder("Archive/Clients")
        let (library, _) = await makeLibrary(folder)

        #expect(await library.moveFolder(FolderPath(string: "Work"), into: FolderPath(string: "Work/Clients")) == nil)
        #expect(await library.moveFolder(FolderPath(string: "Work/Clients"), into: FolderPath(string: "Archive")) == nil)
        #expect(folder.filePaths == ["Work/Clients/A.md"])

        let undo = UndoManager()
        let moved = await library.moveFolder(FolderPath(string: "Work"), into: FolderPath(string: "Archive"), undoManager: undo)
        #expect(moved == FolderPath(string: "Archive/Work"))
        #expect(folder.filePaths == ["Archive/Work/Clients/A.md"])
        #expect(try note("Archive/Work/Clients/A.md", in: library).folder == FolderPath(string: "Archive/Work/Clients"))

        undo.undo()
        await library.waitUntilIdle()
        try await Task.sleep(for: .milliseconds(50))
        await library.waitUntilIdle()
        #expect(folder.filePaths == ["Work/Clients/A.md"])
    }

    @Test func trashingAFolderAndUndoing() async throws {
        let folder = try TemporaryLibrary()
        try folder.write("Inside\nbody", to: "Work/Inside.md")
        try folder.write("Not a note", to: "Work/image.png")
        try folder.write("Outside", to: "Outside.md")
        let (library, editor) = await makeLibrary(folder, timing: .manual)
        let inside = try note("Work/Inside.md", in: library)
        library.selectedID = inside.id
        editor.type("Inside\nlatest", in: library)
        #expect(await library.contentsCount(of: FolderPath(string: "Work")) == (1, 1))

        let receipt = try #require(await library.trashFolder(FolderPath(string: "Work")))
        #expect(folder.filePaths == ["Outside.md"])
        #expect(library.folders.isEmpty)
        #expect(!library.notes.contains { $0 === inside })
        #expect(folder.trashedCount == 1)

        await library.restoreFolder(receipt)
        #expect(folder.filePaths == ["Outside.md", "Work/Inside.md", "Work/image.png"])
        #expect(folder.contents(of: "Work/Inside.md") == "Inside\nlatest")
        #expect(library.note(atPath: "Work/Inside.md") != nil)
    }

    @Test func movingAFolderWithLockedNotesKeepsOtherNotesBackups() async throws {
        let folder = try TemporaryLibrary()
        try folder.write("Secret\nlocked", to: "Work/Secret.md")
        try folder.write("Secret\nplain words", to: "Secret.md")
        let (library, editor) = await makeLibrary(folder)
        try await library.setPassword("correct horse battery", hint: nil)
        try await library.lock(note("Work/Secret.md", in: library).id)
        await library.waitUntilIdle()
        await library.rescanNow() // the lock is known before the backup exists
        // Emptying the plain one keeps a backup of it.
        library.selectedID = try note("Secret.md", in: library).id
        editor.type("", in: library)
        await library.waitUntilIdle()
        let backups = { (try? FileManager.default.contentsOfDirectory(atPath: folder.backups.path)) ?? [] }
        #expect(backups().count == 1)

        _ = await library.renameFolder(FolderPath(string: "Work"), to: "Jobs")
        await library.waitUntilIdle()
        await library.rescanNow()
        #expect(library.note(atPath: "Jobs/Secret.mdlock") != nil)
        #expect(backups().count == 1)
    }

    @Test func aScanPutsANoteBackInTheFolderItsFileIsIn() async throws {
        let folder = try TemporaryLibrary()
        try folder.write("Stray", to: "Work/Stray.md")
        let (library, _) = await makeLibrary(folder)
        let stray = try note("Work/Stray.md", in: library)
        stray.folder = FolderPath(string: "Elsewhere") // out of step, as a race could leave it
        try folder.write("Stray, changed", to: "Work/Stray.md")
        await library.rescanNow()
        #expect(stray.folder == FolderPath(string: "Work"))
        #expect(library.note(atPath: "Work/Stray.md") === stray)
    }

    @Test func folderSettingsFollowARenameMadeWhileANoteWasRenamed() async throws {
        let folder = try TemporaryLibrary()
        try folder.write("Alpha", to: "Work/Alpha.md")
        try folder.write("Beta", to: "Work/Beta.md")
        let (library, _) = await makeLibrary(folder)
        let work = FolderPath(string: "Work")
        await library.place(.note(try note("Work/Beta.md", in: library)), in: work, at: 0)
        _ = await library.renameFolder(work, to: "Jobs")
        await library.waitUntilIdle()
        #expect(settingsFile(folder, "Jobs") == FolderSettings(sort: .manual, order: ["Beta", "Alpha"]))
        await library.rescanNow()
        #expect(library.folderSettings[FolderPath(string: "Jobs")]?.order == ["Beta", "Alpha"])
    }

    // MARK: Notes

    @Test func movingANoteKeepsItsEditorAndTakesAFreeName() async throws {
        let folder = try TemporaryLibrary()
        try folder.write("Plan\nmine", to: "Plan.md")
        try folder.write("Plan\ntheirs", to: "Work/Plan.md")
        let (library, editor) = await makeLibrary(folder, timing: .manual)
        let plan = try note("Plan.md", in: library)
        library.selectedID = plan.id
        editor.type("Plan\nmine, unsaved", in: library)

        let undo = UndoManager()
        #expect(await library.moveNote(plan.id, to: FolderPath(string: "Work"), undoManager: undo))
        #expect(plan.relativePath == "Work/Plan 2.md")
        #expect(editor.displayedNoteID == plan.id)
        #expect(folder.contents(of: "Work/Plan 2.md") == "Plan\nmine, unsaved")
        #expect(folder.contents(of: "Work/Plan.md") == "Plan\ntheirs")

        undo.undo()
        try await Task.sleep(for: .milliseconds(50))
        await library.waitUntilIdle()
        #expect(plan.folder == .root)
    }

    @Test func movingADraftOnlyChangesWhereItWillBeWritten() async throws {
        let folder = try TemporaryLibrary()
        try folder.makeFolder("Work")
        let (library, editor) = await makeLibrary(folder, timing: .manual)
        let draft = try #require(library.selectedNote)
        #expect(await library.moveNote(draft.id, to: FolderPath(string: "Work")))
        editor.type("Later\ntext", in: library)
        await library.saveNow()
        #expect(folder.filePaths == ["Work/Later.md"])
    }

    // MARK: Order

    @Test func placingInASortedFolderMakesItManualFromWhatItShowed() async throws {
        let folder = try TemporaryLibrary()
        for (index, name) in ["A", "B", "C"].enumerated() {
            try folder.write(name, to: "\(name).md")
            let date = Date(timeIntervalSince1970: 1_000_000 + Double(index) * 100)
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: folder.notes.appendingPathComponent("\(name).md").path)
        }
        let (library, _) = await makeLibrary(folder)
        let names: () -> [String] = { library.ordering.children(of: .root).compactMap(\.orderKey) }
        #expect(names() == ["C", "B", "A"]) // newest first

        let undo = UndoManager()
        await library.place(.note(try note("A.md", in: library)), in: .root, at: 0, undoManager: undo)
        #expect(names() == ["A", "C", "B"])
        #expect(library.sortOrder(of: .root).sort == .manual)
        await library.waitUntilIdle()
        #expect(settingsFile(folder) == FolderSettings(sort: .manual, order: ["A", "C", "B"]))

        await library.place(.note(try note("C.md", in: library)), in: .root, at: 3)
        #expect(names() == ["A", "B", "C"])

        // Another sort keeps the order for when Manual comes back.
        library.setSort(SortOrder(.title, reversed: true), for: .root)
        #expect(names() == ["C", "B", "A"])
        library.setSort(SortOrder(.manual), for: .root)
        #expect(names() == ["A", "B", "C"])

        undo.undo() // the first place: back to the sort it had
        #expect(library.sortOrder(of: .root) == .standard)
    }

    @Test func orderFollowsRenamesAndMoves() async throws {
        let folder = try TemporaryLibrary()
        try folder.write("Alpha", to: "Work/Alpha.md")
        try folder.write("Beta", to: "Work/Beta.md")
        try folder.makeFolder("Work/Sub")
        let (library, _) = await makeLibrary(folder)
        let work = FolderPath(string: "Work")
        await library.place(.folder(FolderPath(string: "Work/Sub")), in: work, at: 3)
        await library.place(.note(try note("Work/Beta.md", in: library)), in: work, at: 0)
        #expect(library.folderSettings[work]?.order == ["Beta", "Alpha", "Sub/"])

        await library.rename(try note("Work/Alpha.md", in: library).id, to: "Gamma")
        _ = await library.renameFolder(FolderPath(string: "Work/Sub"), to: "Deeper")
        #expect(library.folderSettings[work]?.order == ["Beta", "Gamma", "Deeper/"])

        // A newcomer to a manual folder goes where it was dropped.
        try folder.write("Outside", to: "Outside.md")
        await library.waitUntilIdle()
        await library.rescanNow()
        #expect(await library.moveNote(try note("Outside.md", in: library).id, to: work, at: 1))
        #expect(library.folderSettings[work]?.order == ["Beta", "Outside", "Gamma", "Deeper/"])
        #expect(await library.moveNote(try note("Work/Outside.md", in: library).id, to: .root))
        #expect(library.folderSettings[work]?.order == ["Beta", "Gamma", "Deeper/"])
    }

    @Test func settingsWritesAreNotTakenForOutsideChanges() async throws {
        let folder = try TemporaryLibrary()
        try folder.write("A", to: "Work/A.md")
        let (library, editor) = await makeLibrary(folder)
        let a = try note("Work/A.md", in: library)
        library.selectedID = a.id
        let reloads = editor.reloadCount
        library.setSort(SortOrder(.title), for: FolderPath(string: "Work"))
        await library.waitUntilIdle()
        await library.rescanNow()
        #expect(library.sortOrder(of: FolderPath(string: "Work")) == SortOrder(.title))
        #expect(editor.reloadCount == reloads)
        #expect(library.notes.count == 1)
    }
}

@MainActor
@Suite("Several items at once")
struct GroupCommandsTests {
    private func makeLibrary(_ folder: TemporaryLibrary) async -> Library {
        let library = Library(store: folder.makeStore(), timing: .fast, defaults: freshDefaults())
        library.attach(FakeEditor())
        await library.load()
        return library
    }

    @Test func itemsInsideAChosenFolderGoWithIt() async throws {
        let folder = try TemporaryLibrary()
        try folder.write("A", to: "Work/A.md")
        try folder.write("B", to: "B.md")
        let library = await makeLibrary(folder)
        let a = try #require(library.note(atPath: "Work/A.md"))
        let b = try #require(library.note(atPath: "B.md"))
        let items: [LibraryEntry] = [.note(a.id), .folder(FolderPath(string: "Work")), .note(b.id), .note(b.id)]
        #expect(library.outermost(items) == [.folder(FolderPath(string: "Work")), .note(b.id)])
    }

    @Test func movingSeveralAndUndoingInOneStep() async throws {
        let folder = try TemporaryLibrary()
        try folder.write("A", to: "A.md")
        try folder.write("B", to: "Work/B.md")
        try folder.write("C", to: "Clients/C.md")
        try folder.makeFolder("Archive")
        let library = await makeLibrary(folder)
        let a = try #require(library.note(atPath: "A.md"))
        let b = try #require(library.note(atPath: "Work/B.md"))
        let undo = UndoManager()
        let moved = await library.moveItems([.note(a.id), .note(b.id), .folder(FolderPath(string: "Clients")),
                                             .folder(FolderPath(string: "Archive"))],
                                            to: FolderPath(string: "Archive"), undoManager: undo)
        #expect(moved == 3) // Archive into itself is skipped
        #expect(folder.filePaths == ["Archive/A.md", "Archive/B.md", "Archive/Clients/C.md"])

        undo.undo()
        for _ in 0..<20 where folder.filePaths != ["A.md", "Clients/C.md", "Work/B.md"] {
            try await Task.sleep(for: .milliseconds(20))
            await library.waitUntilIdle()
        }
        #expect(folder.filePaths == ["A.md", "Clients/C.md", "Work/B.md"])
        #expect(!undo.canUndo)
    }

    @Test func trashingSeveralAndBringingThemBack() async throws {
        let folder = try TemporaryLibrary()
        try folder.write("A", to: "A.md")
        try folder.write("B", to: "Work/B.md")
        try folder.write("Keep", to: "Keep.md")
        let library = await makeLibrary(folder)
        let a = try #require(library.note(atPath: "A.md"))
        let undo = UndoManager()
        #expect(await library.trashItems([.note(a.id), .folder(FolderPath(string: "Work"))], undoManager: undo) == 2)
        #expect(folder.filePaths == ["Keep.md"])

        undo.undo()
        for _ in 0..<20 where folder.filePaths.count != 3 {
            try await Task.sleep(for: .milliseconds(20))
            await library.waitUntilIdle()
        }
        #expect(folder.filePaths == ["A.md", "Keep.md", "Work/B.md"])
    }
}
