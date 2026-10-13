import AppKit
import MinoteKit
import SwiftUI
import MinoteEditor

/// Window-level state shared by the sidebar, the editor and the menus.
@Observable
final class WindowState {
    var columnVisibility: NavigationSplitViewVisibility = .all
    var isSidebarFocused = false
    var isEditorFocused = false
    /// Bumped by Edit ▸ Search All Notes to focus the search field.
    var searchFocusRequest = 0
    /// The note being renamed (File ▸ Rename…), if any.
    var renaming: Note?

    // Word counter.
    var showsCounter = false
    var statistics = TextStatistics(words: 0, characters: 0)
    var statisticsAreForSelection = false

    /// View ▸ Preview: the note is read, not edited.
    var isPreviewing = false
    /// The text settings popover (font, size, theme) is open.
    var isShowingTextSettings = false

    /// The editor, for Format menu commands.
    @ObservationIgnored weak var editor: EditorCoordinator?
}
