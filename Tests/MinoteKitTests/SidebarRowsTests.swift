import CoreGraphics
import Foundation
import Testing
@testable import MinoteKit

@MainActor
@Suite("Sidebar rows")
struct SidebarRowsTests {
    private let now = Date(timeIntervalSince1970: 1_780_000_000) // 28/05/2026
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    /// A library of notes at paths, each last updated `daysAgo` before `now`.
    private func makeLibrary(_ folder: TemporaryLibrary, _ notes: [(String, Double)], text: (String) -> String = { $0 }) async throws -> Library {
        for (path, daysAgo) in notes {
            try folder.write(text(path), to: path)
            let date = now.addingTimeInterval(-daysAgo * 86_400)
            try FileManager.default.setAttributes([.modificationDate: date, .creationDate: date],
                                                  ofItemAtPath: folder.notes.appendingPathComponent(path).path)
        }
        let library = Library(store: folder.makeStore(), timing: .fast, defaults: freshDefaults())
        await library.load()
        return library
    }

    private func rows(_ library: Library, view: LibraryView = .standard, collapsed: Set<FolderPath> = [],
                      scope: FolderPath = .root, search: String = "") -> [SidebarRow] {
        SidebarRows.build(.init(notes: library.notes.filter { !$0.isDraft }, folders: library.folders, settings: library.folderSettings,
                                view: view, collapsed: collapsed, scope: scope, search: search, now: now, calendar: calendar))
    }

    /// Rows as "  Name" lines: two spaces a level, "▸"/"▾" for folders.
    private func describe(_ rows: [SidebarRow]) -> [String] {
        rows.map { row in
            let indent = String(repeating: "  ", count: row.depth)
            switch row {
            case .folder(let path, _, let count, let isOpen): return indent + (isOpen ? "▾ " : "▸ ") + (path.name ?? "") + " \(count)"
            case .note(let note, _, let label): return indent + note.displayTitle + (label.map { " [\($0.string)]" } ?? "")
            case .section(let title): return "# " + title
            }
        }
    }

    private let tree: [(String, Double)] = [
        ("Work/Roadmap.md", 1), ("Work/Clients/Acme.md", 0), ("Work/Clients/Zenith.md", 10),
        ("Personal/Reading.md", 40), ("Loose.md", 3),
    ]

    @Test func folderTreeNewestFirstFoldersFirst() async throws {
        let folder = try TemporaryLibrary()
        try folder.makeFolder("Empty")
        let library = try await makeLibrary(folder, tree)
        #expect(describe(rows(library)) == [
            "▾ Work 3", "  ▾ Clients 2", "    Acme", "    Zenith", "  Roadmap",
            "▾ Personal 1", "  Reading",
            "▾ Empty 0",
            "Loose",
        ])
        #expect(describe(rows(library, collapsed: [FolderPath(string: "Work")])) == [
            "▸ Work 3", "▾ Personal 1", "  Reading", "▾ Empty 0", "Loose",
        ])
    }

    @Test func folderSortsOverrideAndReverse() async throws {
        let folder = try TemporaryLibrary()
        let library = try await makeLibrary(folder, tree)
        library.setSort(SortOrder(.title), for: .root)
        library.setSort(SortOrder(.title, reversed: true), for: FolderPath(string: "Work/Clients"))
        #expect(describe(rows(library)) == [
            "▾ Personal 1", "  Reading",
            "▾ Work 3", "  ▾ Clients 2", "    Zenith", "    Acme", "  Roadmap",
            "Loose",
        ])
    }

    @Test func manualOrderInterleavesAndPutsNewcomersFirst() async throws {
        let folder = try TemporaryLibrary()
        let library = try await makeLibrary(folder, tree)
        library.setSort(SortOrder(.manual), for: .root)
        library.writeSettings(FolderSettings(sort: .manual, order: ["Loose", "Personal/", "Gone"]), for: .root)
        // Work isn't in the order: it comes first.
        #expect(describe(rows(library)).filter { !$0.hasPrefix(" ") } == ["▾ Work 3", "Loose", "▾ Personal 1"])
    }

    @Test func searchOpensMatchesAndHidesTheRest() async throws {
        let folder = try TemporaryLibrary()
        let library = try await makeLibrary(folder, tree)
        let collapsed: Set<FolderPath> = [FolderPath(string: "Work"), FolderPath(string: "Work/Clients")]
        #expect(describe(rows(library, collapsed: collapsed, search: "acme")) == ["▾ Work 1", "  ▾ Clients 1", "    Acme"])
        // A folder whose name matches shows everything in it.
        #expect(describe(rows(library, search: "clients")) == ["▾ Work 2", "  ▾ Clients 2", "    Acme", "    Zenith"])
        #expect(rows(library, search: "nothing like it").isEmpty)
    }

    @Test func lockedOnlyShowsLockedNotes() async throws {
        let folder = try TemporaryLibrary()
        let library = try await makeLibrary(folder, tree)
        var view = LibraryView()
        view.lockedOnly = true
        #expect(rows(library, view: view).isEmpty)
    }

    @Test func lookingIntoAFolder() async throws {
        let folder = try TemporaryLibrary()
        let library = try await makeLibrary(folder, tree)
        #expect(describe(rows(library, scope: FolderPath(string: "Work"))) == ["▾ Clients 2", "  Acme", "  Zenith", "Roadmap"])
        var flat = LibraryView()
        flat.groupBy = .none
        #expect(describe(rows(library, view: flat, scope: FolderPath(string: "Work"))) == ["Acme [Clients]", "Roadmap", "Zenith [Clients]"])
        // A folder that's gone: everything.
        #expect(rows(library, scope: FolderPath(string: "Gone")).count == rows(library).count)
    }

    @Test func flatAndDateGroupings() async throws {
        let folder = try TemporaryLibrary()
        let library = try await makeLibrary(folder, tree + [("Old.md", 400), ("Spring.md", 100)])
        var view = LibraryView()
        view.groupBy = .none
        #expect(describe(rows(library, view: view)) == [
            "Acme [Work/Clients]", "Roadmap [Work]", "Loose", "Zenith [Work/Clients]", "Reading [Personal]", "Spring", "Old",
        ])
        view.groupBy = .date
        #expect(describe(rows(library, view: view)) == [
            "# Today", "Acme [Work/Clients]",
            "# Yesterday", "Roadmap [Work]",
            "# Previous 7 Days", "Loose",
            "# Previous 30 Days", "Zenith [Work/Clients]",
            "# April", "Reading [Personal]",
            "# February", "Spring",
            "# 2025", "Old",
        ])
    }

    @Test func dateSectionsAcrossMidnightAndTheYearEnd() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let newYear = calendar.date(from: DateComponents(year: 2027, month: 1, day: 1, hour: 0, minute: 5))!
        let folder = try TemporaryLibrary()
        _ = folder
        let lateLastNight = newYear.addingTimeInterval(-10 * 60)
        let lastMonth = newYear.addingTimeInterval(-40 * 86_400)
        let notes = [lateLastNight, lastMonth].map { date -> Note in
            let note = Note(draftCreatedAt: date)
            note.modified = date
            return note
        }
        let sections = SidebarRows.dateSections(notes, now: newYear, calendar: calendar).map(\.0)
        #expect(sections == ["Yesterday", "2026"])
    }

    // MARK: Dropping

    private func frames(_ rows: [SidebarRow]) -> [CGRect] {
        rows.indices.map { CGRect(x: 0, y: CGFloat($0) * 20, width: 200, height: 20) }
    }

    private func drop(_ library: Library, _ rows: [SidebarRow], y: CGFloat, _ item: SidebarDragItem,
                      folderView: Bool = true, searching: Bool = false) -> SidebarDrop? {
        SidebarDrop.resolve(rows: rows, frames: frames(rows), y: y, dragging: item, ordering: library.ordering,
                            scope: .root, isFolderView: folderView, isSearching: searching)
    }

    @Test func dropsIntoFoldersAndBetweenRows() async throws {
        let folder = try TemporaryLibrary()
        let library = try await makeLibrary(folder, tree)
        library.setSort(SortOrder(.manual), for: .root)
        let rows = rows(library)
        // A manual root lists its children newest first until ordered:
        // 0 ▾ Work, 1 ▾ Clients, 2 Acme, 3 Zenith, 4 Roadmap, 5 Loose, 6 ▾ Personal, 7 Reading
        #expect(describe(rows).map { $0.trimmingCharacters(in: .whitespaces) } ==
                ["▾ Work 3", "▾ Clients 2", "Acme", "Zenith", "Roadmap", "Loose", "▾ Personal 1", "Reading"])
        let loose = SidebarDragItem.note(try #require(library.note(atPath: "Loose.md")))
        let acme = SidebarDragItem.note(try #require(library.note(atPath: "Work/Clients/Acme.md")))
        let work = SidebarDragItem.folder(FolderPath(string: "Work"))

        // The middle of a folder row: into it.
        #expect(drop(library, rows, y: 130, loose)?.target == .into(FolderPath(string: "Personal")))
        #expect(drop(library, rows, y: 130, loose)?.highlight == FolderPath(string: "Personal"))
        // Just under an open folder: its first child.
        #expect(drop(library, rows, y: 38, loose)?.target == .at(FolderPath(string: "Work/Clients"), index: 0))
        // Between two top-level rows: a place in the root.
        #expect(drop(library, rows, y: 2, loose)?.target == .at(.root, index: 0))
        // Where it already is: nothing.
        #expect(drop(library, rows, y: 112, loose) == nil)
        // Below every row: the end of the top level, whatever the last row's depth.
        #expect(drop(library, rows, y: 200, .note(try #require(library.note(atPath: "Work/Roadmap.md"))))?.target == .at(.root, index: 3))
        // A newcomer to a folder that isn't manual lands where its sort puts it.
        library.setSort(SortOrder(.title), for: FolderPath(string: "Work/Clients"))
        let sortedRows = self.rows(library)
        #expect(drop(library, sortedRows, y: 38, loose) == SidebarDrop(target: .into(FolderPath(string: "Work/Clients")),
                                                                      highlight: FolderPath(string: "Work/Clients"), line: nil))
        // A folder into itself or below: refused.
        #expect(drop(library, rows, y: 30, work) == nil)
        #expect(drop(library, rows, y: 50, work) == nil)
        // A reorder inside a sorted folder is allowed (it becomes manual).
        #expect(drop(library, rows, y: 78, acme)?.target == .at(FolderPath(string: "Work/Clients"), index: 2))
        // Flat lists and searching: no drops.
        #expect(drop(library, rows, y: 130, loose, folderView: false) == nil)
        #expect(drop(library, rows, y: 130, loose, searching: true) == nil)
    }
}

@MainActor
@Suite("Dropping several")
struct GroupDropTests {
    @Test func aGroupIsCheckedAsAWhole() async throws {
        let folder = try TemporaryLibrary()
        try folder.write("A", to: "Work/A.md")
        try folder.write("B", to: "B.md")
        try folder.write("C", to: "Archive/C.md")
        let library = Library(store: folder.makeStore(), timing: .fast, defaults: freshDefaults())
        await library.load()
        let rows = SidebarRows.build(.init(notes: library.notes.filter { !$0.isDraft }, folders: library.folders, settings: [:]))
        let frames = rows.indices.map { CGRect(x: 0, y: CGFloat($0) * 20, width: 200, height: 20) }
        let a = SidebarDragItem.note(try #require(library.note(atPath: "Work/A.md")))
        let b = SidebarDragItem.note(try #require(library.note(atPath: "B.md")))
        let work = FolderPath(string: "Work")
        let workRow = try #require(rows.firstIndex { $0.folder == work })
        let middle = CGFloat(workRow) * 20 + 10
        func drop(_ item: SidebarDragItem, _ group: [SidebarDragItem]) -> SidebarDrop? {
            SidebarDrop.resolve(rows: rows, frames: frames, y: middle, dragging: item, group: group, ordering: library.ordering,
                                scope: .root, isFolderView: true, isSearching: false)
        }
        // A alone onto its own folder: nothing. With B along: B moves in.
        #expect(drop(a, []) == nil)
        #expect(drop(a, [a, b])?.target == .into(work))
        // A folder in the group can't go into itself.
        #expect(drop(a, [a, .folder(work)]) == nil)
    }
}
