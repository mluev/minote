import AppKit
import MinoteEditor
import MinoteKit
import SwiftUI

/// Every action lives in the system menus; the window stays a blank page.
struct AppCommands: Commands {
    let libraryWindow: LibraryWindow
    let openedFiles: OpenedFiles

    private var library: Library { libraryWindow.library }
    private var windowState: WindowState { libraryWindow.windowState }
    private var storage: LibraryStorageSwitcher { libraryWindow.storage }
    private var preferences = EditorPreferences()
    @AppStorage(PreferenceKey.appearance) private var appearance = AppearancePreference.system
    @AppStorage(PreferenceKey.showCounter) private var showCounter = false

    init(libraryWindow: LibraryWindow, openedFiles: OpenedFiles) {
        self.libraryWindow = libraryWindow
        self.openedFiles = openedFiles
    }

    var body: some Commands {
        // No Settings window: every preference lives in the menus.
        CommandGroup(replacing: .appSettings) {}
        SidebarCommands()
        TextEditingCommands()
        fileCommands
        editCommands
        CommandMenu("Format") {
            FormatMenuItems(isEnabled: front.windowState.isEditorFocused) { front.windowState.editor?.perform($0) }
        }
        viewCommands
        CommandGroup(replacing: .help) {}
    }

    /// The window the menus act on: an opened file's when it's in front,
    /// otherwise the library's.
    private var front: (library: Library, windowState: WindowState) {
        if let session = openedFiles.frontSession { return (session.library, session.windowState) }
        return (library, windowState)
    }

    /// Library commands don't apply to an opened file.
    private var isFileInFront: Bool { openedFiles.frontSession != nil }

    // MARK: File

    @CommandsBuilder private var fileCommands: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Note") { libraryWindow.newNote() }
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
            Button("Show in Finder") {
                if let url = front.library.selectedNote?.fileURL { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(front.library.selectedNote?.fileURL == nil)
            Button("Show Library in Finder") { NSWorkspace.shared.open(library.directory) }
            Toggle(storage.isICloudAvailable ? "Keep Notes in iCloud Drive" : "Keep Notes in iCloud Drive (iCloud Unavailable)", isOn: Binding(
                get: { storage.storage == .iCloud },
                set: { keep in Task { await storage.move(to: keep ? .iCloud : .local) } }
            ))
            .disabled(storage.isMoving || (!storage.isICloudAvailable && storage.storage == .local))
            Divider()
            // ⌘⌫ only while the list has focus; in the editor it deletes to the start of the line.
            Button("Move to Trash") {
                guard let id = library.selectedID else { return }
                library.moveToTrash(id, undoManager: NSApp.keyWindow?.undoManager, actionName: "Move to Trash")
            }
            .keyboardShortcut(.delete, modifiers: .command)
            .disabled(isFileInFront || !windowState.isSidebarFocused || library.selectedNote == nil)
        }
        CommandGroup(replacing: .printItem) {
            Button("Print…") {
                let front = self.front
                let title = front.library.selectedNote?.title ?? ""
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
                libraryWindow.show()
                windowState.columnVisibility = .all
                windowState.searchFocusRequest += 1
            }
            .keyboardShortcut("f", modifiers: [.command, .shift])
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
            Toggle("Focus Mode", isOn: preferences.$focusEnabled)
                .keyboardShortcut("d")
            Picker("Focus On", selection: preferences.$focusUnit) {
                Text("Sentence").tag(FocusMode.sentence)
                Text("Paragraph").tag(FocusMode.paragraph)
            }
            Toggle("Typewriter Mode", isOn: preferences.$typewriter)
                .keyboardShortcut("t")
            Toggle("Syntax Highlight", isOn: preferences.$syntaxHighlight)
                .keyboardShortcut("h", modifiers: [.command, .shift])
            Toggle("Word Count", isOn: $showCounter)
            Toggle("Show Markdown Syntax", isOn: preferences.$showsSyntax)
                .keyboardShortcut("m", modifiers: [.command, .shift])
            Divider()
            Picker("Font", selection: preferences.$fontFamily) {
                ForEach(EditorFontFamily.allCases) { family in
                    Text(family.displayName).tag(family)
                }
            }
            Button("Bigger") { preferences.fontSize = min(preferences.fontSize + 1, EditorTheme.fontSizeRange.upperBound) }
                .keyboardShortcut("+")
                .disabled(preferences.fontSize >= EditorTheme.fontSizeRange.upperBound)
            Button("Smaller") { preferences.fontSize = max(preferences.fontSize - 1, EditorTheme.fontSizeRange.lowerBound) }
                .keyboardShortcut("-")
                .disabled(preferences.fontSize <= EditorTheme.fontSizeRange.lowerBound)
            Button("Actual Size") { preferences.fontSize = EditorTheme.defaultFontSize }
                .keyboardShortcut("0")
                .disabled(preferences.fontSize == EditorTheme.defaultFontSize)
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

/// View ▸ Appearance.
enum AppearancePreference: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}
