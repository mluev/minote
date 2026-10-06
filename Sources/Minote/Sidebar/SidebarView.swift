import MinoteKit
import SwiftUI

/// The library: every note, newest first, with search and a "+" button.
struct SidebarView: View {
    @Bindable var library: Library
    @Bindable var windowState: WindowState
    @Environment(\.undoManager) private var undoManager
    @FocusState private var isListFocused: Bool
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        let notes = library.visibleNotes
        List(selection: $library.selectedID) {
            ForEach(notes) { note in
                NoteRow(note: note)
                    .tag(note.id)
                    .contextMenu { contextMenu(for: note) }
            }
        }
        .listStyle(.sidebar)
        .focused($isListFocused)
        .onChange(of: isListFocused) { _, focused in
            windowState.isSidebarFocused = focused
        }
        .searchable(text: $library.searchText, placement: .sidebar, prompt: "Search")
        .searchFocused($isSearchFocused)
        .onChange(of: windowState.searchFocusRequest) {
            isSearchFocused = true
        }
        .onDeleteCommand {
            if let id = library.selectedID {
                NoteActions.moveToTrash(id, in: library, undoManager: undoManager)
            }
        }
        .onKeyPress(.return) {
            library.editor?.focus()
            return .handled
        }
        .overlay {
            if notes.isEmpty && !library.searchText.isEmpty {
                ContentUnavailableView.search(text: library.searchText)
            }
        }
        .toolbar {
            ToolbarItem {
                Button {
                    library.newNote()
                } label: {
                    Label("New Note", systemImage: "plus")
                }
                .help("New Note")
            }
        }
    }

    @ViewBuilder
    private func contextMenu(for note: Note) -> some View {
        Button("Show in Finder") {
            NoteActions.revealInFinder(note)
        }
        .disabled(note.isDraft)
        Button("Rename…") {
            windowState.renaming = note
        }
        .disabled(note.isBlankDraft)
        Button("Duplicate") {
            Task { await library.duplicate(note.id) }
        }
        .disabled(note.isDraft)
        Divider()
        Button("Move to Trash") {
            NoteActions.moveToTrash(note.id, in: library, undoManager: undoManager)
        }
    }
}

/// One library row: title, a two-line preview and the date.
struct NoteRow: View {
    let note: Note

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(note.title.isEmpty ? "New Note" : note.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(note.title.isEmpty ? .secondary : .primary)
                .lineLimit(1)
            if !note.excerpt.isEmpty {
                Text(note.excerpt)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Text(NoteDateText.string(for: note.modified))
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }
}
