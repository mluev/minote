import Foundation
import Testing
@testable import MinoteKit

@MainActor
@Suite("Library search")
struct LibrarySearchTests {
    private func text(_ text: String, _ match: FuzzyMatch?) -> [String] {
        match?.ranges.map { String(text[$0]) } ?? []
    }

    @Test func wholeWordsBeatScatteredLetters() throws {
        let plain = try #require(Fuzzy.match("road", in: "Q1 Roadmap"))
        #expect(text("Q1 Roadmap", plain) == ["Road"])
        let scattered = try #require(Fuzzy.match("rdmp", in: "Q1 Roadmap"))
        #expect(scattered.score < plain.score)
        #expect(text("Q1 Roadmap", scattered).joined().lowercased() == "rdmp")
        // Word starts are preferred: "mn" finds Meeting Notes, not "meeting" letters.
        #expect(text("Meeting notes", Fuzzy.match("mn", in: "Meeting notes")) == ["M", "n"])
        #expect(Fuzzy.match("xyz", in: "Q1 Roadmap") == nil)
        #expect(Fuzzy.match("cafe", in: "Café plans") != nil)
        let start = try #require(Fuzzy.match("plan", in: "Plan B"))
        let middle = try #require(Fuzzy.match("plan", in: "The plan"))
        #expect(start.score > middle.score)
    }

    @Test func snippetsShowTheMatchingLine() throws {
        let note = "# Groceries\n\n- [ ] Buy **oat milk** and bread\nother line"
        let hit = try #require(LibrarySearch.snippet(for: "oat", in: note, skippingTitle: true))
        #expect(hit.text == "Buy oat milk and bread") // markup stripped, as in the sidebar
        #expect(String(hit.text[hit.match]) == "oat")
        #expect(LibrarySearch.snippet(for: "groceries", in: note, skippingTitle: true) == nil)

        let long = String(repeating: "word ", count: 40) + "needle" + String(repeating: " tail", count: 40)
        let cut = try #require(LibrarySearch.snippet(for: "needle", in: long, width: 60))
        #expect(cut.text.count <= 62)
        #expect(cut.text.hasPrefix("…") && cut.text.hasSuffix("…"))
        #expect(String(cut.text[cut.match]) == "needle")
    }

    @Test func notesByTitleFirstThenByText() async throws {
        let folder = try TemporaryLibrary()
        try folder.write("Budget 2027\nnumbers", to: "Budget 2027.md")
        try folder.write("Trip\nkeep the budget small", to: "Trip.md")
        try folder.write("Unrelated\nnothing here", to: "Unrelated.md")
        let library = Library(store: folder.makeStore(), timing: .fast, defaults: freshDefaults())
        await library.load()

        let hits = LibrarySearch.notes("budget", in: library.notes)
        #expect(hits.map(\.note.displayTitle) == ["Budget 2027", "Trip"])
        #expect(hits[0].titleMatch != nil)
        #expect(hits[1].snippet == "keep the budget small")
        #expect(LibrarySearch.notes("", in: library.notes).count == 3)
    }

    @Test func foldersByName() {
        let folders = [FolderPath(string: "Work"), FolderPath(string: "Work/Clients"), FolderPath(string: "Personal")]
        #expect(LibrarySearch.folders("cli", in: folders).map(\.folder.string) == ["Work/Clients"])
        #expect(LibrarySearch.folders("", in: folders).isEmpty)
    }

    @Test func keyboardStepsSkipHeadingsAndFindParents() async throws {
        let folder = try TemporaryLibrary()
        try folder.write("A", to: "Work/Clients/A.md")
        try folder.write("B", to: "Work/B.md")
        let library = Library(store: folder.makeStore(), timing: .fast, defaults: freshDefaults())
        await library.load()
        let rows = SidebarRows.build(.init(notes: library.notes.filter { !$0.isDraft }, folders: library.folders, settings: [:]))
        // ▾ Work, ▾ Clients, A, B
        #expect(rows.count == 4)
        #expect(SidebarRows.row(from: nil, offset: 1, in: rows)?.id == rows[0].id)
        #expect(SidebarRows.row(from: nil, offset: -1, in: rows)?.id == rows[3].id)
        #expect(SidebarRows.row(from: rows[1].id, offset: 1, in: rows)?.id == rows[2].id)
        #expect(SidebarRows.row(from: rows[3].id, offset: 5, in: rows)?.id == rows[3].id)
        #expect(SidebarRows.parentRow(of: rows[2].id, in: rows)?.folder == FolderPath(string: "Work/Clients"))
        #expect(SidebarRows.parentRow(of: rows[3].id, in: rows)?.folder == FolderPath(string: "Work"))
        #expect(SidebarRows.parentRow(of: rows[0].id, in: rows) == nil)
    }
}
