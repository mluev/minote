import MinoteEditor
import MinoteKit
import SwiftUI

/// The library: every note, newest first, with search and a "+" button.
/// Its own rows rather than a system list: the page's paper a shade darker,
/// and a soft rounded selection instead of the accent-colored capsule.
struct SidebarView: View {
    @Bindable var library: Library
    @Bindable var windowState: WindowState
    @Environment(\.undoManager) private var undoManager
    @FocusState private var isListFocused: Bool
    @FocusState private var isSearchFocused: Bool
    @ViewState private var hoveredID: Note.ID? = nil

    var body: some View {
        let notes = library.visibleNotes
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(notes) { note in
                        NoteRow(note: note, isSelected: note.id == library.selectedID, isHovered: note.id == hoveredID)
                            .id(note.id)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                library.selectedID = note.id
                                isListFocused = true
                            }
                            .onHover { inside in
                                if inside {
                                    hoveredID = note.id
                                } else if hoveredID == note.id {
                                    hoveredID = nil
                                }
                            }
                            .contextMenu { contextMenu(for: note) }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
            .onChange(of: library.selectedID) { _, id in
                guard let id else { return }
                proxy.scrollTo(id)
            }
        }
        .background(Color(nsColor: EditorTheme.sidebarBackground).ignoresSafeArea())
        .focusable()
        .focusEffectDisabled()
        .focused($isListFocused)
        .onChange(of: isListFocused) { _, focused in
            windowState.isSidebarFocused = focused
        }
        .onKeyPress(.upArrow) {
            select(offset: -1, in: notes)
            return .handled
        }
        .onKeyPress(.downArrow) {
            select(offset: 1, in: notes)
            return .handled
        }
        .onKeyPress(.return) {
            library.editor?.focus()
            return .handled
        }
        .onDeleteCommand {
            if let id = library.selectedID {
                NoteActions.moveToTrash(id, in: library, undoManager: undoManager)
            }
        }
        .searchable(text: $library.searchText, placement: .sidebar, prompt: "Search")
        .searchFocused($isSearchFocused)
        .onChange(of: windowState.searchFocusRequest) {
            isSearchFocused = true
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

    /// ↑/↓ move to the previous or next note in the list.
    private func select(offset: Int, in notes: [Note]) {
        guard !notes.isEmpty else { return }
        let current = notes.firstIndex { $0.id == library.selectedID }
        let index = current.map { min(max($0 + offset, 0), notes.count - 1) } ?? 0
        library.selectedID = notes[index].id
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

/// One library row: title, a two-line preview and the date, on a rounded
/// plate when selected or under the pointer.
struct NoteRow: View {
    let note: Note
    var isSelected = false
    var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(note.title.isEmpty ? "New Note" : note.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color(nsColor: note.title.isEmpty ? EditorTheme.syntax : EditorTheme.text))
                .lineLimit(1)
            if !note.excerpt.isEmpty {
                Text(note.excerpt)
                    .font(.system(size: 12))
                    .foregroundStyle(Color(nsColor: EditorTheme.quote))
                    .lineLimit(2)
            }
            Text(NoteDateText.string(for: note.modified))
                .font(.system(size: 11))
                .foregroundStyle(Color(nsColor: EditorTheme.syntax))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background {
            if isSelected || isHovered {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(nsColor: isSelected ? EditorTheme.sidebarSelection : EditorTheme.sidebarHover))
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
