import MinoteEditor
import MinoteKit
import SwiftUI

/// Library on the left (or first, on iPhone), the page on the right.
struct RootView: View {
    @Bindable var library: Library
    @Bindable var state: MobileState
    let storage: LibraryStorageSwitcher
    let lock: LockController
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationSplitView(preferredCompactColumn: $state.preferredColumn) {
            NotesList(library: library, state: state, storage: storage)
        } detail: {
            EditorScreen(library: library, state: state, lock: lock)
        }
        .overlay {
            if library.isLibraryLocked {
                MobileLockScreen(lock: lock)
                    .ignoresSafeArea()
            } else if scenePhase != .active && library.isUnlocked && library.hasLockedNotes {
                PrivacyCover()
            }
        }
        .sheet(isPresented: $state.isShowingSecurity) {
            MobileSecuritySettings(lock: lock) { state.isShowingSecurity = false }
        }
        .sheet(item: $state.passwordRequest) { request in
            MobilePasswordSheet(request: request, lock: lock) { state.passwordRequest = nil }
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
                    .listRowBackground(sizeClass == .compact ? Color(uiColor: EditorPalette.standard.background) : nil)
                    .swipeActions {
                        Button("Delete", systemImage: "trash", role: .destructive) { trash(note) }
                    }
                    .contextMenu { menu(for: note) }
            }
        }
        .modifier(LibraryListStyle(compact: sizeClass == .compact))
        .scrollContentBackground(sizeClass == .compact ? .hidden : .automatic)
        .background(sizeClass == .compact ? Color(uiColor: EditorPalette.standard.background) : .clear)
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
                Button("Locked Notes…", systemImage: "lock") { state.isShowingSecurity = true }
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
        LockMenuItem(note: note, library: library, state: state)
        // A locked note's file is ciphertext: nothing to share.
        if let url = note.fileURL, !note.isLocked {
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
            HStack(spacing: 4) {
                if note.isLocked {
                    Image(systemName: note.isSealed ? "lock.fill" : "lock.open.fill")
                        .accessibilityLabel(note.isSealed ? "Locked" : "Unlocked")
                }
                Text(NoteDateText.string(for: note.modified))
            }
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
    let lock: LockController
    @Environment(\.horizontalSizeClass) private var sizeClass

    private var preferences = EditorPreferences()

    init(library: Library, state: MobileState, lock: LockController) {
        self.library = library
        self.state = state
        self.lock = lock
    }

    var body: some View {
        MobileEditorView(
            library: library,
            state: state,
            configuration: preferences.configuration(preview: state.isPreviewing),
            isWide: sizeClass == .regular
        )
        .ignoresSafeArea(.container, edges: .bottom)
        // Over the editor, never instead of it: removing it would detach it from the library.
        .overlay {
            if let note = library.selectedNote, note.isSealed {
                LockedNoteView(note: note, lock: lock)
            }
        }
        .background(Color(uiColor: EditorPalette.standard.background))
        .navigationTitle(library.selectedNote?.displayTitle ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color(uiColor: EditorPalette.standard.background), for: .navigationBar)
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
                .disabled(library.selectedNote?.isSealed == true)
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
                LockMenuItem(note: note, library: library, state: state)
                if let url = note.fileURL, !note.isLocked {
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
    let lock: LockController

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Note") {
                library.newNote()
                state.preferredColumn = .detail
            }
            .keyboardShortcut("n")
            .disabled(library.isLibraryLocked)
            Button("Lock Now") { lock.lockNow() }
                .keyboardShortcut("l", modifiers: [.command, .control])
                .disabled(!library.isUnlocked)
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

/// Lock Note or Remove Lock, for the list's and the page's menus.
struct LockMenuItem: View {
    let note: Note
    let library: Library
    let state: MobileState

    var body: some View {
        if note.isLocked {
            Button("Remove Lock", systemImage: "lock.open") {
                Task {
                    do { try await library.removeLock(note.id) } catch {
                        library.presentedError = LibraryError(title: "Couldn't remove the lock", message: error.localizedDescription)
                    }
                }
            }
            .disabled(note.isSealed || library.lockScope == .library)
        } else {
            Button("Lock Note", systemImage: "lock") { lockNote() }
                .disabled(note.isBlankDraft)
        }
    }

    private func lockNote() {
        guard library.hasPassword else {
            if library.canSetPassword { state.passwordRequest = MobilePasswordRequest(kind: .set, thenLock: note.id) }
            return
        }
        Task {
            if !library.isUnlocked, !(await state.lock?.unlockWithBiometrics(reason: "lock this note") ?? false) {
                state.passwordRequest = MobilePasswordRequest(kind: .unlock, thenLock: note.id)
                return
            }
            do { try await library.lock(note.id) } catch {
                library.presentedError = LibraryError(title: "Couldn't lock the note", message: error.localizedDescription)
            }
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
