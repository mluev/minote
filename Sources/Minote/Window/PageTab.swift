import AppKit
import MinoteEditor
import MinoteKit
import SwiftUI

/// One tab: its own editor, showing a library note or a file opened from
/// elsewhere. A tab lives in a `PageWindow`'s tab bar and can move to another
/// window; its editor (and the note's caret, scroll and undo) goes with it.
@Observable
final class PageTab: Identifiable {
    enum Content {
        /// The library's notes, one at a time.
        case library
        /// A file opened from elsewhere, alone.
        case file(OpenedFile)
    }

    @ObservationIgnored let content: Content
    /// The library this tab's note belongs to.
    @ObservationIgnored let library: Library
    @ObservationIgnored let editor: EditorCoordinator
    /// The window whose tab bar holds this tab.
    @ObservationIgnored weak var window: PageWindow?

    /// The note this tab shows.
    var noteID: Note.ID?
    /// Typed in since it showed its note: the next note opens in a new tab
    /// instead of replacing this one. Set once per note, not per keystroke.
    var isEdited = false
    /// View ▸ Preview: the note is read, not edited.
    var isPreviewing = false
    var isEditorFocused = false

    // Word counter.
    var showsCounter = false
    var statistics = TextStatistics(words: 0, characters: 0)
    var statisticsAreForSelection = false

    init(content: Content, library: Library) {
        self.content = content
        self.library = library
        editor = EditorCoordinator(configuration: EditorPreferences().configuration(preview: false, paper: PageTheme.saved.paper))
        editor.library = library
        editor.tab = self
    }

    var file: OpenedFile? {
        if case .file(let file) = content { return file }
        return nil
    }

    var isLibraryTab: Bool { file == nil }

    /// What `OpenPlacement` needs to know about this tab.
    var placement: OpenPlacement.FrontTab {
        isLibraryTab ? .libraryNote(edited: isEdited) : .outsideFile
    }

    var note: Note? {
        noteID.flatMap(library.note(with:))
    }

    /// The tab's label: the note's title, or a file's name.
    var title: String {
        if let file { return file.url.lastPathComponent }
        return note?.displayTitle ?? "New Note"
    }

    /// Shown in italics: nobody typed in it, so the next note opened takes its place.
    var isUntouched: Bool { isLibraryTab && !isEdited }

    /// Kept tabs are by file name: a renamed note (or a saved draft) changes them.
    var fileName: String? {
        isLibraryTab ? note?.fileURL?.lastPathComponent : nil
    }
}
