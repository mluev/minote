import AppKit
import MinoteEditor
import MinoteKit
import SwiftUI

/// Every action lives in the system menus; the window stays a blank page.
struct AppCommands: Commands {
    let workspace: Workspace

    private var library: Library { workspace.library }
    private var storage: LibraryStorageSwitcher { workspace.storage }
    private var preferences = EditorPreferences()
    @AppStorage(PreferenceKey.appearance) private var theme = PageTheme.system
    @AppStorage(PreferenceKey.showCounter) private var showCounter = false

    init(workspace: Workspace) {
        self.workspace = workspace
    }

    var body: some Commands {
        // No Settings window: every preference lives in the menus.
        CommandGroup(replacing: .appSettings) {}
        TextEditingCommands()
        fileCommands
        editCommands
        CommandMenu("Format") {
            FormatMenuItems(isEnabled: front?.isEditorFocused ?? false) { front?.editor.perform($0) }
        }
        viewCommands
        windowCommands
        CommandGroup(replacing: .help) {}
    }

    /// The tab the menus act on: the front window's.
    private var front: PageTab? { workspace.frontTab }

    /// The window in front.
    private var frontWindow: WindowState? { workspace.frontWindow?.state }

    /// The note of the tab in front, if it's one of the library's: library
    /// commands (Duplicate, Rename, Move to Trash) act on it, not on files
    /// opened from elsewhere.
    private var frontLibraryNote: Note? {
        guard let front, front.isLibraryTab else { return nil }
        return front.note
    }

    /// The note of the tab in front, whichever library it's in.
    private var frontNote: Note? { front?.note }

    // MARK: File

    @CommandsBuilder private var fileCommands: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Note") { workspace.newNote() }
                .keyboardShortcut("n")
            Button("New Tab") { workspace.newTab() }
                .keyboardShortcut("t")
            Button("Open…") { workspace.showOpenPanel() }
                .keyboardShortcut("o")
            Menu("Open Recent") {
                ForEach(workspace.recents, id: \.self) { url in
                    Button(workspace.recentTitle(for: url)) { workspace.openRecent(url) }
                }
                Divider()
                Button("Clear Menu") { workspace.clearRecents() }
                    .disabled(workspace.recents.isEmpty)
            }
        }
        CommandGroup(replacing: .saveItem) {
            Button("Close Tab") { workspace.closeFrontTab() }
                .keyboardShortcut("w")
                .disabled(front == nil)
            Button("Close Window") { workspace.frontWindow?.window.performClose(nil) }
                .keyboardShortcut("w", modifiers: [.command, .shift])
                .disabled(workspace.frontWindow == nil)
        }
        CommandGroup(after: .newItem) {
            Button("Duplicate") {
                guard let id = frontLibraryNote?.id else { return }
                Task { await library.duplicate(id) }
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])
            .disabled(frontLibraryNote?.isDraft ?? true)
            Button("Rename…") { frontWindow?.renaming = frontLibraryNote }
                .disabled(frontLibraryNote?.isBlankDraft ?? true)
            Divider()
            Button("Show in Finder") {
                if let url = frontNote?.fileURL { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(frontNote?.fileURL == nil)
            Button("Show Library in Finder") { NSWorkspace.shared.open(library.directory) }
            Toggle(storage.isICloudAvailable ? "Keep Notes in iCloud Drive" : "Keep Notes in iCloud Drive (iCloud Unavailable)", isOn: Binding(
                get: { storage.storage == .iCloud },
                set: { keep in Task { await storage.move(to: keep ? .iCloud : .local) } }
            ))
            .disabled(storage.isMoving || (!storage.isICloudAvailable && storage.storage == .local))
            Divider()
            // ⌘⌫ only while the list has focus; in the editor it deletes to the start of the line.
            Button("Move to Trash") {
                guard let id = frontLibraryNote?.id else { return }
                library.moveToTrash(id, undoManager: NSApp.keyWindow?.undoManager, actionName: "Move to Trash")
            }
            .keyboardShortcut(.delete, modifiers: .command)
            .disabled(!(frontWindow?.isSidebarFocused ?? false) || frontLibraryNote == nil)
        }
        CommandGroup(replacing: .printItem) {
            Button("Print…") {
                let title = frontNote?.title ?? ""
                front?.editor.printNote(title: title.isEmpty ? "Note" : title)
            }
            .keyboardShortcut("p")
            .disabled(frontNote == nil)
        }
    }

    // MARK: Edit

    @CommandsBuilder private var editCommands: some Commands {
        CommandGroup(after: .textEditing) {
            Button("Search All Notes") {
                if workspace.frontWindow == nil { workspace.showLibrary() }
                guard let window = workspace.frontWindow?.state ?? workspace.targetWindow?.state else { return }
                window.isSidebarVisible = true
                window.searchFocusRequest += 1
            }
            .keyboardShortcut("f", modifiers: [.command, .shift])
        }
    }

    // MARK: View

    @CommandsBuilder private var viewCommands: some Commands {
        CommandGroup(replacing: .sidebar) {
            Button(frontWindow?.isSidebarVisible == false ? "Show Sidebar" : "Hide Sidebar") {
                guard let window = frontWindow else { return }
                withAnimation(.smooth(duration: 0.22)) { window.isSidebarVisible.toggle() }
            }
            .keyboardShortcut("s", modifiers: [.command, .control])
            .disabled(frontWindow == nil)
        }
        CommandGroup(after: .sidebar) {
            Divider()
            Toggle("Preview", isOn: Binding(get: { front?.isPreviewing ?? false }, set: { front?.isPreviewing = $0 }))
                .keyboardShortcut("r")
                .disabled(frontNote == nil)
            Divider()
            Toggle("Focus Mode", isOn: preferences.$focusEnabled)
                .keyboardShortcut("d")
            Picker("Focus On", selection: preferences.$focusUnit) {
                Text("Sentence").tag(FocusMode.sentence)
                Text("Paragraph").tag(FocusMode.paragraph)
            }
            Toggle("Typewriter Mode", isOn: preferences.$typewriter)
                .keyboardShortcut("t", modifiers: [.command, .control])
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
            // A closure, not `PageTheme.select` itself: Swift 6.3 (CI's Xcode 26)
            // crashes making the method into the binding's setter.
            Picker("Appearance", selection: Binding(get: { theme }, set: { PageTheme.select($0) })) {
                ForEach(PageTheme.allCases) { theme in
                    Text(theme.displayName).tag(theme)
                }
            }
            Divider()
        }
    }

    // MARK: Window

    /// The tab shortcuts (⌘1…⌘9, ⌘⇧] / ⌘⇧[, ⌃Tab) are `AppDelegate`'s.
    @CommandsBuilder private var windowCommands: some Commands {
        CommandGroup(before: .windowArrangement) {
            Button("Show Previous Tab") { workspace.selectTab(offset: -1) }
                .disabled((workspace.frontWindow?.tabs.count ?? 0) < 2)
            Button("Show Next Tab") { workspace.selectTab(offset: 1) }
                .disabled((workspace.frontWindow?.tabs.count ?? 0) < 2)
            Button("Move Tab to New Window") {
                if let front { workspace.moveToNewWindow(front) }
            }
            .disabled((workspace.frontWindow?.tabs.count ?? 0) < 2)
            Button("Merge All Windows") { workspace.mergeAllWindows() }
            Divider()
        }
    }
}
