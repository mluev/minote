import MinoteEditor
import MinoteKit
import SwiftUI

/// Library on the left (or first, on iPhone), the page on the right.
struct RootView: View {
    @Bindable var library: Library
    @Bindable var state: MobileState
    let storage: LibraryStorageSwitcher

    var body: some View {
        NavigationSplitView(preferredCompactColumn: $state.preferredColumn) {
            NotesList(library: library, state: state, storage: storage)
        } detail: {
            EditorScreen(library: library, state: state)
        }
        .tint(Color(uiColor: EditorTheme.caret))
        .alert("Rename Note", isPresented: Binding(
            get: { state.renaming != nil },
            set: { if !$0 { state.renaming = nil } }
        )) {
            RenameField(library: library, state: state)
        } message: {
            Text("The file keeps this name instead of following its first line.")
        }
        .libraryErrorAlert(library)
    }
}

/// Every note, newest first, with search and a "+" button.
struct NotesList: View {
    @Bindable var library: Library
    let state: MobileState
    let storage: LibraryStorageSwitcher
    @Environment(\.undoManager) private var undoManager
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        let notes = library.visibleNotes
        List(selection: $library.selectedID) {
            ForEach(notes) { note in
                MobileNoteRow(note: note)
                    .tag(note.id)
                    .listRowBackground(sizeClass == .compact ? Color(uiColor: EditorTheme.background) : nil)
                    .swipeActions {
                        Button("Delete", systemImage: "trash", role: .destructive) { trash(note) }
                    }
                    .contextMenu { menu(for: note) }
            }
        }
        .modifier(LibraryListStyle(compact: sizeClass == .compact))
        .scrollContentBackground(sizeClass == .compact ? .hidden : .automatic)
        .background(sizeClass == .compact ? Color(uiColor: EditorTheme.background) : .clear)
        .searchable(text: $library.searchText, prompt: "Search")
        .overlay {
            if notes.isEmpty && !library.searchText.isEmpty {
                ContentUnavailableView.search(text: library.searchText)
            }
        }
        .navigationTitle("Notes")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("New Note", systemImage: "plus") {
                    library.newNote()
                    state.preferredColumn = .detail
                }
                .keyboardShortcut("n")
            }
            ToolbarItem(placement: .secondaryAction) {
                Toggle(isOn: Binding(
                    get: { storage.storage == .iCloud },
                    set: { keep in Task { await storage.move(to: keep ? .iCloud : .local) } }
                )) {
                    Label(storage.isICloudAvailable ? "Keep in iCloud Drive" : "iCloud Drive Unavailable", systemImage: "icloud")
                }
                .disabled(storage.isMoving || (!storage.isICloudAvailable && storage.storage == .local))
            }
        }
    }

    @ViewBuilder
    private func menu(for note: Note) -> some View {
        Button("Rename…", systemImage: "pencil") { state.renaming = note }
            .disabled(note.isBlankDraft)
        Button("Duplicate", systemImage: "plus.square.on.square") {
            Task { await library.duplicate(note.id) }
        }
        .disabled(note.isDraft)
        if let url = note.fileURL {
            ShareLink(item: url)
        }
        Divider()
        Button("Delete", systemImage: "trash", role: .destructive) { trash(note) }
    }

    private func trash(_ note: Note) {
        library.moveToTrash(note.id, undoManager: undoManager, actionName: "Delete Note")
    }
}

struct MobileNoteRow: View {
    let note: Note

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(note.displayTitle)
                .font(.headline)
                .foregroundStyle(note.title.isEmpty ? .secondary : .primary)
                .lineLimit(1)
            if !note.excerpt.isEmpty {
                Text(note.excerpt)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Text(NoteDateText.string(for: note.modified))
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }
}

/// The page, with everything else tucked into one menu.
struct EditorScreen: View {
    @Bindable var library: Library
    @Bindable var state: MobileState
    @Environment(\.horizontalSizeClass) private var sizeClass

    private var preferences = EditorPreferences()

    init(library: Library, state: MobileState) {
        self.library = library
        self.state = state
    }

    var body: some View {
        MobileEditorView(
            library: library,
            state: state,
            configuration: preferences.configuration(preview: state.isPreviewing),
            isWide: sizeClass == .regular
        )
        .ignoresSafeArea(.container, edges: .bottom)
        .background(Color(uiColor: EditorTheme.background))
        .navigationTitle(library.selectedNote?.displayTitle ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color(uiColor: EditorTheme.background), for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    viewMenu
                } label: {
                    Label("View", systemImage: "ellipsis.circle")
                }
                .disabled(library.selectedNote == nil)
            }
        }
    }

    @ViewBuilder
    private var viewMenu: some View {
        Section(statisticsLine) {
            Toggle("Preview", systemImage: "eye", isOn: $state.isPreviewing)
        }
        Section {
            Toggle("Focus Mode", systemImage: "scope", isOn: preferences.$focusEnabled)
            Picker("Focus On", selection: preferences.$focusUnit) {
                Text("Sentence").tag(FocusMode.sentence)
                Text("Paragraph").tag(FocusMode.paragraph)
            }
            Toggle("Typewriter Mode", systemImage: "text.aligncenter", isOn: preferences.$typewriter)
            Toggle("Syntax Highlight", systemImage: "paintpalette", isOn: preferences.$syntaxHighlight)
            Toggle("Show Markdown Syntax", systemImage: "number", isOn: preferences.$showsSyntax)
        }
        Section {
            Picker("Font", selection: preferences.$fontFamily) {
                ForEach(EditorFontFamily.allCases) { Text($0.displayName).tag($0) }
            }
            ControlGroup {
                Button("Smaller", systemImage: "textformat.size.smaller") {
                    preferences.fontSize = max(preferences.fontSize - 1, EditorTheme.fontSizeRange.lowerBound)
                }
                Button("Larger", systemImage: "textformat.size.larger") {
                    preferences.fontSize = min(preferences.fontSize + 1, EditorTheme.fontSizeRange.upperBound)
                }
            }
        }
        if let note = library.selectedNote {
            Section {
                Button("Rename…", systemImage: "pencil") { state.renaming = note }
                    .disabled(note.isBlankDraft)
                if let url = note.fileURL {
                    ShareLink(item: url)
                }
            }
        }
    }

    private var statisticsLine: String {
        let statistics = state.statistics
        let words = "\(statistics.words.formatted()) \(statistics.words == 1 ? "word" : "words")"
        let minutes = statistics.readingMinutes
        return minutes > 0 ? "\(words) · \(minutes) min read" : words
    }
}

/// The text field inside the Rename alert.
struct RenameField: View {
    let library: Library
    @Bindable var state: MobileState

    var body: some View {
        TextField("Name", text: $state.renameText)
        Button("Cancel", role: .cancel) { state.renaming = nil }
        Button("Rename") {
            guard let note = state.renaming, !state.renameText.isBlank else { return }
            let newName = state.renameText
            state.renaming = nil
            Task { await library.rename(note.id, to: newName) }
        }
    }
}

/// Keyboard shortcuts and the iPad menu bar: the same Format menu as on the Mac.
struct MobileCommands: Commands {
    let library: Library
    let state: MobileState

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Note") {
                library.newNote()
                state.preferredColumn = .detail
            }
            .keyboardShortcut("n")
        }
        CommandGroup(after: .sidebar) {
            Toggle("Preview", isOn: Binding(get: { state.isPreviewing }, set: { state.isPreviewing = $0 }))
                .keyboardShortcut("r")
                .disabled(library.selectedNote == nil)
        }
        CommandGroup(replacing: .textFormatting) {
            FormatMenuItems(isEnabled: state.isEditorFocused) { state.editor?.perform($0) }
        }
    }
}

/// Plain paper list on iPhone, a sidebar on iPad.
private struct LibraryListStyle: ViewModifier {
    let compact: Bool

    func body(content: Content) -> some View {
        if compact {
            content.listStyle(.plain)
        } else {
            content.listStyle(.sidebar)
        }
    }
}
