import Foundation

extension Library {
    /// The note a relative link points to: `Other note.md`, `Other note`, or
    /// `../Notes/Other note.md` all find the note whose file is "Other note.md".
    public func note(linkedAs path: String) -> Note? {
        let name = (path as NSString).lastPathComponent
        guard !name.isEmpty else { return nil }
        let stem = NoteNaming.isNoteFile(URL(fileURLWithPath: name)) ? (name as NSString).deletingPathExtension : name
        return notes.first { $0.fileURL?.lastPathComponent.caseInsensitiveCompare(name) == .orderedSame }
            ?? notes.first { $0.fileStem?.caseInsensitiveCompare(stem) == .orderedSame }
            ?? notes.first { $0.title.caseInsensitiveCompare(stem) == .orderedSame }
    }
}
