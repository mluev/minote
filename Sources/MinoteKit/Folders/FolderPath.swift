import Foundation

/// A folder of the library, relative to the library folder: "" is the
/// library folder itself, "Work/Clients" a folder two levels down. The names
/// are the ones on disk, as a scan found them, so two paths are equal when
/// they're spelled alike.
public struct FolderPath: Hashable, Sendable, Comparable, CustomStringConvertible {
    public let components: [String]

    public static let root = FolderPath([])

    public init(_ components: [String]) {
        self.components = components.filter { !$0.isEmpty }
    }

    /// "Work/Clients" → ["Work", "Clients"]; "" is the root.
    public init(string: String) {
        self.init(string.split(separator: "/").map(String.init))
    }

    /// The folder holding `url`, if it lies inside `root`.
    public init?(folderOf url: URL, root: URL) {
        let parent = url.standardizedFileURL.deletingLastPathComponent().pathComponents
        let base = root.standardizedFileURL.pathComponents
        guard parent.count >= base.count, Array(parent.prefix(base.count)) == base else { return nil }
        self.init(Array(parent.dropFirst(base.count)))
    }

    public var string: String { components.joined(separator: "/") }
    public var description: String { string.isEmpty ? "/" : string }
    public var isRoot: Bool { components.isEmpty }
    /// The folder's own name, nil for the root.
    public var name: String? { components.last }
    /// How many folders down from the root.
    public var depth: Int { components.count }
    /// The folder above, nil for the root.
    public var parent: FolderPath? { isRoot ? nil : FolderPath(Array(components.dropLast())) }

    public func appending(_ name: String) -> FolderPath {
        FolderPath(components + [name])
    }

    /// Whether `other` lies below this folder (not this folder itself).
    public func isAncestor(of other: FolderPath) -> Bool {
        other.components.count > components.count && Array(other.components.prefix(components.count)) == components
    }

    /// This folder or one below it.
    public func contains(_ other: FolderPath) -> Bool {
        self == other || isAncestor(of: other)
    }

    /// `other` with this folder's place taken by `replacement`, for a folder
    /// renamed or moved: "Work/Clients" under "Work" → "Jobs" is "Jobs/Clients".
    public func rebasing(_ other: FolderPath, onto replacement: FolderPath) -> FolderPath {
        guard contains(other) else { return other }
        return FolderPath(replacement.components + other.components.dropFirst(components.count))
    }

    /// The folder's URL under the library folder `root`.
    public func url(in root: URL) -> URL {
        components.reduce(root) { $0.appendingPathComponent($1, isDirectory: true) }
    }

    /// A file's path relative to the library folder: "Work/Ideas.md", or
    /// "Ideas.md" at the root (the name alone, as earlier builds kept it).
    public func relativePath(ofFile name: String) -> String {
        isRoot ? name : "\(string)/\(name)"
    }

    public static func < (lhs: FolderPath, rhs: FolderPath) -> Bool {
        for (a, b) in zip(lhs.components, rhs.components) where a != b {
            return a.localizedStandardCompare(b) == .orderedAscending
        }
        return lhs.components.count < rhs.components.count
    }
}

extension FolderPath: Codable {
    public init(from decoder: any Decoder) throws {
        self.init(string: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(string)
    }
}
