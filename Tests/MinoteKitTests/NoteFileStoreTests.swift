import Foundation
import Testing
@testable import MinoteKit

@Suite("File store")
struct NoteFileStoreTests {
    @Test func createWriteReadRoundTrip() async throws {
        let library = try TemporaryLibrary()
        let store = library.makeStore()

        let created = try await store.create(text: "Hello\nworld", base: "Hello")
        #expect(created.url.lastPathComponent == "Hello.md")
        #expect(try await store.readText(at: created.url) == "Hello\nworld")

        let id = UUID()
        _ = try await store.write("Hello again", to: created.url, autoNameTag: "Hello", noteID: id, revision: 1)
        #expect(library.contents(of: "Hello.md") == "Hello again")
    }

    @Test func createNeverOverwrites() async throws {
        let library = try TemporaryLibrary()
        try library.write("existing", to: "Note.md")
        let store = library.makeStore()

        let created = try await store.create(text: "new", base: "Note")
        #expect(created.url.lastPathComponent == "Note 2.md")
        #expect(library.contents(of: "Note.md") == "existing")
    }

    @Test func createdFilesAreTaggedAsAutoNamed() async throws {
        let library = try TemporaryLibrary()
        let store = library.makeStore()
        let created = try await store.create(text: "x", base: "Tagged")
        #expect(ExtendedAttributes.string(named: NoteFileStore.autoNameAttribute, at: created.url) == "Tagged")
    }

    @Test("Saving keeps Finder tags and other extended attributes")
    func safeWritePreservesMetadata() async throws {
        let library = try TemporaryLibrary()
        let store = library.makeStore()
        let created = try await store.create(text: "v1", base: "Tagged note")

        let url = created.url
        try (url as NSURL).setResourceValue(["Red", "Work"], forKey: .tagNamesKey)
        try ExtendedAttributes.set("keep me", named: "com.example.custom", at: url)
        let creation = try url.resourceValues(forKeys: [.creationDateKey]).creationDate

        _ = try await store.write("v2", to: url, autoNameTag: "Tagged note", noteID: UUID(), revision: 1)

        let fresh = URL(fileURLWithPath: url.path)
        let after = try fresh.resourceValues(forKeys: [.tagNamesKey, .creationDateKey])
        #expect(library.contents(of: "Tagged note.md") == "v2")
        #expect(Set(after.tagNames ?? []) == ["Red", "Work"])
        #expect(ExtendedAttributes.string(named: "com.example.custom", at: fresh) == "keep me")
        #expect(ExtendedAttributes.string(named: NoteFileStore.autoNameAttribute, at: fresh) == "Tagged note")
        #expect(after.creationDate == creation)
    }

    @Test func emptyingANoteKeepsABackup() async throws {
        let library = try TemporaryLibrary()
        let store = library.makeStore()
        let created = try await store.create(text: "precious words", base: "Keep")
        _ = try await store.write("", to: created.url, autoNameTag: nil, noteID: UUID(), revision: 1)

        let backups = try FileManager.default.contentsOfDirectory(at: store.backupDirectory, includingPropertiesForKeys: nil)
        #expect(backups.count == 1)
        #expect(try String(contentsOf: backups[0], encoding: .utf8) == "precious words")
        #expect(library.contents(of: "Keep.md") == "")
    }

    @Test func staleRevisionsAreDropped() async throws {
        let library = try TemporaryLibrary()
        let store = library.makeStore()
        let created = try await store.create(text: "v0", base: "Rev")
        let id = UUID()

        #expect(try await store.write("v2", to: created.url, autoNameTag: nil, noteID: id, revision: 2) != nil)
        #expect(try await store.write("v1", to: created.url, autoNameTag: nil, noteID: id, revision: 1) == nil)
        #expect(library.contents(of: "Rev.md") == "v2")
    }

    @Test func renameFollowsTitleAndUpdatesTag() async throws {
        let library = try TemporaryLibrary()
        let store = library.makeStore()
        let created = try await store.create(text: "x", base: "Draft")

        let renamed = try await store.rename(created.url, toBase: "Final essay")
        #expect(renamed.lastPathComponent == "Final essay.md")
        #expect(library.fileNames == ["Final essay.md"])
        #expect(ExtendedAttributes.string(named: NoteFileStore.autoNameAttribute, at: renamed) == "Final essay")
    }

    @Test func renameNeverClobbersAnotherFile() async throws {
        let library = try TemporaryLibrary()
        try library.write("other", to: "Taken.md")
        let store = library.makeStore()
        let created = try await store.create(text: "mine", base: "Mine")

        let renamed = try await store.rename(created.url, toBase: "Taken")
        #expect(renamed.lastPathComponent == "Taken 2.md")
        #expect(library.contents(of: "Taken.md") == "other")

        // Renaming to the same base again is a no-op, not "Taken 3".
        #expect(try await store.rename(renamed, toBase: "Taken") == renamed)
    }

    @Test func caseOnlyRename() async throws {
        let library = try TemporaryLibrary()
        let store = library.makeStore()
        let created = try await store.create(text: "x", base: "hello")

        let renamed = try await store.rename(created.url, toBase: "Hello")
        #expect(renamed.lastPathComponent == "Hello.md")
        #expect(library.fileNames == ["Hello.md"])
    }

    @Test func scanReadsOnlyChangedFiles() async throws {
        let library = try TemporaryLibrary()
        try library.write("one", to: "One.md")
        try library.write("two", to: "Two.txt")
        try library.write("ignored", to: "image.png")
        try library.write("hidden", to: ".hidden.md")
        let store = library.makeStore()

        let first = try await store.scan(known: [:])
        #expect(first.map(\.url.lastPathComponent).sorted() == ["One.md", "Two.txt"])
        #expect(first.allSatisfy { $0.text != nil })

        let known = Dictionary(uniqueKeysWithValues: first.map { ($0.url, $0.stamp) })
        let second = try await store.scan(known: known)
        #expect(second.allSatisfy { $0.text == nil })
    }

    @Test func trashAndRestore() async throws {
        let library = try TemporaryLibrary()
        let store = library.makeStore()
        let created = try await store.create(text: "precious", base: "Keep")

        let trashed = try #require(try await store.trash(created.url))
        #expect(library.fileNames.isEmpty)

        let restored = try await store.restore(trashed, preferredName: "Keep.md")
        #expect(restored.lastPathComponent == "Keep.md")
        #expect(library.contents(of: "Keep.md") == "precious")
    }

    @Test func readsNonUTF8AndStripsBOM() async throws {
        let library = try TemporaryLibrary()
        let store = library.makeStore()
        let bom = library.notes.appendingPathComponent("bom.md")
        try Data([0xEF, 0xBB, 0xBF] + Array("hi".utf8)).write(to: bom)
        let latin = library.notes.appendingPathComponent("latin.md")
        try Data([0x63, 0x61, 0x66, 0xE9]).write(to: latin) // "café" in Windows-1252

        #expect(try await store.readText(at: bom) == "hi")
        #expect(try await store.readText(at: latin) == "café")

        let utf16 = library.notes.appendingPathComponent("utf16.md")
        try "naïve – text".data(using: .utf16)!.write(to: utf16) // with a byte order mark
        #expect(try await store.readText(at: utf16) == "naïve – text")
    }

    @Test func backupsGoWhereTheAppSays() async throws {
        let library = try TemporaryLibrary()
        let backups = library.root.appendingPathComponent("Elsewhere", isDirectory: true)
        let store = NoteFileStore(directory: library.notes, backupDirectory: backups)
        try library.write("keep me", to: "Note.md")
        _ = try await store.write("", to: library.notes.appendingPathComponent("Note.md"), autoNameTag: nil, noteID: UUID(), revision: 1)
        let copies = try FileManager.default.contentsOfDirectory(at: backups, includingPropertiesForKeys: nil)
        #expect(copies.count == 1)
    }
}
