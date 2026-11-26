import Foundation

/// How a folder's notes and folders are ordered.
public enum NoteSort: String, Codable, CaseIterable, Sendable {
    /// The writer's own order (dragged into place).
    case manual
    /// Last updated first.
    case updated
    /// Last made first.
    case created
    /// A to Z.
    case title

    public var displayName: String {
        switch self {
        case .manual: "Manual"
        case .updated: "Last Updated"
        case .created: "Date Created"
        case .title: "Title"
        }
    }
}

/// A sort and its direction.
public struct SortOrder: Equatable, Sendable {
    public var sort: NoteSort
    public var reversed: Bool

    public init(_ sort: NoteSort, reversed: Bool = false) {
        self.sort = sort
        self.reversed = reversed
    }

    /// The library folder's order when nothing was chosen: as before folders.
    public static let standard = SortOrder(.updated)
}

/// What a folder remembers about its own order, kept in a hidden
/// `.minote-folder` file inside it, so it travels with the folder whoever
/// moves it and syncs with it. Losing the file loses that order, nothing else.
public struct FolderSettings: Equatable, Sendable, Codable {
    public static let fileName = ".minote-folder"
    public static let currentVersion = 1

    public var version: Int
    /// This folder's own sort; nil follows the folder above.
    public var sort: NoteSort?
    public var reversed: Bool?
    /// The folder's children in the writer's order: a folder as "Name/", a
    /// note as its file name without extension (so locking it keeps its
    /// place). Kept while another sort is chosen, so Manual brings it back.
    public var order: [String]

    public init(sort: NoteSort? = nil, reversed: Bool? = nil, order: [String] = []) {
        self.version = Self.currentVersion
        self.sort = sort
        self.reversed = reversed
        self.order = order
    }

    /// Nothing worth a file.
    public var isEmpty: Bool { sort == nil && order.isEmpty }

    /// This folder's own sort, or nil when it follows the one above.
    public var ownOrder: SortOrder? { sort.map { SortOrder($0, reversed: reversed ?? false) } }

    public static func key(forFolder name: String) -> String { name + "/" }
    public static func key(forNote stem: String) -> String { stem }

    public enum Read: Equatable, Sendable {
        case found(FolderSettings)
        /// A file this build can't read (newer, or damaged): left alone, and
        /// not rewritten until the writer orders that folder again.
        case unreadable
    }

    public static func decode(_ data: Data) -> Read {
        guard let settings = try? JSONDecoder().decode(FolderSettings.self, from: data),
              settings.version == currentVersion else { return .unreadable }
        return .found(settings)
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    private enum CodingKeys: String, CodingKey { case version, sort, reversed, order }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        sort = try? container.decodeIfPresent(NoteSort.self, forKey: .sort)
        reversed = try container.decodeIfPresent(Bool.self, forKey: .reversed)
        order = try container.decodeIfPresent([String].self, forKey: .order) ?? []
    }
}

/// One child of a folder, as the sidebar lists it.
@MainActor
public enum FolderChild: Equatable {
    case folder(FolderPath)
    case note(Note)

    /// Its entry in the folder's manual order; nil for a draft (always first).
    public var orderKey: String? {
        switch self {
        case .folder(let path): path.name.map(FolderSettings.key(forFolder:))
        case .note(let note): note.fileStem.map(FolderSettings.key(forNote:))
        }
    }

    nonisolated public static func == (lhs: FolderChild, rhs: FolderChild) -> Bool {
        switch (lhs, rhs) {
        case (.folder(let a), .folder(let b)): a == b
        case (.note(let a), .note(let b)): a === b
        default: false
        }
    }
}

/// How the children of a folder are ordered. Pure: the sidebar and the
/// library's reordering both ask it, so what's shown and what's stored agree.
@MainActor
public struct FolderOrdering {
    public let notes: [Note]
    public let folders: [FolderPath]
    public let settings: [FolderPath: FolderSettings]

    private let notesByFolder: [FolderPath: [Note]]
    private let subfolders: [FolderPath: [FolderPath]]

    public init(notes: [Note], folders: [FolderPath], settings: [FolderPath: FolderSettings]) {
        self.notes = notes
        self.folders = folders
        self.settings = settings
        notesByFolder = Dictionary(grouping: notes, by: \.folder)
        var subfolders: [FolderPath: [FolderPath]] = [:]
        for folder in folders {
            if let parent = folder.parent { subfolders[parent, default: []].append(folder) }
        }
        self.subfolders = subfolders
    }

    /// The order a folder uses: its own, else the nearest folder above's,
    /// else the standard one.
    public func sortOrder(of folder: FolderPath) -> SortOrder {
        var current: FolderPath? = folder
        while let path = current {
            if let own = settings[path]?.ownOrder { return own }
            current = path.parent
        }
        return .standard
    }

    public func notes(in folder: FolderPath) -> [Note] { notesByFolder[folder] ?? [] }
    public func subfolders(of folder: FolderPath) -> [FolderPath] { subfolders[folder] ?? [] }

    /// Every note in the folder and the folders below it.
    public func notes(under folder: FolderPath) -> [Note] {
        notes(in: folder) + subfolders(of: folder).flatMap { notes(under: $0) }
    }

    /// The folder's children in order: drafts first, newest first; then, in
    /// Manual, the writer's order (children it doesn't know first, newest
    /// first); otherwise folders, then notes, each sorted.
    public func children(of folder: FolderPath) -> [FolderChild] {
        let all = notes(in: folder)
        let drafts = all.filter(\.isDraft).sorted { $0.created > $1.created }.map(FolderChild.note)
        let filed = all.filter { !$0.isDraft }
        let order = sortOrder(of: folder)
        let folders = subfolders(of: folder)

        guard order.sort != .manual else {
            let items = folders.map(FolderChild.folder) + filed.map(FolderChild.note)
            let positions = Dictionary((settings[folder]?.order ?? []).enumerated().map { (Self.normalized($1), $0) },
                                       uniquingKeysWith: { first, _ in first })
            let position: (FolderChild) -> Int? = { child in child.orderKey.flatMap { positions[Self.normalized($0)] } }
            let known = items.filter { position($0) != nil }.sorted { position($0)! < position($1)! }
            let unknown = items.filter { position($0) == nil }.sorted { isNewer($0, $1, by: .updated) }
            return drafts + unknown + known
        }
        let sortedFolders = folders.map(FolderChild.folder).sorted { isBefore($0, $1, order) }
        let sortedNotes = filed.map(FolderChild.note).sorted { isBefore($0, $1, order) }
        return drafts + sortedFolders + sortedNotes
    }

    /// `items` in the order `order` puts them, for flat lists.
    public func sorted(_ notes: [Note], by order: SortOrder) -> [Note] {
        let order = order.sort == .manual ? SortOrder.standard : order
        let drafts = notes.filter(\.isDraft).sorted { $0.created > $1.created }
        let filed = notes.filter { !$0.isDraft }.map(FolderChild.note).sorted { isBefore($0, $1, order) }
        return drafts + filed.compactMap { if case .note(let note) = $0 { note } else { nil } }
    }

    // MARK: Comparing

    private func isBefore(_ a: FolderChild, _ b: FolderChild, _ order: SortOrder) -> Bool {
        if order.sort == .title {
            let result = title(of: a).localizedStandardCompare(title(of: b))
            if result != .orderedSame { return order.reversed ? result == .orderedDescending : result == .orderedAscending }
            return tieBreak(a, b)
        }
        let (da, db) = (date(of: a, by: order.sort), date(of: b, by: order.sort))
        if da != db { return order.reversed ? da < db : da > db }
        return tieBreak(a, b)
    }

    private func isNewer(_ a: FolderChild, _ b: FolderChild, by sort: NoteSort) -> Bool {
        isBefore(a, b, SortOrder(sort))
    }

    private func tieBreak(_ a: FolderChild, _ b: FolderChild) -> Bool {
        name(of: a).localizedStandardCompare(name(of: b)) == .orderedAscending
    }

    private func title(of child: FolderChild) -> String {
        switch child {
        case .folder(let path): path.name ?? ""
        case .note(let note): note.displayTitle
        }
    }

    private func name(of child: FolderChild) -> String {
        switch child {
        case .folder(let path): path.string
        case .note(let note): note.relativePath ?? ""
        }
    }

    /// A note's date, or the newest of the notes in a folder (and below).
    private func date(of child: FolderChild, by sort: NoteSort) -> Date {
        switch child {
        case .note(let note): sort == .created ? note.created : note.modified
        case .folder(let path):
            notes(under: path).map { sort == .created ? $0.created : $0.modified }.max() ?? .distantPast
        }
    }

    /// Order keys compare the way file names do on a case-insensitive volume.
    static func normalized(_ key: String) -> String {
        key.precomposedStringWithCanonicalMapping.lowercased()
    }
}
