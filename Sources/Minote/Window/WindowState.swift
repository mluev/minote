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

    /// The editor, for Format menu commands.
    @ObservationIgnored weak var editor: EditorCoordinator?
}

/// User actions reachable from more than one place (menus, context menus, keys).
enum NoteActions {
    /// Moves a note to the Trash and registers "Undo Move to Trash".
    static func moveToTrash(_ id: Note.ID, in library: Library, undoManager: UndoManager?) {
        Task {
            guard let receipt = await library.moveToTrash(id), let undoManager else { return }
            undoManager.registerUndo(withTarget: library) { library in
                Task { @MainActor in await library.restore(receipt) }
            }
            undoManager.setActionName("Move to Trash")
        }
    }

    static func revealInFinder(_ note: Note?) {
        guard let url = note?.fileURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    static func openLibraryFolder(_ library: Library) {
        NSWorkspace.shared.open(library.directory)
    }
}
