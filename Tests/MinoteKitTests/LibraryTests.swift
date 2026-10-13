import Foundation
import Testing
@testable import MinoteKit

/// Where the notes under test live: the library folder, or one file of it
/// opened from elsewhere (Finder, File ▸ Open…) in its own window.
enum Place: CaseIterable, Sendable {
    case library, openedFile
}

@MainActor
@Suite("Library")
struct LibraryTests {
    /// A loaded library over a temporary folder, or over just its file `name`,
    /// with a fake editor attached.
    private func makeLibrary(_ folder: TemporaryLibrary, _ place: Place = .library, file name: String = "",
                             timing: LibraryTiming = .fast, defaults: UserDefaults = freshDefaults()) async -> (Library, FakeEditor) {
        let store = place == .library ? folder.makeStore()
            : NoteFileStore(file: folder.notes.appendingPathComponent(name), backupDirectory: folder.backups)
        let library = Library(store: store, timing: timing, defaults: defaults)
        let editor = FakeEditor()
        library.attach(editor)
        await library.load()
        return (library, editor)
    }

    @Test func emptyLibraryStartsWithADraftAndWritesNothing() async throws {
        let folder = try TemporaryLibrary()
        let (library, editor) = await makeLibrary(folder)

        #expect(library.notes.count == 1)
        #expect(library.selectedNote?.isDraft == true)
        #expect(editor.displayedNoteID == library.selectedID)

        editor.type("   \n", in: library)
        await library.waitUntilIdle()
        #expect(folder.fileNames.isEmpty)

        editor.type("Hello", in: library)
        await library.waitUntilIdle()
        #expect(folder.fileNames == ["Hello.md"])
        #expect(folder.contents(of: "Hello.md") == "Hello")
        #expect(library.selectedNote?.isDraft == false)
    }

    @Test func emptyDraftDisappearsWhenLeft() async throws {
        let folder = try TemporaryLibrary()
        try folder.write("Existing\nbody", to: "Existing.md")
        let (library, _) = await makeLibrary(folder)
        let existing = try #require(library.notes.first)

        library.newNote()
        #expect(library.notes.count == 2)
        library.selectedID = existing.id
        await library.waitUntilIdle()

        #expect(library.notes.count == 1)
        #expect(folder.fileNames == ["Existing.md"])
    }

    @Test func newNoteReusesTheCurrentEmptyDraft() async throws {
        let folder = try TemporaryLibrary()
        let (library, editor) = await makeLibrary(folder)
        let draft = library.selectedID
        let focusBefore = editor.focusCount

        library.newNote()
        #expect(library.selectedID == draft)
        #expect(library.notes.count == 1)
        #expect(editor.focusCount == focusBefore + 1)
    }

    @Test func renamesWhenTheTitleIsDoneNotWhileTyping() async throws {
        let folder = try TemporaryLibrary()
        let (library, editor) = await makeLibrary(folder)

        editor.type("Hel", in: library)
        await library.waitUntilIdle()
        #expect(folder.fileNames == ["Hel.md"])

        // Still typing the title: the file keeps its name.
        editor.type("Hello world", in: library)
        await library.waitUntilIdle()
        #expect(folder.fileNames == ["Hel.md"])
        #expect(library.selectedNote?.title == "Hello world")

        // The caret moved on to the body: the file follows the title.
        editor.type("Hello world\nBody", in: library)
        await library.waitUntilIdle()
        #expect(folder.fileNames == ["Hello world.md"])
        #expect(folder.contents(of: "Hello world.md") == "Hello world\nBody")
    }

    @Test func renamesWhenLeavingTheNote() async throws {
        let folder = try TemporaryLibrary()
        try folder.write("Other", to: "Other.md")
        let (library, editor) = await makeLibrary(folder)
        let other = try #require(library.notes.first)

        library.newNote()
        editor.type("Sea", in: library)
        await library.waitUntilIdle()
        editor.type("Seasons", in: library) // caret still on the title line
        library.selectedID = other.id
        await library.waitUntilIdle()

        #expect(folder.fileNames == ["Other.md", "Seasons.md"])
    }

    @Test func continuousTypingStillSaves() async throws {
        let folder = try TemporaryLibrary()
        let timing = LibraryTiming(
            saveDebounce: .milliseconds(150),
            maxSaveLatency: .milliseconds(250),
            rescanDebounce: .milliseconds(10),
            retryDelay: .milliseconds(50)
        )
        let (library, editor) = await makeLibrary(folder, timing: timing)

        var text = "Typing\n"
        for _ in 0..<40 {
            text += "x"
            editor.type(text, in: library)
            try await Task.sleep(for: .milliseconds(20))
        }
        // Keystrokes never paused for 150 ms, yet the 250 ms cap forced saves.
        let saved = try #require(folder.contents(of: "Typing.md"))
        #expect(saved.hasPrefix("Typing\nx"))
        await library.waitUntilIdle()
        #expect(folder.contents(of: "Typing.md") == text)
    }

    // MARK: Outside changes, in the library and in an opened file

    @Test(arguments: Place.allCases)
    func outsideChangesReloadTheOpenNote(_ place: Place) async throws {
        let folder = try TemporaryLibrary()
        try folder.write("Shared\nv1", to: "Shared.md")
        let (library, editor) = await makeLibrary(folder, place, file: "Shared.md")
        #expect(editor.text == "Shared\nv1")
        #expect(library.isSingleFile == (place == .openedFile))

        try await Task.sleep(for: .milliseconds(20)) // distinct modification date
        try folder.write("Shared\nv2 from vim", to: "Shared.md")
        try folder.write("Brand new", to: "New file.md")
        await library.rescanNow()

        #expect(editor.text == "Shared\nv2 from vim")
        #expect(editor.reloadCount == 1)
        // An opened file's window shows that file alone.
        #expect(library.notes.map(\.title).sorted() == (place == .library ? ["New file", "Shared"] : ["Shared"]))
    }

    @Test(arguments: Place.allCases)
    func unsavedEditsWinOverOutsideChanges(_ place: Place) async throws {
        let folder = try TemporaryLibrary()
        try folder.write("Mine\nv1", to: "Mine.md")
        let (library, editor) = await makeLibrary(folder, place, file: "Mine.md", timing: .slow)

        editor.type("Mine\nlocal edit", in: library)
        try folder.write("Mine\noutside edit", to: "Mine.md")
        await library.rescanNow()
        #expect(editor.text == "Mine\nlocal edit")
        #expect(editor.reloadCount == 0)

        await library.waitUntilIdle()
        #expect(folder.contents(of: "Mine.md") == "Mine\nlocal edit")
    }

    @Test(arguments: Place.allCases)
    func deletedWhileTypingIsWrittenAgain(_ place: Place) async throws {
        let folder = try TemporaryLibrary()
        try folder.write("Fragile\nv1", to: "Fragile.md")
        let (library, editor) = await makeLibrary(folder, place, file: "Fragile.md", timing: .slow)

        editor.type("Fragile\nunsaved words", in: library)
        try FileManager.default.removeItem(at: folder.notes.appendingPathComponent("Fragile.md"))
        await library.rescanNow()
        await library.waitUntilIdle()

        #expect(folder.fileNames == ["Fragile.md"])
        #expect(folder.contents(of: "Fragile.md") == "Fragile\nunsaved words")
        #expect(library.notes.count == 1)
    }

    @Test func outsideDeletionOfACleanNoteRemovesIt() async throws {
        let folder = try TemporaryLibrary()
        try folder.write("A", to: "A.md")
        try folder.write("B", to: "B.md")
        let (library, _) = await makeLibrary(folder)
        #expect(library.notes.count == 2)

        try FileManager.default.removeItem(at: folder.notes.appendingPathComponent("A.md"))
        await library.rescanNow()
        #expect(library.notes.map(\.title) == ["B"])
    }

    @Test func filesMinoteDidNotCreateAreNeverRenamed() async throws {
        let folder = try TemporaryLibrary()
        try folder.write("Original first line\nbody", to: "My own name.md")
        let (library, editor) = await makeLibrary(folder)
        #expect(library.selectedNote?.title == "My own name")

        editor.type("A different first line\nbody", in: library)
        library.newNote() // leave the note
        await library.waitUntilIdle()

        #expect(folder.fileNames == ["My own name.md"])
        #expect(folder.contents(of: "My own name.md") == "A different first line\nbody")
    }

    @Test func manualRenameStopsAutoNaming() async throws {
        let folder = try TemporaryLibrary()
        let (library, editor) = await makeLibrary(folder)
        editor.type("Auto\nbody", in: library)
        await library.waitUntilIdle()
        #expect(folder.fileNames == ["Auto.md"])

        try FileManager.default.moveItem(at: folder.notes.appendingPathComponent("Auto.md"),
                                         to: folder.notes.appendingPathComponent("Chosen by me.md"))
        await library.rescanNow()
        let note = try #require(library.notes.first { $0.fileURL?.lastPathComponent == "Chosen by me.md" })
        #expect(!note.isAutoNamed)
    }

    @Test func renamingToANameWithAnExtensionDoesNotDoubleIt() async throws {
        let folder = try TemporaryLibrary()
        let (library, editor) = await makeLibrary(folder)
        editor.type("Draft\nbody", in: library)
        await library.waitUntilIdle()
        await library.rename(try #require(library.selectedID), to: "Ideas.md")
        #expect(folder.fileNames == ["Ideas.md"])
    }

    @Test func emptiedNoteKeepsItsNameAndIsTrashedWhenLeft() async throws {
        let folder = try TemporaryLibrary()
        let (library, editor) = await makeLibrary(folder)
        editor.type("Short lived\nbody", in: library)
        await library.waitUntilIdle()
        #expect(folder.fileNames == ["Short lived.md"])

        editor.type("", in: library)
        await library.waitUntilIdle()
        #expect(folder.fileNames == ["Short lived.md"]) // not renamed to "Untitled"

        library.newNote()
        await library.waitUntilIdle()
        #expect(folder.fileNames.isEmpty)
        #expect(folder.trashedCount == 1)
    }

    @Test func trashAndUndo() async throws {
        let folder = try TemporaryLibrary()
        try folder.write("Keep me\nplease", to: "Keep me.md")
        try folder.write("Other", to: "Other.md")
        let (library, _) = await makeLibrary(folder)
        let keep = try #require(library.notes.first { $0.title == "Keep me" })
        library.selectedID = keep.id

        let receipt = try #require(await library.moveToTrash(keep.id))
        #expect(folder.fileNames == ["Other.md"])
        #expect(library.selectedNote?.title == "Other")

        await library.restore(receipt)
        #expect(folder.fileNames == ["Keep me.md", "Other.md"])
        #expect(library.selectedNote?.title == "Keep me")
    }

    @Test func trashingTheLastNoteStartsADraft() async throws {
        let folder = try TemporaryLibrary()
        try folder.write("Only", to: "Only.md")
        let (library, _) = await makeLibrary(folder)

        let only = try #require(library.selectedID)
        await library.moveToTrash(only)
        #expect(library.notes.count == 1)
        #expect(library.selectedNote?.isDraft == true)
        #expect(folder.fileNames.isEmpty)
    }

    @Test func pendingEditsAreWrittenBeforeTrashing() async throws {
        let folder = try TemporaryLibrary()
        try folder.write("Draft\nold", to: "Draft.md")
        let (library, editor) = await makeLibrary(folder, timing: .manual)

        editor.type("Draft\nnewest words", in: library)
        let draft = try #require(library.selectedID)
        let receipt = try #require(await library.moveToTrash(draft))
        #expect(try String(contentsOf: receipt.trashedURL, encoding: .utf8) == "Draft\nnewest words")
    }

    @Test func saveNowFlushesBeforeTheDebounce() async throws {
        let folder = try TemporaryLibrary()
        let (library, editor) = await makeLibrary(folder, timing: .manual)

        editor.type("Quit soon\nlast words", in: library)
        await library.prepareForTermination()
        #expect(folder.contents(of: "Quit soon.md") == "Quit soon\nlast words")
        #expect(!library.hasUnsavedChanges)
    }

    @Test func lastOpenedNoteIsRestored() async throws {
        let folder = try TemporaryLibrary()
        try folder.write("First", to: "First.md")
        try await Task.sleep(for: .milliseconds(20))
        try folder.write("Second", to: "Second.md")
        let defaults = freshDefaults()

        let (library, _) = await makeLibrary(folder, defaults: defaults)
        let first = try #require(library.notes.first { $0.title == "First" })
        library.selectedID = first.id
        await library.waitUntilIdle()

        let (reopened, _) = await makeLibrary(folder, defaults: defaults)
        #expect(reopened.selectedNote?.title == "First")
    }

    @Test func relocatingMovesNotesAndReloads() async throws {
        let from = try TemporaryLibrary()
        let to = try TemporaryLibrary()
        try from.write("Kept\nbody", to: "Kept.md")
        try to.write("Already there", to: "Kept.md")
        let (library, editor) = await makeLibrary(from, timing: .manual)

        editor.type("Kept\nunsaved edit", in: library)
        await library.relocate(to: to.makeStore(), watcher: nil, movingNotes: true)

        #expect(from.fileNames.isEmpty)
        #expect(to.fileNames == ["Kept 2.md", "Kept.md"])
        #expect(to.contents(of: "Kept 2.md") == "Kept\nunsaved edit")
        #expect(library.notes.count == 2)
        #expect(library.directory == to.makeStore().directory)
    }

    @Test func searchMatchesTitleAndBody() async throws {
        let folder = try TemporaryLibrary()
        try folder.write("Recipes\nflour and sugar", to: "Recipes.md")
        try folder.write("Travel\nTashkent in spring", to: "Travel.md")
        let (library, _) = await makeLibrary(folder)

        library.searchText = "tashkent"
        #expect(library.visibleNotes.map(\.title) == ["Travel"])
        library.searchText = "RECIPES"
        #expect(library.visibleNotes.map(\.title) == ["Recipes"])
        library.searchText = ""
        #expect(library.visibleNotes.count == 2)
    }

    // MARK: An opened file

    /// A folder with "Readme.md" and a neighbor; `prepare` runs before the readme is opened alone.
    private func openReadme(_ text: String, defaults: UserDefaults = freshDefaults(),
                            prepare: (URL) throws -> Void = { _ in }) async throws -> (TemporaryLibrary, Library, FakeEditor) {
        let folder = try TemporaryLibrary()
        try folder.write(text, to: "Readme.md")
        try folder.write("not mine", to: "Neighbor.md")
        try prepare(folder.notes.appendingPathComponent("Readme.md"))
        let (library, editor) = await makeLibrary(folder, .openedFile, file: "Readme.md", defaults: defaults)
        return (folder, library, editor)
    }

    @Test func aCopyOfAMinoteNoteIsStillNeverRenamed() async throws {
        let (folder, library, editor) = try await openReadme("Readme\nbody") {
            try ExtendedAttributes.set("Readme", named: NoteFileStore.autoNameAttribute, at: $0)
        }
        #expect(library.selectedNote?.isAutoNamed == false)

        editor.type("Something else entirely\nbody", in: library)
        await library.saveNow()

        #expect(folder.fileNames == ["Neighbor.md", "Readme.md"])
        #expect(folder.contents(of: "Readme.md") == "Something else entirely\nbody")
    }

    @Test func emptyingTheFileKeepsItAndBacksItUp() async throws {
        let (folder, library, editor) = try await openReadme("Keep a copy of me")

        editor.type("", in: library)
        await library.prepareForTermination()

        #expect(folder.fileNames == ["Neighbor.md", "Readme.md"])
        #expect(folder.contents(of: "Readme.md") == "")
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.backups.path).count == 1)
    }

    @Test func deletedWithoutEditsKeepsTheWindowAndWritesNothing() async throws {
        let (folder, library, editor) = try await openReadme("Clean")

        try FileManager.default.removeItem(at: folder.notes.appendingPathComponent("Readme.md"))
        await library.rescanNow()
        await library.waitUntilIdle()

        #expect(folder.fileNames == ["Neighbor.md"])
        #expect(library.notes.count == 1)
        #expect(editor.displayedNoteID == library.selectedID)
        #expect(editor.text == "Clean")
    }

    @Test func leavesTheLibrarysLastOpenedNoteAlone() async throws {
        let defaults = freshDefaults()
        defaults.set("Library note.md", forKey: Library.selectionKey)
        let (_, library, editor) = try await openReadme("Mine", defaults: defaults)

        editor.type("Mine, edited", in: library)
        await library.saveNow()

        #expect(defaults.string(forKey: Library.selectionKey) == "Library note.md")
    }

    @Test func libraryCommandsDoNothing() async throws {
        let (folder, library, _) = try await openReadme("Only me")
        let id = try #require(library.selectedID)

        library.newNote()
        await library.rename(id, to: "Other name")
        await library.duplicate(id)
        let receipt = await library.moveToTrash(id)
        await library.waitUntilIdle()

        #expect(receipt == nil)
        #expect(library.notes.count == 1)
        #expect(library.selectedID == id)
        #expect(folder.fileNames == ["Neighbor.md", "Readme.md"])
    }

    @Test func aMissingFileReportsAnError() async throws {
        let (_, library, editor) = try await openReadme("Soon gone") { try FileManager.default.removeItem(at: $0) }

        #expect(library.notes.isEmpty)
        #expect(library.selectedID == nil)
        #expect(editor.displayedNoteID == nil)
        #expect(library.presentedError?.title == "Couldn't open “Readme.md”")
    }
}
