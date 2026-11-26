import Foundation
import Testing
@testable import MinoteKit

/// Notes in folders below the library folder: found, kept apart by path,
/// written where they live.
@MainActor
@Suite("Notes in folders")
struct FolderLibraryTests {
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

    // MARK: Paths

    @Test func folderPathsRebaseAndCompare() {
        let work = FolderPath(string: "Work")
        let clients = FolderPath(string: "Work/Clients")
        #expect(work.isAncestor(of: clients))
        #expect(!clients.isAncestor(of: work))
        #expect(!work.isAncestor(of: work))
        #expect(work.contains(work))
        #expect(clients.parent == work)
        #expect(FolderPath.root.parent == nil)
        #expect(work.rebasing(clients, onto: FolderPath(string: "Jobs")) == FolderPath(string: "Jobs/Clients"))
        #expect(work.rebasing(FolderPath(string: "Home"), onto: FolderPath(string: "Jobs")) == FolderPath(string: "Home"))
        #expect(clients.relativePath(ofFile: "A.md") == "Work/Clients/A.md")
        #expect(FolderPath.root.relativePath(ofFile: "A.md") == "A.md")
        #expect(FolderPath(string: "/Work//Clients/") == clients)
        let root = URL(fileURLWithPath: "/tmp/lib", isDirectory: true)
        #expect(FolderPath(folderOf: root.appendingPathComponent("Work/Clients/A.md"), root: root) == clients)
        #expect(FolderPath(folderOf: URL(fileURLWithPath: "/elsewhere/A.md"), root: root) == nil)
    }

    // MARK: Scanning

    @Test func scanFindsNotesAndFoldersAllTheWayDown() async throws {
        let folder = try TemporaryLibrary()
        try folder.write("Top", to: "Top.md")
        try folder.write("Deep", to: "Work/Clients/Deep.md")
        try folder.makeFolder("Empty")
        try folder.write("Hidden", to: ".git/Hidden.md")
        try folder.write("Inside a package", to: "Bundle.app/Inside.md")
        try folder.write("Not a note", to: "Work/picture.png")
        try FileManager.default.createSymbolicLink(at: folder.notes.appendingPathComponent("Link"),
                                                   withDestinationURL: folder.notes.appendingPathComponent("Work"))

        let result = try await folder.makeStore().scanTree(known: [:])
        let found = result.files.map { $0.folder.relativePath(ofFile: $0.url.lastPathComponent) }.sorted()
        #expect(found == ["Top.md", "Work/Clients/Deep.md"])
        #expect(result.folders.map(\.path.string).sorted() == ["Empty", "Work", "Work/Clients"])

        let (library, _) = await makeLibrary(folder)
        #expect(library.folders.map(\.string) == ["Empty", "Work", "Work/Clients"])
        #expect(try note("Work/Clients/Deep.md", in: library).folder == FolderPath(string: "Work/Clients"))
    }

    @Test func sameNameInTwoFoldersStaysTwoNotes() async throws {
        let folder = try TemporaryLibrary()
        try folder.write("Ideas\nat the top", to: "Ideas.md")
        try folder.write("Ideas\nfor work", to: "Work/Ideas.md")
        let (library, editor) = await makeLibrary(folder)
        #expect(library.notes.count == 2)

        let work = try note("Work/Ideas.md", in: library)
        library.selectedID = work.id
        editor.type("Ideas\nfor work, edited", in: library)
        await library.waitUntilIdle()
        #expect(folder.contents(of: "Work/Ideas.md") == "Ideas\nfor work, edited")
        #expect(folder.contents(of: "Ideas.md") == "Ideas\nat the top")
        #expect(folder.filePaths == ["Ideas.md", "Work/Ideas.md"])
    }

    // MARK: Writing in the note's folder

    @Test func renamingDuplicatingAndLockingStayInTheFolder() async throws {
        let folder = try TemporaryLibrary()
        try folder.write("Taken", to: "Work/Plan.md")
        try folder.write("Draft plan\nbody", to: "Work/Draft.md")
        let (library, editor) = await makeLibrary(folder)
        let draft = try note("Work/Draft.md", in: library)
        library.selectedID = draft.id

        await library.rename(draft.id, to: "Plan")
        #expect(folder.filePaths == ["Work/Draft.md", "Work/Plan.md"]) // refused: taken in this folder
        await library.rename(draft.id, to: "Schedule")
        #expect(folder.filePaths == ["Work/Plan.md", "Work/Schedule.md"])

        await library.duplicate(draft.id)
        #expect(folder.filePaths == ["Work/Plan.md", "Work/Schedule copy.md", "Work/Schedule.md"])

        editor.type("Draft plan\nbody", in: library)
        try await library.setPassword("correct horse battery", hint: nil)
        try await library.lock(draft.id)
        #expect(folder.filePaths.contains("Work/Schedule.mdlock"))
        #expect(draft.folder == FolderPath(string: "Work"))
        try await library.removeLock(draft.id)
        #expect(folder.filePaths.contains("Work/Schedule.md"))
    }

    @Test func lockingKeepsTheCreationDate() async throws {
        let folder = try TemporaryLibrary()
        try folder.write("Old note", to: "Work/Old.md")
        let old = Date(timeIntervalSince1970: 1_000_000_000)
        try FileManager.default.setAttributes([.creationDate: old], ofItemAtPath: folder.notes.appendingPathComponent("Work/Old.md").path)
        let (library, _) = await makeLibrary(folder)
        let note = try note("Work/Old.md", in: library)
        #expect(note.created == old)

        try await library.setPassword("correct horse battery", hint: nil)
        try await library.lock(note.id)
        let values = try folder.notes.appendingPathComponent("Work/Old.mdlock").resourceValues(forKeys: [.creationDateKey])
        #expect(values.creationDate == old)
    }

    @Test func aDraftIsWrittenInItsFolderEvenIfTheFolderWentAway() async throws {
        let folder = try TemporaryLibrary()
        try folder.makeFolder("Work")
        let (library, editor) = await makeLibrary(folder)

        library.newNote(in: FolderPath(string: "Work"))
        try FileManager.default.removeItem(at: folder.notes.appendingPathComponent("Work"))
        editor.type("Filed away\nbody", in: library)
        await library.waitUntilIdle()
        #expect(folder.filePaths == ["Work/Filed away.md"])
        #expect(library.selectedNote?.relativePath == "Work/Filed away.md")
    }

    @Test func trashedNoteComesBackToItsFolder() async throws {
        let folder = try TemporaryLibrary()
        try folder.write("Keep\nme", to: "Work/Keep.md")
        try folder.write("Other", to: "Other.md")
        let (library, _) = await makeLibrary(folder)
        let keep = try note("Work/Keep.md", in: library)

        let receipt = try #require(await library.moveToTrash(keep.id))
        #expect(folder.filePaths == ["Other.md"])
        await library.restore(receipt)
        #expect(folder.filePaths == ["Other.md", "Work/Keep.md"])
    }

    @Test func noteDeletedElsewhereWithEditsIsWrittenAgainInItsFolder() async throws {
        let folder = try TemporaryLibrary()
        try folder.write("Fragile\nbody", to: "Work/Fragile.md")
        let (library, editor) = await makeLibrary(folder, timing: .slow)
        library.selectedID = try note("Work/Fragile.md", in: library).id

        editor.type("Fragile\nunsaved", in: library)
        try FileManager.default.removeItem(at: folder.notes.appendingPathComponent("Work/Fragile.md"))
        await library.rescanNow()
        await library.waitUntilIdle()
        #expect(folder.filePaths == ["Work/Fragile.md"])
        #expect(folder.contents(of: "Work/Fragile.md") == "Fragile\nunsaved")
    }

    // MARK: Changes made elsewhere

    @Test func noteMovedElsewhereKeepsItsIdentityEditorAndEdits() async throws {
        let folder = try TemporaryLibrary()
        try folder.write("Wanderer\nbody", to: "Wanderer.md")
        try folder.makeFolder("Archive")
        let (library, editor) = await makeLibrary(folder, timing: .slow)
        let wanderer = try note("Wanderer.md", in: library)
        library.selectedID = wanderer.id
        editor.type("Wanderer\nbody, edited", in: library)

        try FileManager.default.moveItem(at: folder.notes.appendingPathComponent("Wanderer.md"),
                                         to: folder.notes.appendingPathComponent("Archive/Wanderer.md"))
        await library.rescanNow()
        #expect(library.notes.count == 1)
        #expect(library.notes.first === wanderer)
        #expect(wanderer.relativePath == "Archive/Wanderer.md")
        #expect(editor.displayedNoteID == wanderer.id)
        #expect(editor.text == "Wanderer\nbody, edited")

        await library.waitUntilIdle()
        #expect(folder.filePaths == ["Archive/Wanderer.md"])
        #expect(folder.contents(of: "Archive/Wanderer.md") == "Wanderer\nbody, edited")
    }

    @Test func folderRenamedElsewhereKeepsItsNotes() async throws {
        let folder = try TemporaryLibrary()
        try folder.write("One", to: "Work/One.md")
        try folder.write("Two", to: "Work/Two.md")
        let (library, editor) = await makeLibrary(folder)
        let one = try note("Work/One.md", in: library)
        library.selectedID = one.id
        await library.waitUntilIdle()
        let reloads = editor.reloadCount

        try FileManager.default.moveItem(at: folder.notes.appendingPathComponent("Work"),
                                         to: folder.notes.appendingPathComponent("Jobs"))
        await library.rescanNow()
        #expect(library.note(atPath: "Jobs/One.md") === one)
        #expect(library.note(atPath: "Jobs/Two.md") != nil)
        #expect(library.folders.map(\.string) == ["Jobs"])
        #expect(editor.displayedNoteID == one.id)
        #expect(editor.reloadCount == reloads)
    }

    @Test func twoLookalikeFilesAreNotTakenForAMove() async throws {
        let folder = try TemporaryLibrary()
        try folder.write("Same", to: "A/Same.md")
        let (library, _) = await makeLibrary(folder)
        let original = try note("A/Same.md", in: library)
        let source = folder.notes.appendingPathComponent("A/Same.md")
        try folder.makeFolder("B")
        try folder.makeFolder("C")
        try FileManager.default.copyItem(at: source, to: folder.notes.appendingPathComponent("B/Same.md"))
        try FileManager.default.moveItem(at: source, to: folder.notes.appendingPathComponent("C/Same.md"))

        await library.rescanNow()
        #expect(library.notes.compactMap(\.relativePath).sorted() == ["B/Same.md", "C/Same.md"])
        #expect(!library.notes.contains { $0 === original })
    }

    // MARK: Identity across launches

    @Test func selectionIsRememberedByPathAndBareNamesStillWork() async throws {
        let folder = try TemporaryLibrary()
        try folder.write("Ideas\ntop", to: "Ideas.md")
        try folder.write("Ideas\nwork", to: "Work/Ideas.md")
        let defaults = freshDefaults()
        let (library, _) = await makeLibrary(folder, defaults: defaults)
        library.selectedID = try note("Work/Ideas.md", in: library).id
        await library.waitUntilIdle()

        let (reopened, _) = await makeLibrary(folder, defaults: defaults)
        #expect(reopened.selectedNote?.relativePath == "Work/Ideas.md")

        defaults.set("Ideas.md", forKey: Library.selectionKey) // as an earlier build saved it
        let (legacy, _) = await makeLibrary(folder, defaults: defaults)
        #expect(legacy.selectedNote?.relativePath == "Ideas.md")
    }

    @Test func savedTabsKeepNotesOfTheSameNameApart() {
        let saved = SavedTabs(windows: [.init(notes: ["Ideas.md", "Work/Ideas.md", "Gone.md"], front: 1, untouched: ["Work/Ideas.md"])])
        let restored = saved.restored(existing: ["Ideas.md", "Work/Ideas.md"])
        #expect(restored.windows.first?.notes == ["Ideas.md", "Work/Ideas.md"])
        #expect(restored.windows.first?.front == 1)
        #expect(restored.windows.first?.isUntouched("Work/Ideas.md") == true)
        #expect(restored.windows.first?.isUntouched("Ideas.md") == false)
    }

    // MARK: Links

    @Test func linksResolveFromTheNotesFolderThenByName() async throws {
        let folder = try TemporaryLibrary()
        try folder.write("Index", to: "Work/Index.md")
        try folder.write("Plan\nwork", to: "Work/Plan.md")
        try folder.write("Plan\ntop", to: "Plan.md")
        try folder.write("Deep", to: "Work/Sub/Deep.md")
        try folder.write("Far", to: "Elsewhere/Far away.md")
        let (library, _) = await makeLibrary(folder)
        let index = try note("Work/Index.md", in: library)

        #expect(library.note(linkedAs: "Plan.md", from: index)?.relativePath == "Work/Plan.md")
        #expect(library.note(linkedAs: "../Plan.md", from: index)?.relativePath == "Plan.md")
        #expect(library.note(linkedAs: "Sub/Deep.md", from: index)?.relativePath == "Work/Sub/Deep.md")
        #expect(library.note(linkedAs: "Plan", from: nil)?.relativePath == "Plan.md")
        // Written before folders: found by name wherever the note went.
        #expect(library.note(linkedAs: "Far away.md", from: index)?.relativePath == "Elsewhere/Far away.md")
        #expect(library.note(linkedAs: "../../Notes/Deep.md", from: index)?.relativePath == "Work/Sub/Deep.md")
    }

    // MARK: Locking

    @Test func wholeLibrarySealsNotesInFolders() async throws {
        let folder = try TemporaryLibrary()
        try folder.write("Top secret", to: "Top.md")
        try folder.write("Deep secret", to: "Work/Clients/Deep.md")
        let (library, _) = await makeLibrary(folder)
        try await library.setPassword("correct horse battery", hint: nil)
        try await library.setScope(.library)
        #expect(folder.filePaths == ["Top.mdlock", "Work/Clients/Deep.mdlock"])

        // A plain note added in a folder while locked is sealed at the next unlock.
        library.lockNow()
        try folder.write("Added later", to: "Work/Added.md")
        await library.rescanNow()
        try await library.unlock(password: "correct horse battery")
        await library.waitUntilIdle()
        #expect(folder.filePaths == ["Top.mdlock", "Work/Added.mdlock", "Work/Clients/Deep.mdlock"])
    }

    // MARK: Moving the library

    @Test func relocatingMovesFoldersWhole() async throws {
        let from = try TemporaryLibrary()
        let to = try TemporaryLibrary()
        try from.write("Top", to: "Top.md")
        try from.write("Deep", to: "Work/Clients/Deep.md")
        try from.write("Theirs", to: "Work/notes.txt")
        try to.write("Already there", to: "Work/Mine.md")
        let (library, _) = await makeLibrary(from)

        await library.relocate(to: to.makeStore(), watcher: nil, movingNotes: true)
        #expect(from.filePaths.isEmpty)
        #expect(to.filePaths == ["Top.md", "Work 2/Clients/Deep.md", "Work 2/notes.txt", "Work/Mine.md"])
        #expect(library.note(atPath: "Work 2/Clients/Deep.md") != nil)
    }
}
