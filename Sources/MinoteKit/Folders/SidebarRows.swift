import CoreGraphics
import Foundation

/// How the sidebar lists the library, chosen per device (a phone and a Mac
/// want different views). The sort belongs to the folders, not here.
public struct LibraryView: Codable, Equatable, Sendable {
    public enum Grouping: String, Codable, CaseIterable, Sendable {
        case folder, date, none

        public var displayName: String {
            switch self {
            case .folder: "Folder"
            case .date: "Date"
            case .none: "None"
            }
        }
    }

    public var groupBy: Grouping = .folder
    public var showsDates = true
    public var showsCounts = true
    public var lockedOnly = false

    public init() {}

    public static let standard = LibraryView()

    public static let key = "LibraryView"

    public static func load(from defaults: UserDefaults = .standard) -> LibraryView {
        guard let data = defaults.data(forKey: key), let view = try? JSONDecoder().decode(LibraryView.self, from: data) else { return .standard }
        return view
    }

    public func save(to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.key)
    }

    // Settings added later decode with their defaults.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        groupBy = (try? container.decodeIfPresent(Grouping.self, forKey: .groupBy)) ?? .folder
        showsDates = try container.decodeIfPresent(Bool.self, forKey: .showsDates) ?? true
        showsCounts = try container.decodeIfPresent(Bool.self, forKey: .showsCounts) ?? true
        lockedOnly = try container.decodeIfPresent(Bool.self, forKey: .lockedOnly) ?? false
    }
}

/// One row of the sidebar.
@MainActor
public enum SidebarRow: Identifiable, Equatable {
    /// A folder: `count` notes inside, at every level.
    case folder(FolderPath, depth: Int, count: Int, isOpen: Bool)
    /// A note. `folderLabel` is its folder, in flat lists.
    case note(Note, depth: Int, folderLabel: FolderPath?)
    /// A heading in a list grouped by date.
    case section(String)

    nonisolated public var id: String {
        switch self {
        case .folder(let path, _, _, _): "folder:" + path.string
        case .note(let note, _, _): "note:" + note.id.uuidString
        case .section(let title): "section:" + title
        }
    }

    public var depth: Int {
        switch self {
        case .folder(_, let depth, _, _), .note(_, let depth, _): depth
        case .section: 0
        }
    }

    /// The folder this row sits in.
    public var parent: FolderPath? {
        switch self {
        case .folder(let path, _, _, _): path.parent
        case .note(let note, _, _): note.folder
        case .section: nil
        }
    }

    public var note: Note? {
        if case .note(let note, _, _) = self { note } else { nil }
    }

    public var folder: FolderPath? {
        if case .folder(let path, _, _, _) = self { path } else { nil }
    }

    nonisolated public static func == (lhs: SidebarRow, rhs: SidebarRow) -> Bool {
        switch (lhs, rhs) {
        case let (.folder(a, da, ca, oa), .folder(b, db, cb, ob)): a == b && da == db && ca == cb && oa == ob
        case let (.note(a, da, la), .note(b, db, lb)): a === b && da == db && la == lb
        case let (.section(a), .section(b)): a == b
        default: false
        }
    }
}

/// Builds the sidebar's rows from the library and the view: pure, so every
/// grouping, sort and filter is tested without a screen.
@MainActor
public enum SidebarRows {
    public struct Input {
        public var notes: [Note]
        public var folders: [FolderPath]
        public var settings: [FolderPath: FolderSettings]
        public var view: LibraryView
        /// Folders the writer closed.
        public var collapsed: Set<FolderPath>
        /// The folder looked into ("Show Only This Folder"); the root for all.
        public var scope: FolderPath
        public var search: String
        public var now: Date
        public var calendar: Calendar

        public init(notes: [Note], folders: [FolderPath], settings: [FolderPath: FolderSettings], view: LibraryView = .standard,
                    collapsed: Set<FolderPath> = [], scope: FolderPath = .root, search: String = "",
                    now: Date = Date(), calendar: Calendar = .current) {
            self.notes = notes
            self.folders = folders
            self.settings = settings
            self.view = view
            self.collapsed = collapsed
            self.scope = scope
            self.search = search
            self.now = now
            self.calendar = calendar
        }
    }

    public static func build(_ input: Input) -> [SidebarRow] {
        let scope = input.folders.contains(input.scope) ? input.scope : .root
        let inScope = input.notes.filter { scope.contains($0.folder) }
        let query = input.search.trimmingCharacters(in: .whitespacesAndNewlines)
        let ordering = FolderOrdering(notes: inScope, folders: input.folders.filter { scope.isAncestor(of: $0) }, settings: input.settings)

        func passesFilters(_ note: Note) -> Bool {
            if input.view.lockedOnly && !note.isLocked { return false }
            return true
        }
        func matchesSearch(_ note: Note) -> Bool {
            query.isEmpty || note.title.localizedStandardContains(query) || note.text?.localizedStandardContains(query) == true
        }

        switch input.view.groupBy {
        case .none:
            let notes = ordering.sorted(inScope.filter { passesFilters($0) && matchesSearch($0) }, by: ordering.sortOrder(of: scope))
            return notes.map { .note($0, depth: 0, folderLabel: label(for: $0, scope: scope)) }
        case .date:
            let notes = ordering.sorted(inScope.filter { passesFilters($0) && matchesSearch($0) }, by: ordering.sortOrder(of: scope))
            var rows: [SidebarRow] = []
            for (title, members) in dateSections(notes, now: input.now, calendar: input.calendar) {
                rows.append(.section(title))
                rows += members.map { .note($0, depth: 0, folderLabel: label(for: $0, scope: scope)) }
            }
            return rows
        case .folder:
            break
        }

        let filtering = !query.isEmpty || input.view.lockedOnly
        var rows: [SidebarRow] = []
        /// Whether a folder has anything to show under the filters, and how many notes.
        func visibleNotes(under folder: FolderPath, everything: Bool) -> [Note] {
            ordering.notes(under: folder).filter { passesFilters($0) && (everything || matchesSearch($0)) }
        }
        func nameMatches(_ folder: FolderPath) -> Bool {
            !query.isEmpty && (folder.name?.localizedStandardContains(query) ?? false)
        }
        func emit(_ folder: FolderPath, depth: Int, everything: Bool) {
            for child in ordering.children(of: folder) {
                switch child {
                case .folder(let path):
                    let showAll = everything || nameMatches(path)
                    let visible = visibleNotes(under: path, everything: showAll)
                    if filtering && visible.isEmpty && !(showAll && !input.view.lockedOnly) { continue }
                    let isOpen = filtering || !input.collapsed.contains(path)
                    rows.append(.folder(path, depth: depth, count: visible.count, isOpen: isOpen))
                    if isOpen { emit(path, depth: depth + 1, everything: showAll) }
                case .note(let note):
                    guard passesFilters(note), everything || matchesSearch(note) else { continue }
                    rows.append(.note(note, depth: depth, folderLabel: nil))
                }
            }
        }
        emit(scope, depth: 0, everything: false)
        return rows
    }

    /// A note's folder as a flat list labels it: relative to the folder
    /// looked into, nothing for notes right in it.
    private static func label(for note: Note, scope: FolderPath) -> FolderPath? {
        guard note.folder != scope else { return nil }
        return FolderPath(Array(note.folder.components.dropFirst(scope.depth)))
    }

    /// Today, Yesterday, Previous 7 Days, Previous 30 Days, the months of
    /// this year, then years; newest first, each keeping the notes' order.
    public static func dateSections(_ notes: [Note], now: Date, calendar: Calendar) -> [(String, [Note])] {
        var sections: [(key: Int, title: String, notes: [Note])] = []
        let today = calendar.startOfDay(for: now)
        let year = calendar.component(.year, from: now)
        let months = DateFormatter()
        months.calendar = calendar
        months.timeZone = calendar.timeZone
        months.setLocalizedDateFormatFromTemplate("MMMM")

        for note in notes {
            let date = note.modified
            let day = calendar.startOfDay(for: date)
            let days = calendar.dateComponents([.day], from: day, to: today).day ?? 0
            let key: Int
            let title: String
            switch days {
            case ...0: (key, title) = (0, "Today")
            case 1: (key, title) = (1, "Yesterday")
            case 2...7: (key, title) = (2, "Previous 7 Days")
            case 8...30: (key, title) = (3, "Previous 30 Days")
            default:
                let noteYear = calendar.component(.year, from: date)
                if noteYear == year {
                    let month = calendar.component(.month, from: date)
                    (key, title) = (100 - month, months.string(from: date))
                } else {
                    (key, title) = (100 + (year - noteYear), String(noteYear))
                }
            }
            if let index = sections.firstIndex(where: { $0.key == key }) {
                sections[index].notes.append(note)
            } else {
                sections.append((key, title, [note]))
            }
        }
        return sections.sorted { $0.key < $1.key }.map { ($0.title, $0.notes) }
    }
}

/// What is being dragged in the sidebar.
@MainActor
public enum SidebarDragItem: Equatable {
    case note(Note)
    case folder(FolderPath)

    var folder: FolderPath? { if case .folder(let path) = self { path } else { nil } }

    /// The folder it's in now.
    var parent: FolderPath {
        switch self {
        case .note(let note): note.folder
        case .folder(let path): path.parent ?? .root
        }
    }

    nonisolated public static func == (lhs: SidebarDragItem, rhs: SidebarDragItem) -> Bool {
        switch (lhs, rhs) {
        case (.note(let a), .note(let b)): a === b
        case (.folder(let a), .folder(let b)): a == b
        default: false
        }
    }
}

/// Where a drop in the sidebar lands, and what to show while hovering.
public struct SidebarDrop: Equatable, Sendable {
    public enum Target: Equatable, Sendable {
        /// Into this folder, where its sort puts it (at the top in Manual).
        case into(FolderPath)
        /// At this place among the folder's children (an index into
        /// `FolderOrdering.children`, counted before the item leaves).
        case at(FolderPath, index: Int)
    }

    public var target: Target
    /// The folder row to highlight, if the drop goes into a folder with a row.
    public var highlight: FolderPath?
    /// The insertion line: below which row (nil = above the first), at what depth.
    public var line: (afterRow: Int?, depth: Int)?

    public static func == (lhs: SidebarDrop, rhs: SidebarDrop) -> Bool {
        lhs.target == rhs.target && lhs.highlight == rhs.highlight
            && lhs.line?.afterRow == rhs.line?.afterRow && lhs.line?.depth == rhs.line?.depth
    }

    /// The drop for a pointer at `y` over rows laid out at `frames` (one per
    /// row, top to bottom, in the same coordinates). Nil where nothing may be
    /// dropped: in flat lists, while searching, a folder into itself or below
    /// it, or where the item already is.
    @MainActor
    public static func resolve(rows: [SidebarRow], frames: [CGRect], y: CGFloat, dragging item: SidebarDragItem,
                               ordering: FolderOrdering, scope: FolderPath, isFolderView: Bool, isSearching: Bool) -> SidebarDrop? {
        guard isFolderView, !isSearching, rows.count == frames.count else { return nil }

        // Over a folder row's middle: into it.
        if let index = frames.firstIndex(where: { y >= $0.minY && y < $0.maxY }), case .folder(let path, _, _, _) = rows[index] {
            let frame = frames[index]
            if y > frame.minY + frame.height * 0.25 && y < frame.maxY - frame.height * 0.25 {
                return validated(SidebarDrop(target: .into(path), highlight: path, line: nil), item: item, ordering: ordering)
            }
        }

        // Below every row: the end of the list, at the top level.
        if let last = frames.last, y > last.maxY + 8 {
            let drop = SidebarDrop(target: .at(scope, index: ordering.children(of: scope).count), highlight: nil,
                                   line: (rows.count - 1, 0))
            return validated(drop, item: item, ordering: ordering)
        }

        // Otherwise the gap nearest the pointer, between `above` and `below`.
        var below = frames.firstIndex { y < $0.midY } ?? rows.count
        if below < rows.count, case .section = rows[below] { below += 1 }
        let above = below > 0 ? below - 1 : nil
        let target: Target
        let depth: Int
        if let above, case .folder(let path, let rowDepth, _, true) = rows[above] {
            // Right under an open folder: its first child.
            target = .at(path, index: 0)
            depth = rowDepth + 1
        } else if let above, below < rows.count, rows[below].depth >= rows[above].depth, let parent = rows[below].parent {
            target = .at(parent, index: position(of: rows[below], in: parent, ordering: ordering))
            depth = rows[below].depth
        } else if let above, let parent = rows[above].parent {
            target = .at(parent, index: position(of: rows[above], in: parent, ordering: ordering) + 1)
            depth = rows[above].depth
        } else {
            target = .at(scope, index: 0)
            depth = 0
        }
        return validated(SidebarDrop(target: target, highlight: nil, line: (above, depth)), item: item, ordering: ordering)
    }

    /// Applies the rules: no folder into itself or below; nothing where the
    /// item already is; a newcomer to a folder that isn't sorted by hand
    /// lands where the sort puts it, so its sort never changes behind the
    /// writer's back.
    @MainActor
    private static func validated(_ drop: SidebarDrop, item: SidebarDragItem, ordering: FolderOrdering) -> SidebarDrop? {
        let destination: FolderPath
        switch drop.target {
        case .into(let folder): destination = folder
        case .at(let folder, _): destination = folder
        }
        if let moving = item.folder, moving.contains(destination) { return nil }

        switch drop.target {
        case .into(let folder):
            return folder == item.parent ? nil : drop
        case .at(let folder, let index):
            if folder != item.parent {
                guard ordering.sortOrder(of: folder).sort == .manual else {
                    return SidebarDrop(target: .into(folder), highlight: folder.isRoot ? nil : folder, line: nil)
                }
                return drop
            }
            // A move within the folder: nothing to do where it already is.
            let children = ordering.children(of: folder)
            if let current = children.firstIndex(where: { child in
                switch (child, item) {
                case (.note(let a), .note(let b)): a === b
                case (.folder(let a), .folder(let b)): a == b
                default: false
                }
            }), index == current || index == current + 1 {
                return nil
            }
            return drop
        }
    }

    @MainActor
    private static func position(of row: SidebarRow, in folder: FolderPath, ordering: FolderOrdering) -> Int {
        ordering.children(of: folder).firstIndex { child in
            switch (child, row) {
            case (.note(let a), .note(let b, _, _)): a === b
            case (.folder(let a), .folder(let b, _, _, _)): a == b
            default: false
            }
        } ?? 0
    }
}

// MARK: Keyboard

extension SidebarRows {
    /// The row `offset` rows from the row `id`, headings skipped, stopping at
    /// either end. With `id` not listed: the first row (or the last, going up).
    public static func row(from id: String?, offset: Int, in rows: [SidebarRow]) -> SidebarRow? {
        let selectable = rows.filter { if case .section = $0 { false } else { true } }
        guard !selectable.isEmpty else { return nil }
        guard let id, let index = selectable.firstIndex(where: { $0.id == id }) else {
            return offset < 0 ? selectable.last : selectable.first
        }
        return selectable[min(max(index + offset, 0), selectable.count - 1)]
    }

    /// The folder row the row `id` sits under, if it's listed.
    public static func parentRow(of id: String, in rows: [SidebarRow]) -> SidebarRow? {
        guard let index = rows.firstIndex(where: { $0.id == id }), rows[index].depth > 0 else { return nil }
        let depth = rows[index].depth
        return rows[..<index].last { row in
            if case .folder = row { row.depth == depth - 1 } else { false }
        }
    }
}
