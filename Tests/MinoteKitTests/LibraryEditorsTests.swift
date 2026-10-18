import Foundation
import Testing
@testable import MinoteKit

/// The library with several editors at once: one per tab on the Mac.
@MainActor
@Suite("Library with tabs")
struct LibraryEditorsTests {
    /// A loaded library over `folder` with one editor attached.
    private func makeLibrary(_ folder: TemporaryLibrary, timing: LibraryTiming = .fast,
                             defaults: UserDefaults = freshDefaults()) async -> (Library, FakeEditor) {
        let library = Library(store: folder.makeStore(), timing: timing, defaults: defaults)
        let editor = FakeEditor()
        library.attach(editor)
        await library.load()
        return (library, editor)
    }

    private func note(_ title: String, in library: Library) throws -> Note {
        try #require(library.notes.first { $0.title == title })
    }

    @Test func eachEditorShowsItsOwnNote() async throws {
        let folder = try TemporaryLibrary()
        try folder.write("A", to: "A.md")
        try folder.write("B", to: "B.md")
        let (library, first) = await makeLibrary(folder)
        let a = try note("A", in: library)
        let b = try note("B", in: library)
        library.selectedID = a.id

        let second = FakeEditor()
        #expect(library.show(b.id, in: second))
        #expect(first.displayedNoteID == a.id)
        #expect(second.displayedNoteID == b.id)
        #expect(library.selectedID == b.id)
        #expect(library.editor === second)

        // The first window comes forward: the selection follows, nothing is redisplayed.
        library.activate(first)
        #expect(library.selectedID == a.id)
        #expect(library.editor === first)
        #expect(second.displayedNoteID == b.id)
    }

    @Test func aNoteIsNeverShownInTwoEditors() async throws {
        let folder = try TemporaryLibrary()
        try folder.write("A", to: "A.md")
        let (library, first) = await makeLibrary(folder)
        let a = try note("A", in: library)

        let second = FakeEditor()
        #expect(!library.show(a.id, in: second))
        #expect(second.displayedNoteID == nil)
        #expect(first.displayedNoteID == a.id)
        #expect(library.editor(showing: a.id) === first)
    }

    @Test func settingTheSelectionToANoteShownElsewhereBringsThatEditorForward() async throws {
        let folder = try TemporaryLibrary()
        try folder.write("A", to: "A.md")
        try folder.write("B", to: "B.md")
        let (library, first) = await makeLibrary(folder)
        let a = try note("A", in: library)
        let b = try note("B", in: library)
        library.selectedID = a.id
        let second = FakeEditor()
        library.show(b.id, in: second)

        library.selectedID = a.id
        #expect(library.editor === first)
        #expect(first.displayedNoteID == a.id)
        #expect(second.displayedNoteID == b.id)
    }

    @Test func aBlankDraftInABackgroundTabStaysUntilItsTabCloses() async throws {
        let folder = try TemporaryLibrary()
        try folder.write("A", to: "A.md")
        let (library, first) = await makeLibrary(folder)
        let draft = try #require(library.makeDraft())
        let second = FakeEditor()
        library.show(draft, in: second)

        library.activate(first)
        await library.waitUntilIdle()
        #expect(library.note(with: draft) != nil)

        library.detach(second)
        await library.waitUntilIdle()
        #expect(library.note(with: draft) == nil)
        #expect(folder.fileNames == ["A.md"])
    }

    @Test func replacingANoteInATabWrapsItUp() async throws {
        let folder = try TemporaryLibrary()
        try folder.write("A", to: "A.md")
        let (library, first) = await makeLibrary(folder)
        let a = try note("A", in: library)
        let draft = try #require(library.makeDraft())
        let second = FakeEditor()
        library.show(draft, in: second)

        // The draft's tab moves on to something else: the blank draft goes.
        library.show(nil, in: second)
        library.activate(first)
        await library.waitUntilIdle()
        #expect(library.note(with: draft) == nil)
        #expect(first.displayedNoteID == a.id)
    }

    @Test func anEmptiedNoteIsTrashedWhenItsLastTabCloses() async throws {
        let folder = try TemporaryLibrary()
        try folder.write("Other", to: "Other.md")
        let (library, first) = await makeLibrary(folder)
        let other = try note("Other", in: library)
        let draft = try #require(library.makeDraft())
        library.show(draft, in: first)
        first.type("Short lived\nbody", in: library)
        await library.waitUntilIdle()
        #expect(folder.fileNames == ["Other.md", "Short lived.md"])

        first.type("", in: library)
        let second = FakeEditor()
        library.show(other.id, in: second)
        await library.waitUntilIdle()
        // Still open in the first tab: kept.
        #expect(folder.fileNames == ["Other.md", "Short lived.md"])

        library.detach(first)
        await library.waitUntilIdle()
        #expect(folder.fileNames == ["Other.md"])
        #expect(folder.trashedCount == 1)
    }

    @Test func aBackgroundTabsTextIsSaved() async throws {
        let folder = try TemporaryLibrary()
        try folder.write("A\nold", to: "A.md")
        try folder.write("B", to: "B.md")
        let (library, first) = await makeLibrary(folder, timing: .manual)
        let a = try note("A", in: library)
        let b = try note("B", in: library)
        library.selectedID = a.id

        first.type("A\nwritten in the first tab", in: library)
        let second = FakeEditor()
        library.show(b.id, in: second)
        await library.saveNow()

        #expect(folder.contents(of: "A.md") == "A\nwritten in the first tab")
        #expect(!library.hasUnsavedChanges)
    }

    @Test func aBackgroundTabStillWaitsForTheTitleBeforeRenaming() async throws {
        let folder = try TemporaryLibrary()
        try folder.write("B", to: "B.md")
        let (library, first) = await makeLibrary(folder)
        let b = try note("B", in: library)
        let draft = try #require(library.makeDraft())
        library.show(draft, in: first)
        first.type("Hel", in: library)
        await library.waitUntilIdle()

        let second = FakeEditor()
        library.show(b.id, in: second)
        first.type("Hello", in: library) // caret still on the title line, in the background tab
        await library.waitUntilIdle()
        #expect(folder.fileNames == ["B.md", "Hel.md"])
    }

    @Test func anOutsideChangeReloadsTheTabShowingIt() async throws {
        let folder = try TemporaryLibrary()
        try folder.write("A\nv1", to: "A.md")
        try folder.write("B", to: "B.md")
        let (library, first) = await makeLibrary(folder)
        let a = try note("A", in: library)
        let b = try note("B", in: library)
        library.selectedID = a.id
        let second = FakeEditor()
        library.show(b.id, in: second)

        try await Task.sleep(for: .milliseconds(20)) // distinct modification date
        try folder.write("A\nv2 from vim", to: "A.md")
        await library.rescanNow()

        #expect(first.text == "A\nv2 from vim")
        #expect(first.reloadCount == 1)
        #expect(second.reloadCount == 0)
    }

    @Test func aRemovedNoteClosesItsTabWhenTheHandlerSaysSo() async throws {
        let folder = try TemporaryLibrary()
        try folder.write("A", to: "A.md")
        try folder.write("B", to: "B.md")
        let (library, first) = await makeLibrary(folder)
        let a = try note("A", in: library)
        let b = try note("B", in: library)
        library.selectedID = a.id
        let second = FakeEditor()
        library.show(b.id, in: second)

        var asked: [FakeEditor] = []
        library.shownNoteRemovedHandler = { editor in
            asked.append(editor as! FakeEditor)
            library.detach(editor)
            return true
        }
        await library.moveToTrash(a.id)

        #expect(asked.count == 1 && asked.first === first)
        #expect(library.editor === second)
        #expect(library.selectedID == b.id)
        #expect(folder.fileNames == ["B.md"])
    }

    @Test func otherwiseItShowsANoteNoOtherTabShows() async throws {
        let folder = try TemporaryLibrary()
        try folder.write("A", to: "A.md")
        try await Task.sleep(for: .milliseconds(20))
        try folder.write("B", to: "B.md")
        try await Task.sleep(for: .milliseconds(20))
        try folder.write("C", to: "C.md")
        let (library, first) = await makeLibrary(folder)
        // Newest first: C, B, A. B's neighbor is A, but A is in the first tab.
        let a = try note("A", in: library)
        let b = try note("B", in: library)
        library.selectedID = a.id
        let second = FakeEditor()
        library.show(b.id, in: second)

        await library.moveToTrash(b.id)
        #expect(first.displayedNoteID == a.id)
        #expect(second.displayedNoteID == (try note("C", in: library)).id)
    }

    @Test func userOpensGoThroughTheHandler() async throws {
        let folder = try TemporaryLibrary()
        try folder.write("A\nsee [B](B.md)", to: "A.md")
        try folder.write("B", to: "B.md")
        let (library, _) = await makeLibrary(folder)
        let a = try note("A", in: library)
        let b = try note("B", in: library)
        library.selectedID = a.id

        var opened: [Note.ID] = []
        library.openHandler = { opened.append($0) }
        #expect(library.followLink(to: "B.md") == nil)
        library.newNote()

        #expect(opened.first == b.id)
        #expect(opened.count == 2)
        #expect(library.note(with: opened[1])?.isDraft == true)
        #expect(library.selectedID == a.id)
    }

    @Test func eachTabKeepsItsNoteWhenTheLibraryMoves() async throws {
        let from = try TemporaryLibrary()
        let to = try TemporaryLibrary()
        try from.write("A", to: "A.md")
        try from.write("B", to: "B.md")
        let (library, first) = await makeLibrary(from, timing: .manual)
        let a = try note("A", in: library)
        let b = try note("B", in: library)
        library.selectedID = a.id
        let second = FakeEditor()
        library.show(b.id, in: second)

        await library.relocate(to: to.makeStore(), watcher: nil, movingNotes: true)

        #expect(to.fileNames == ["A.md", "B.md"])
        #expect(first.displayedNoteID == (try note("A", in: library)).id)
        #expect(second.displayedNoteID == (try note("B", in: library)).id)
        #expect(library.editor === second)
        #expect(library.selectedNote?.title == "B")
    }
}
