import Foundation
import Observation

/// One note in the library: either a file on disk or an in-memory draft that
/// hasn't been written yet. Observable per property, so typing in one note only
/// re-renders that note's sidebar row.
@MainActor
@Observable
public final class Note: Identifiable {
    public nonisolated let id: UUID

    /// nil while the note is a draft.
    public internal(set) var fileURL: URL?
    /// Sidebar title: the live first line for drafts and auto-named files,
    /// the file name for everything else.
    public internal(set) var title: String
    public internal(set) var excerpt: String
    public internal(set) var modified: Date
    /// Whether the file name follows the first line (see `NoteFileStore.autoNameAttribute`).
    public internal(set) var isAutoNamed: Bool

    /// Full text as last loaded from or saved to disk. While the note is open,
    /// the editor holds the live text and the library pulls it when saving.
    @ObservationIgnored public internal(set) var text: String
    @ObservationIgnored var stamp: FileStamp?
    @ObservationIgnored var autoNameTag: String?
    /// Bumped on every edit; `savedRevision` catches up when a save lands.
    @ObservationIgnored var revision = 0
    @ObservationIgnored var savedRevision = 0

    public var isDraft: Bool { fileURL == nil }
    /// A draft without a word yet: nothing to rename, duplicate or reveal.
    public var isBlankDraft: Bool { isDraft && title.isEmpty }
    public var hasUnsavedChanges: Bool { revision != savedRevision }

    /// File name without extension, or nil for drafts.
    public var fileStem: String? { fileURL?.deletingPathExtension().lastPathComponent }

    /// A new, empty draft.
    init(draftCreatedAt date: Date) {
        id = UUID()
        fileURL = nil
        title = ""
        excerpt = ""
        modified = date
        isAutoNamed = true
        text = ""
    }

    /// A note backed by a scanned file.
    init(file: ScannedFile, text: String) {
        id = UUID()
        fileURL = file.url
        title = ""
        excerpt = ""
        modified = file.stamp.modified
        isAutoNamed = false
        self.text = text
        stamp = file.stamp
        autoNameTag = file.autoNameTag
        refreshAutoNamed()
        updateDerived(from: text.prefix(NoteNaming.prefixLength))
    }

    /// Re-evaluates whether the file name still follows the first line.
    func refreshAutoNamed() {
        let value: Bool
        if let stem = fileStem {
            value = autoNameTag.map { NoteNaming.stemsMatch($0, stem) } ?? false
        } else {
            value = true
        }
        if isAutoNamed != value { isAutoNamed = value }
    }

    /// Recomputes title and excerpt from the beginning of the text.
    func updateDerived(from prefix: some StringProtocol) {
        let firstLine = NoteNaming.title(of: prefix)
        let newTitle: String
        let skipFirstLine: Bool
        if isDraft || isAutoNamed {
            newTitle = firstLine
            skipFirstLine = true
        } else {
            let stem = fileStem ?? ""
            newTitle = stem
            // Don't repeat the title in the excerpt when the first line is the title.
            skipFirstLine = NoteNaming.stemsMatch(NoteNaming.fileStem(forTitle: firstLine), stem)
        }
        let newExcerpt = NoteNaming.excerpt(of: prefix, skippingTitleLine: skipFirstLine)
        if title != newTitle { title = newTitle }
        if excerpt != newExcerpt { excerpt = newExcerpt }
    }
}
