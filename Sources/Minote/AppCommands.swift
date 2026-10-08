import AppKit
import MinoteKit
import SwiftUI
import MinoteEditor

/// Every action lives in the system menus; the window stays a blank page.
struct AppCommands: Commands {
    let library: Library
    let windowState: WindowState
    let storage: LibraryStorageSwitcher
    let openedFiles: OpenedFiles

    @Environment(\.openWindow) private var openWindow
    @AppStorage(PreferenceKey.fontFamily) private var fontFamily = EditorFontFamily.plexMono
    @AppStorage(PreferenceKey.fontSize) private var fontSize = EditorTheme.defaultFontSize
    @AppStorage(PreferenceKey.appearance) private var appearance = AppearancePreference.system
    @AppStorage(PreferenceKey.focusEnabled) private var focusEnabled = false
    @AppStorage(PreferenceKey.focusUnit) private var focusUnit = FocusMode.sentence
    @AppStorage(PreferenceKey.typewriter) private var typewriter = false
    @AppStorage(PreferenceKey.syntaxHighlight) private var syntaxHighlight = false
    @AppStorage(PreferenceKey.showCounter) private var showCounter = false
    @AppStorage(PreferenceKey.showsSyntax) private var showsSyntax = false

    var body: some Commands {
        SidebarCommands()
        TextEditingCommands()
        fileCommands
        editCommands
        formatMenu
        viewCommands
        CommandGroup(replacing: .help) {}
    }

    /// The window the menus act on: an opened file's when it's in front,
    /// otherwise the library's.
    private var front: (library: Library, windowState: WindowState) {
        if let session = openedFiles.frontSession { return (session.library, session.windowState) }
        return (library, windowState)
    }

    /// Brings the library window forward, also when it was hidden or closed.
    private func showLibrary() {
        if !openedFiles.showLibraryWindow() { openWindow(id: "main") }
    }

    /// Library commands don't apply to an opened file.
    private var isFileInFront: Bool { openedFiles.frontSession != nil }

    // MARK: File

    @CommandsBuilder private var fileCommands: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Note") {
                showLibrary()
                if library.isLoaded { library.newNote() }
            }
            .keyboardShortcut("n")
            Button("Open…") { openedFiles.showOpenPanel() }
                .keyboardShortcut("o")
            Menu("Open Recent") {
                ForEach(openedFiles.recents, id: \.self) { url in
                    Button(openedFiles.recentTitle(for: url)) { openedFiles.openRecent(url) }
                }
                Divider()
                Button("Clear Menu") { openedFiles.clearRecents() }
                    .disabled(openedFiles.recents.isEmpty)
            }
        }
        CommandGroup(after: .newItem) {
            Button("Duplicate") {
                guard let id = library.selectedID else { return }
                Task { await library.duplicate(id) }
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])
            .disabled(isFileInFront || library.selectedNote?.isDraft ?? true)
            Button("Rename…") { windowState.renaming = library.selectedNote }
                .disabled(isFileInFront || library.selectedNote?.isBlankDraft ?? true)
            Divider()
            Button("Show in Finder") { NoteActions.revealInFinder(front.library.selectedNote) }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(front.library.selectedNote?.fileURL == nil)
            Button("Show Library in Finder") { NoteActions.openLibraryFolder(library) }
            Toggle(storage.isICloudAvailable ? "Keep Notes in iCloud Drive" : "Keep Notes in iCloud Drive (iCloud Unavailable)", isOn: Binding(
                get: { storage.storage == .iCloud },
                set: { keep in Task { await storage.move(to: keep ? .iCloud : .local) } }
            ))
            .disabled(storage.isMoving || (!storage.isICloudAvailable && storage.storage == .local))
            Divider()
            // ⌘⌫ only while the list has focus; in the editor it deletes to the start of the line.
            Button("Move to Trash") {
                guard let id = library.selectedID else { return }
                NoteActions.moveToTrash(id, in: library, undoManager: NSApp.keyWindow?.undoManager)
            }
            .keyboardShortcut(.delete, modifiers: .command)
            .disabled(isFileInFront || !windowState.isSidebarFocused || library.selectedNote == nil)
        }
        CommandGroup(replacing: .printItem) {
            Button("Print…") {
                let front = self.front
                let title = front.library.selectedNote?.title ?? "Note"
                front.windowState.editor?.printNote(title: title.isEmpty ? "Note" : title)
            }
            .keyboardShortcut("p")
            .disabled(front.library.selectedNote == nil)
        }
    }

    // MARK: Edit

    @CommandsBuilder private var editCommands: some Commands {
        CommandGroup(after: .textEditing) {
            Button("Search All Notes") {
                if isFileInFront { showLibrary() }
                windowState.columnVisibility = .all
                windowState.searchFocusRequest += 1
            }
            .keyboardShortcut("f", modifiers: [.command, .shift])
        }
    }

    // MARK: Format

    private var formatMenu: some Commands {
        CommandMenu("Format") {
            format("Bold", .bold, "b")
            format("Italic", .italic, "i")
            format("Strikethrough", .strikethrough, "x", [.command, .shift])
            format("Code", .inlineCode, "c", [.command, .option])
            format("Link", .link, "k")
            Divider()
            Menu("Heading") {
                ForEach(1...6, id: \.self) { level in
                    format("Heading \(level)", .heading(level), KeyEquivalent(Character("\(level)")))
                }
                Divider()
                format("Body Text", .heading(0))
            }
            Divider()
            format("Bulleted List", .bulletedList, "l")
            format("Numbered List", .numberedList, "l", [.command, .option])
            format("Task List", .taskList, "l", [.command, .shift])
            format("Mark Task as Done", .toggleTaskDone, .return)
            Divider()
            format("Quote", .blockquote, "'")
            format("Code Block", .codeBlock, "b", [.command, .option])
            format("Horizontal Rule", .horizontalRule)
            Divider()
            format("Shift Right", .shiftRight, "]")
            format("Shift Left", .shiftLeft, "[")
        }
    }

    @ViewBuilder
    private func format(_ title: String, _ action: FormatAction, _ key: KeyEquivalent? = nil, _ modifiers: EventModifiers = .command) -> some View {
        let button = Button(title) { front.windowState.editor?.perform(action) }
            .disabled(!front.windowState.isEditorFocused)
        if let key {
            button.keyboardShortcut(key, modifiers: modifiers)
        } else {
            button
        }
    }

    // MARK: View

    @CommandsBuilder private var viewCommands: some Commands {
        CommandGroup(after: .sidebar) {
            Divider()
            Toggle("Preview", isOn: Binding(get: { front.windowState.isPreviewing }, set: { front.windowState.isPreviewing = $0 }))
                .keyboardShortcut("r")
                .disabled(front.library.selectedNote == nil)
            Divider()
            Toggle("Focus Mode", isOn: $focusEnabled)
                .keyboardShortcut("d")
            Picker("Focus On", selection: $focusUnit) {
                Text("Sentence").tag(FocusMode.sentence)
                Text("Paragraph").tag(FocusMode.paragraph)
            }
            Toggle("Typewriter Mode", isOn: $typewriter)
                .keyboardShortcut("t")
            Toggle("Syntax Highlight", isOn: $syntaxHighlight)
                .keyboardShortcut("h", modifiers: [.command, .shift])
            Toggle("Word Count", isOn: $showCounter)
            Toggle("Show Markdown Syntax", isOn: $showsSyntax)
                .keyboardShortcut("m", modifiers: [.command, .shift])
            Divider()
            Picker("Font", selection: $fontFamily) {
                ForEach(EditorFontFamily.allCases) { family in
                    Text(family.displayName).tag(family)
                }
            }
            Button("Bigger") { fontSize = min(fontSize + 1, EditorTheme.fontSizeRange.upperBound) }
                .keyboardShortcut("+")
                .disabled(fontSize >= EditorTheme.fontSizeRange.upperBound)
            Button("Smaller") { fontSize = max(fontSize - 1, EditorTheme.fontSizeRange.lowerBound) }
                .keyboardShortcut("-")
                .disabled(fontSize <= EditorTheme.fontSizeRange.lowerBound)
            Button("Actual Size") { fontSize = EditorTheme.defaultFontSize }
                .keyboardShortcut("0")
                .disabled(fontSize == EditorTheme.defaultFontSize)
            Divider()
            // Applied here too: the library window, which also applies it, may not be open.
            Picker("Appearance", selection: Binding(get: { appearance }, set: { appearance = $0; NSApp.appearance = $0.nsAppearance })) {
                ForEach(AppearancePreference.allCases) { preference in
                    Text(preference.displayName).tag(preference)
                }
            }
            Divider()
        }
    }
}
