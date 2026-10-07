import Foundation
import Testing
@testable import MinoteKit

/// A Markdown file opened from elsewhere (Finder, File ▸ Open…): its window's
/// library holds just that file and edits it in place.
@MainActor
@Suite("Opened file")
struct SingleFileLibraryTests {
    /// A folder outside the library with the opened file and a neighbor.
    private struct Elsewhere {
        let folder: TemporaryLibrary
        let directory: URL
        let file: URL

        init(_ text: String, name: String = "Readme.md") throws {
            folder = try TemporaryLibrary()
            directory = folder.root.appendingPathComponent("Downloads", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            file = directory.appendingPathComponent(name)
            try text.write(to: file, atomically: true, encoding: .utf8)
            try "not mine".write(to: directory.appendingPathComponent("Neighbor.md"), atomically: true, encoding: .utf8)
        }

        var backups: URL { folder.root.appendingPathComponent("Backups", isDirectory: true) }

        var fileNames: [String] {
            ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
        }

        var contents: String? { try? String(contentsOf: file, encoding: .utf8) }

        func write(_ text: String) throws {
            try text.write(to: file, atomically: true, encoding: .utf8)
        }
    }

    private func open(_ place: Elsewhere, timing: LibraryTiming = .fast, defaults: UserDefaults = freshDefaults()) async -> (Library, FakeEditor) {
        let store = NoteFileStore(file: place.file, backupDirectory: place.backups)
        let library = Library(store: store, timing: timing, defaults: defaults)
        let editor = FakeEditor()
        library.attach(editor)
        await library.load()
        return (library, editor)
    }

    private let slow = LibraryTiming(saveDebounce: .milliseconds(300), maxSaveLatency: .seconds(1), rescanDebounce: .milliseconds(10), retryDelay: .milliseconds(50))

    @Test func showsOnlyTheOpenedFile() async throws {
        let place = try Elsewhere("# Project\nNotes about it")
        let (library, editor) = await open(place)

        #expect(library.isSingleFile)
        #expect(library.notes.count == 1)
        #expect(library.selectedNote?.title == "Readme")
        #expect(editor.text == "# Project\nNotes about it")
        #expect(library.presentedError == nil)
    }

    @Test func editsAreSavedIntoTheSameFile() async throws {
        let place = try Elsewhere("Draft")
        let (library, editor) = await open(place)

        editor.type("A new first line\nand more", in: library)
        await library.waitUntilIdle()
        await library.saveNow()

        #expect(place.contents == "A new first line\nand more")
        #expect(place.fileNames == ["Neighbor.md", "Readme.md"])
    }

    @Test func aCopyOfAMinoteNoteIsStillNeverRenamed() async throws {
        let place = try Elsewhere("Readme\nbody")
        try ExtendedAttributes.set("Readme", named: NoteFileStore.autoNameAttribute, at: place.file)
        let (library, editor) = await open(place)
        #expect(library.selectedNote?.isAutoNamed == false)

        editor.type("Something else entirely\nbody", in: library)
        await library.saveNow()

        #expect(place.fileNames == ["Neighbor.md", "Readme.md"])
        #expect(place.contents == "Something else entirely\nbody")
    }

    @Test func emptyingTheFileKeepsItAndBacksItUp() async throws {
        let place = try Elsewhere("Keep a copy of me")
        let (library, editor) = await open(place)

        editor.type("", in: library)
        await library.prepareForTermination()

        #expect(place.fileNames == ["Neighbor.md", "Readme.md"])
        #expect(place.contents == "")
        let backups = try FileManager.default.contentsOfDirectory(atPath: place.backups.path)
        #expect(backups.count == 1)
    }

    @Test func outsideChangesReloadTheWindow() async throws {
        let place = try Elsewhere("v1")
        let (library, editor) = await open(place)

        try await Task.sleep(for: .milliseconds(20)) // distinct modification date
        try place.write("v2 from vim")
        await library.rescanNow()

        #expect(editor.text == "v2 from vim")
        #expect(editor.reloadCount == 1)
        #expect(library.notes.count == 1)
    }

    @Test func unsavedEditsWinOverOutsideChanges() async throws {
        let place = try Elsewhere("v1")
        let (library, editor) = await open(place, timing: slow)

        editor.type("local edit", in: library)
        try place.write("outside edit")
        await library.rescanNow()
        #expect(editor.text == "local edit")

        await library.waitUntilIdle()
        #expect(place.contents == "local edit")
    }

    @Test func deletedWhileTypingIsWrittenBackToTheSamePlace() async throws {
        let place = try Elsewhere("Fragile")
        let (library, editor) = await open(place, timing: slow)

        editor.type("Fragile\nunsaved words", in: library)
        try FileManager.default.removeItem(at: place.file)
        await library.rescanNow()
        await library.waitUntilIdle()

        #expect(place.fileNames == ["Neighbor.md", "Readme.md"])
        #expect(place.contents == "Fragile\nunsaved words")
        #expect(library.notes.count == 1)
    }

    @Test func deletedWithoutEditsKeepsTheWindowAndWritesNothing() async throws {
        let place = try Elsewhere("Clean")
        let (library, editor) = await open(place)

        try FileManager.default.removeItem(at: place.file)
        await library.rescanNow()
        await library.waitUntilIdle()

        #expect(place.fileNames == ["Neighbor.md"])
        #expect(library.notes.count == 1)
        #expect(editor.displayedNoteID == library.selectedID)
        #expect(editor.text == "Clean")
    }

    @Test func leavesTheLibrarysLastOpenedNoteAlone() async throws {
        let place = try Elsewhere("Mine")
        let defaults = freshDefaults()
        defaults.set("Library note.md", forKey: Library.selectionKey)
        let (library, editor) = await open(place, defaults: defaults)

        editor.type("Mine, edited", in: library)
        await library.saveNow()

        #expect(defaults.string(forKey: Library.selectionKey) == "Library note.md")
    }

    @Test func libraryCommandsDoNothing() async throws {
        let place = try Elsewhere("Only me")
        let (library, _) = await open(place)
        let id = try #require(library.selectedID)

        library.newNote()
        await library.rename(id, to: "Other name")
        await library.duplicate(id)
        let receipt = await library.moveToTrash(id)
        await library.waitUntilIdle()

        #expect(receipt == nil)
        #expect(library.notes.count == 1)
        #expect(library.selectedID == id)
        #expect(place.fileNames == ["Neighbor.md", "Readme.md"])
    }

    @Test func aMissingFileReportsAnError() async throws {
        let place = try Elsewhere("Soon gone")
        try FileManager.default.removeItem(at: place.file)
        let (library, editor) = await open(place)

        #expect(library.notes.isEmpty)
        #expect(library.selectedID == nil)
        #expect(editor.displayedNoteID == nil)
        #expect(library.presentedError?.title == "Couldn't open “Readme.md”")
    }
}
