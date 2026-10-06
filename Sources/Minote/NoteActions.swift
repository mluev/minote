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

/// The word counter in the bottom corner. Click to switch between words,
/// characters and reading time.
struct WordCounter: View {
    let windowState: WindowState
    @AppStorage(PreferenceKey.counterMetric) private var metric = Metric.words

    enum Metric: String {
        case words, characters, readingTime

        var next: Metric {
            switch self {
            case .words: .characters
            case .characters: .readingTime
            case .readingTime: .words
            }
        }
    }

    var body: some View {
        Button {
            metric = metric.next
        } label: {
            Text(label)
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Click to switch between words, characters and reading time")
        .accessibilityLabel(label)
    }

    private var label: String {
        let statistics = windowState.statistics
        let suffix = windowState.statisticsAreForSelection ? " selected" : ""
        switch metric {
        case .words:
            return "\(statistics.words.formatted()) \(statistics.words == 1 ? "word" : "words")\(suffix)"
        case .characters:
            return "\(statistics.characters.formatted()) \(statistics.characters == 1 ? "character" : "characters")\(suffix)"
        case .readingTime:
            let minutes = statistics.readingMinutes
            return minutes == 0 ? "No reading time" : "\(minutes) min read\(suffix)"
        }
    }
}

/// File ▸ Rename… sheet.
struct RenameSheet: View {
    let note: Note
    let library: Library
    let dismiss: () -> Void
    @ViewState private var name: String

    init(note: Note, library: Library, dismiss: @escaping () -> Void) {
        self.note = note
        self.library = library
        self.dismiss = dismiss
        _name = ViewState(initialValue: note.fileStem ?? note.title)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename Note")
                .font(.headline)
            Text("The file keeps this name instead of following its first line.")
                .font(.callout)
                .foregroundStyle(.secondary)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(commit)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: dismiss)
                    .keyboardShortcut(.cancelAction)
                Button("Rename", action: commit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.isBlank)
            }
        }
        .padding(20)
        .frame(width: 360)
    }

    private func commit() {
        guard !name.isBlank else { return }
        let id = note.id, newName = name
        dismiss()
        Task { await library.rename(id, to: newName) }
    }
}
