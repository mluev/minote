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
    /// A locked note whose text isn't in memory: the library is locked.
    public private(set) var isSealed = false
    /// A draft to be written as a locked note (whole-library lock, New Locked Note).
    public internal(set) var lockOnCreate = false

    /// Full text as last loaded from or saved to disk, or nothing while the
    /// note is sealed. While the note is open, the editor holds the live text
    /// and the library pulls it when saving.
    @ObservationIgnored var content: NoteContent {
        didSet {
            if isSealed != content.isSealed { isSealed = content.isSealed }
        }
    }
    /// The password record of a locked note's file.
    @ObservationIgnored var lockRecord: KeyRecord?
    @ObservationIgnored var stamp: FileStamp?
    @ObservationIgnored var autoNameTag: String?
    /// Bumped on every edit; `savedRevision` catches up when a save lands.
    @ObservationIgnored var revision = 0
    @ObservationIgnored var savedRevision = 0

    /// The text, or nil while the note is sealed: never mistake that for empty.
    public var text: String? { content.text }

    /// Whether the note is locked: its file is sealed, or will be (a draft).
    public var isLocked: Bool { fileURL.map(NoteNaming.isLockedFile) ?? lockOnCreate }

    /// Whether the note is known to be empty. A sealed note's text is unknown,
    /// except for edits made before it was sealed, and for a draft (all of a
    /// draft's text is such edits).
    var isKnownBlank: Bool {
        switch content {
        case .plain(let text): text.isBlank
        case .sealed(let pending): pending?.isBlank ?? isDraft
        }
    }

    /// The title, or "New Note" while there's none.
    public var displayTitle: String { title.isEmpty ? "New Note" : title }
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
        content = .plain("")
    }

    /// A note backed by a scanned file. A locked note the scan couldn't open
    /// starts sealed.
    init(file: ScannedFile, content: ScannedContent) {
        id = UUID()
        fileURL = file.url
        title = ""
        excerpt = ""
        modified = file.stamp.modified
        isAutoNamed = false
        switch content {
        case .plain(let text):
            self.content = .plain(text)
        case .locked(let record, let text):
            self.content = text.map(NoteContent.plain) ?? .sealed(pending: nil)
            lockRecord = record
        }
        isSealed = self.content.isSealed
        stamp = file.stamp
        autoNameTag = file.autoNameTag
        refreshAutoNamed()
        updateDerived()
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

    /// Recomputes title and excerpt from the text in memory. A sealed note is
    /// titled by its file name, and a locked note never shows an excerpt.
    func updateDerived() {
        if let text {
            updateDerived(from: text.prefix(NoteNaming.prefixLength))
        } else {
            if let stem = fileStem, title != stem { title = stem }
            if !excerpt.isEmpty { excerpt = "" }
        }
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
        let newExcerpt = isLocked ? "" : NoteNaming.excerpt(of: prefix, skippingTitleLine: skipFirstLine)
        if title != newTitle { title = newTitle }
        if excerpt != newExcerpt { excerpt = newExcerpt }
    }
}

/// A note's text as the library holds it.
enum NoteContent {
    case plain(String)
    /// A locked note while the library is locked: its text isn't in memory.
    /// `pending` holds edits made before locking, already sealed, until
    /// they're on disk.
    case sealed(pending: SealedText?)

    var text: String? {
        if case .plain(let text) = self { text } else { nil }
    }

    var isSealed: Bool {
        if case .sealed = self { true } else { false }
    }
}

/// Text sealed in memory, waiting to be written.
struct SealedText: Sendable {
    let data: Data
    let isBlank: Bool
}
