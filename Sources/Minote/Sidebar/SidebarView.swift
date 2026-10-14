import AppKit
import MinoteEditor
import MinoteKit
import SwiftUI

/// The library: every note, newest first, with search and a "+" button.
/// Its own rows rather than a system list: the page's paper a shade darker,
/// and a soft rounded selection instead of the accent-colored capsule. The
/// highlighted row is this tab's note; opening a note follows the tab rules
/// (`Workspace.open(note:)`).
struct SidebarView: View {
    @Bindable var library: Library
    @Bindable var windowState: WindowState
    let workspace: Workspace
    @Environment(\.undoManager) private var undoManager
    @FocusState private var isListFocused: Bool
    @FocusState private var isSearchFocused: Bool
    @ViewState private var hoveredID: Note.ID? = nil
    @AppStorage(PreferenceKey.appearance) private var theme = PageTheme.system

    var body: some View {
        let notes = library.visibleNotes
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(notes) { note in
                        NoteRow(note: note, palette: theme.palette, isSelected: note.id == windowState.noteID, isHovered: note.id == hoveredID)
                            .id(note.id)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                // ⌘-click: a tab of its own.
                                let newTab = NSEvent.modifierFlags.contains(.command)
                                isListFocused = true
                                workspace.open(note: note.id, newTab: newTab, focus: false)
                                keepBrowsing(note.id)
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
            .onChange(of: windowState.noteID, initial: true) { _, id in
                guard let id else { return }
                proxy.scrollTo(id)
            }
        }
        .background(Color(nsColor: theme.palette.sidebarBackground).ignoresSafeArea())
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
            windowState.editor?.focus()
            return .handled
        }
        .onDeleteCommand {
            if let id = windowState.noteID, library.note(with: id) != nil { trash(id) }
        }
        .searchable(text: $library.searchText, placement: .sidebar, prompt: "Search")
        .searchFocused($isSearchFocused)
        .onChange(of: windowState.searchFocusRequest) {
            isSearchFocused = true
        }
        .onChange(of: windowState.sidebarFocusRequest) {
            isListFocused = true
        }
        .overlay {
            if notes.isEmpty && !library.searchText.isEmpty {
                ContentUnavailableView.search(text: library.searchText)
            }
        }
        .toolbar {
            ToolbarItem {
                Button {
                    workspace.newNote()
                } label: {
                    Label("New Note", systemImage: "plus")
                }
                .help("New Note")
            }
        }
    }

    /// ↑/↓ open the previous or next note in the list, under the tab rules:
    /// browsing replaces an untouched tab, so it stays in one tab.
    private func select(offset: Int, in notes: [Note]) {
        guard !notes.isEmpty else { return }
        let current = notes.firstIndex { $0.id == windowState.noteID }
        let index = current.map { min(max($0 + offset, 0), notes.count - 1) } ?? 0
        let id = notes[index].id
        guard id != windowState.noteID else { return }
        workspace.open(note: id, focus: false)
        keepBrowsing(id)
    }

    /// The note may have opened in another tab: its list takes the keyboard,
    /// so ↑/↓ go on from there.
    private func keepBrowsing(_ id: Note.ID) {
        guard windowState.noteID != id, let editor = library.editor(showing: id) as? EditorCoordinator else { return }
        editor.windowState?.sidebarFocusRequest += 1
    }

    private func trash(_ id: Note.ID) {
        library.moveToTrash(id, undoManager: undoManager, actionName: "Move to Trash")
    }

    @ViewBuilder
    private func contextMenu(for note: Note) -> some View {
        Button("Open in New Tab") {
            workspace.open(note: note.id, newTab: true, focus: false)
        }
        Divider()
        Button("Show in Finder") {
            if let url = note.fileURL { NSWorkspace.shared.activateFileViewerSelecting([url]) }
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
        Button("Move to Trash") { trash(note.id) }
    }
}

/// One library row: title, a two-line preview and the date, on a rounded
/// plate when selected or under the pointer.
struct NoteRow: View {
    let note: Note
    let palette: EditorPalette
    var isSelected = false
    var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(note.displayTitle)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color(nsColor: note.title.isEmpty ? palette.syntax : palette.text))
                .lineLimit(1)
            if !note.excerpt.isEmpty {
                Text(note.excerpt)
                    .font(.system(size: 12))
                    .foregroundStyle(Color(nsColor: palette.quote))
                    .lineLimit(2)
            }
            Text(NoteDateText.string(for: note.modified))
                .font(.system(size: 11))
                .foregroundStyle(Color(nsColor: palette.syntax))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background {
            if isSelected || isHovered {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(nsColor: isSelected ? palette.sidebarSelection : palette.sidebarHover))
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
