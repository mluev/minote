import AppKit
import MinoteEditor
import MinoteKit
import SwiftUI

/// Search everything, as a launcher does: notes by title and by what they
/// say, folders, and the app's commands, from one field. ↑↓ move, Return
/// opens, ⌘Return opens a note in a new tab (or looks into a folder),
/// Escape closes. Opened with ⌘J or ⇧⌘F, or the sidebar's magnifying glass.
struct SearchPalette: View {
    @Bindable var library: Library
    @Bindable var state: WindowState
    let workspace: Workspace
    let palette: EditorPalette
    /// How tall the results may grow: the window decides.
    var maxResultsHeight: CGFloat = 400

    static let fieldHeight: CGFloat = 54
    static let footerHeight: CGFloat = 32

    @ViewState private var query = ""
    @ViewState private var selection: String?
    /// The pointer moved over a row: hovering selects only after it moves,
    /// so results appearing under a still pointer don't steal the highlight.
    @ViewState private var pointerMoved = false
    @FocusState private var isFieldFocused: Bool

    // MARK: Results

    enum Result: Identifiable {
        case note(NoteHit)
        case folder(FolderPath, FuzzyMatch?)
        case command(PaletteCommand, FuzzyMatch?)

        var id: String {
            switch self {
            case .note(let hit): "note:" + hit.id.uuidString
            case .folder(let path, _): "folder:" + path.string
            case .command(let command, _): "command:" + command.id
            }
        }
    }

    struct Section: Identifiable {
        let title: String
        let results: [Result]
        var id: String { title }
    }

    private var sections: [Section] {
        let notes = LibrarySearch.notes(query, in: library.notes, limit: query.isEmpty ? 8 : 30)
        let folders = LibrarySearch.folders(query, in: library.folders)
        let commands = PaletteCommand.all(workspace: workspace, state: state)
        let matchedCommands = Self.match(commands, to: query)
        var sections: [Section] = []
        if !notes.isEmpty { sections.append(Section(title: query.isEmpty ? "Recent" : "Notes", results: notes.map(Result.note))) }
        if !folders.isEmpty { sections.append(Section(title: "Folders", results: folders.map { .folder($0.folder, $0.match) })) }
        if !matchedCommands.isEmpty { sections.append(Section(title: "Commands", results: matchedCommands.prefix(8).map { .command($0.0, $0.1) })) }
        return sections
    }

    /// Commands whose title (or, more weakly, one of their keywords) matches;
    /// the suggested ones before anything's typed.
    private static func match(_ commands: [PaletteCommand], to query: String) -> [(PaletteCommand, FuzzyMatch?)] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            return commands.filter(\.isSuggested).map { ($0, nil) }
        }
        var found: [(PaletteCommand, FuzzyMatch?)] = []
        for command in commands {
            if let match = Fuzzy.match(query, in: command.title) {
                found.append((command, match))
                continue
            }
            for keyword in command.keywords {
                guard let match = Fuzzy.match(query, in: keyword) else { continue }
                found.append((command, FuzzyMatch(score: match.score / 2, ranges: [])))
                break
            }
        }
        found.sort { ($0.1?.score ?? 0) > ($1.1?.score ?? 0) }
        return found
    }

    var body: some View {
        let sections = sections
        let results = sections.flatMap(\.results)
        let selected = selection.flatMap { id in results.first { $0.id == id } } ?? results.first
        VStack(spacing: 0) {
            field(results: results, selected: selected)
            if !results.isEmpty && maxResultsHeight >= 44 {
                Rectangle().fill(Color(nsColor: palette.rule)).frame(height: 1)
                list(sections, selected: selected)
                Rectangle().fill(Color(nsColor: palette.rule)).frame(height: 1)
                footer(selected)
            } else if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                Rectangle().fill(Color(nsColor: palette.rule)).frame(height: 1)
                Text("Nothing matches “\(query)”")
                    .font(.system(size: 13))
                    .foregroundStyle(Color(nsColor: palette.syntax))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 22)
                    .transition(.opacity)
            }
        }
        .chromeSurface(palette, cornerRadius: 14)
        .animation(ChromeMotion.move, value: results.count)
        .onAppear { isFieldFocused = true }
        .onChange(of: query) {
            selection = nil
            pointerMoved = false
        }
    }

    // MARK: Field

    private func field(results: [Result], selected: Result?) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Color(nsColor: palette.quote))
            ZStack(alignment: .leading) {
                if query.isEmpty {
                    Text("Search notes, folders and commands")
                        .font(.system(size: 17))
                        .foregroundStyle(Color(nsColor: palette.syntax))
                        .allowsHitTesting(false)
                }
                TextField("", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 17))
                    .foregroundStyle(Color(nsColor: palette.text))
                    .focused($isFieldFocused)
                    .onSubmit { if let selected { run(selected, alternate: false) } }
                    .onKeyPress(.upArrow) { moveSelection(-1, in: results, from: selected); return .handled }
                    .onKeyPress(.downArrow) { moveSelection(1, in: results, from: selected); return .handled }
                    .onKeyPress(.escape) {
                        if query.isEmpty { state.dismissOverlay() } else { query = "" }
                        return .handled
                    }
                    .onKeyPress(keys: [.return], phases: .down) { press in
                        guard press.modifiers.contains(.command), let selected else { return .ignored }
                        run(selected, alternate: true)
                        return .handled
                    }
                    .accessibilityLabel("Search")
            }
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                }
                .buttonStyle(ChromeButtonStyle(palette: palette, cornerRadius: 11, size: 22))
                .help("Clear")
                .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }
            KeyCap("esc", palette: palette)
        }
        .padding(.horizontal, 16)
        .frame(height: Self.fieldHeight)
        .animation(ChromeMotion.move, value: query.isEmpty)
    }

    // MARK: List

    private func list(_ sections: [Section], selected: Result?) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(sections) { section in
                        Text(section.title)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color(nsColor: palette.syntax))
                            .padding(.horizontal, 10)
                            .padding(.top, 10)
                            .padding(.bottom, 4)
                        ForEach(section.results) { result in
                            row(result, isSelected: result.id == selected?.id)
                                .id(result.id)
                        }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 6)
            }
            .frame(maxHeight: maxResultsHeight)
            .fixedSize(horizontal: false, vertical: true)
            .onContinuousHover { phase in
                if case .active = phase { pointerMoved = true }
            }
            .onChange(of: selection) { _, id in
                guard let id else { return }
                proxy.scrollTo(id)
            }
        }
    }

    private func row(_ result: Result, isSelected: Bool) -> some View {
        HStack(spacing: 10) {
            icon(result)
                .frame(width: 24, height: 24)
                .background {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color(nsColor: palette.sidebarSelection).opacity(isSelected ? 0 : 0.7))
                }
            VStack(alignment: .leading, spacing: 2) {
                highlighted(title(of: result), match(of: result))
                    .font(.system(size: 13.5, weight: .medium))
                    .lineLimit(1)
                if let subtitle = subtitle(of: result) {
                    subtitle
                        .font(.system(size: 12))
                        .foregroundStyle(Color(nsColor: palette.quote))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if let trailing = trailing(of: result) {
                Text(trailing)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color(nsColor: palette.syntax))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 8)
        .frame(minHeight: 40)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(nsColor: palette.sidebarSelection))
            }
        }
        .contentShape(Rectangle())
        .onHover { inside in
            if inside && pointerMoved { selection = result.id }
        }
        .onTapGesture { run(result, alternate: NSEvent.modifierFlags.contains(.command)) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    @ViewBuilder
    private func icon(_ result: Result) -> some View {
        let name: String = switch result {
        case .note(let hit): hit.note.isLocked ? (hit.note.isSealed ? "lock.fill" : "lock.open.fill") : "doc.text"
        case .folder: "folder"
        case .command(let command, _): command.systemImage
        }
        Image(systemName: name)
            .font(.system(size: 12.5))
            .foregroundStyle(Color(nsColor: palette.quote))
    }

    private func title(of result: Result) -> String {
        switch result {
        case .note(let hit): hit.note.displayTitle
        case .folder(let path, _): path.name ?? ""
        case .command(let command, _): command.title
        }
    }

    private func match(of result: Result) -> [Range<String.Index>] {
        switch result {
        case .note(let hit): hit.titleMatch?.ranges ?? []
        case .folder(_, let match): match?.ranges ?? []
        case .command(_, let match): match?.ranges ?? []
        }
    }

    private func subtitle(of result: Result) -> Text? {
        switch result {
        case .note(let hit):
            if let snippet = hit.snippet {
                return highlighted(snippet, hit.snippetMatch.map { [$0] } ?? [])
            }
            return hit.note.folder.isRoot ? nil : Text(hit.note.folder.string)
        case .folder(let path, _):
            return path.parent.map { $0.isRoot ? Text("Notes") : Text($0.string) }
        case .command:
            return nil
        }
    }

    private func trailing(of result: Result) -> String? {
        switch result {
        case .note(let hit):
            hit.snippet != nil && !hit.note.folder.isRoot ? hit.note.folder.name : NoteDateText.string(for: hit.note.modified)
        case .folder(let path, _):
            "\(library.notes(under: path).count) notes"
        case .command(let command, _):
            command.shortcut
        }
    }

    /// The text with the matched letters in the text color, the rest a shade quieter.
    private func highlighted(_ text: String, _ ranges: [Range<String.Index>]) -> Text {
        var attributed = AttributedString(text)
        attributed.foregroundColor = Color(nsColor: palette.text)
        guard !ranges.isEmpty else { return Text(attributed) }
        attributed.foregroundColor = Color(nsColor: palette.text).opacity(0.72)
        for range in ranges {
            guard let lower = AttributedString.Index(range.lowerBound, within: attributed),
                  let upper = AttributedString.Index(range.upperBound, within: attributed) else { continue }
            attributed[lower..<upper].foregroundColor = Color(nsColor: palette.text)
            attributed[lower..<upper].inlinePresentationIntent = .stronglyEmphasized
        }
        return Text(attributed)
    }

    // MARK: Footer

    private func footer(_ selected: Result?) -> some View {
        HStack(spacing: 14) {
            hint("↑↓", "Move")
            hint("↵", primaryTitle(selected))
            if let alternate = alternateTitle(selected) { hint("⌘↵", alternate) }
            Spacer()
        }
        .padding(.horizontal, 16)
        .frame(height: Self.footerHeight)
    }

    private func hint(_ key: String, _ title: String) -> some View {
        HStack(spacing: 5) {
            KeyCap(key, palette: palette)
            Text(title)
                .font(.system(size: 11.5))
                .foregroundStyle(Color(nsColor: palette.syntax))
        }
    }

    private func primaryTitle(_ result: Result?) -> String {
        switch result {
        case .note: "Open"
        case .folder: "Show in Sidebar"
        case .command, nil: "Run"
        }
    }

    private func alternateTitle(_ result: Result?) -> String? {
        switch result {
        case .note: "Open in New Tab"
        case .folder: "Show Only This Folder"
        default: nil
        }
    }

    // MARK: Acting

    private func moveSelection(_ step: Int, in results: [Result], from current: Result?) {
        guard !results.isEmpty else { return }
        let index = current.flatMap { current in results.firstIndex { $0.id == current.id } } ?? 0
        selection = results[min(max(index + step, 0), results.count - 1)].id
        pointerMoved = false
    }

    private func run(_ result: Result, alternate: Bool) {
        state.dismissOverlay()
        switch result {
        case .note(let hit):
            workspace.sidebar.reveal(hit.note.folder)
            workspace.open(note: hit.note.id, newTab: alternate)
        case .folder(let path, _):
            state.isSidebarVisible = true
            if alternate {
                state.scope = path
            } else {
                if !state.scope.contains(path) { state.scope = .root }
                workspace.sidebar.reveal(path)
                if let parent = path.parent, !parent.isRoot { workspace.sidebar.reveal(parent) }
                state.sidebarCursor = "folder:" + path.string
                state.sidebarFocusRequest += 1
            }
        case .command(let command, _):
            // After the palette is gone: the command may present something of its own.
            DispatchQueue.main.async { command.run() }
        }
    }
}

/// A key as the footer and the field show it.
struct KeyCap: View {
    let key: String
    let palette: EditorPalette

    init(_ key: String, palette: EditorPalette) {
        self.key = key
        self.palette = palette
    }

    var body: some View {
        Text(key)
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(Color(nsColor: palette.quote))
            .padding(.horizontal, 5)
            .frame(minWidth: 18, minHeight: 18)
            .background {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color(nsColor: palette.sidebarSelection))
            }
    }
}

/// Something the palette can do besides opening a note or a folder.
struct PaletteCommand: Identifiable {
    let id: String
    let title: String
    let systemImage: String
    var shortcut: String?
    /// Other words it's found by.
    var keywords: [String] = []
    /// Listed before anything's typed.
    var isSuggested = false
    let run: () -> Void

    @MainActor
    static func all(workspace: Workspace, state: WindowState) -> [PaletteCommand] {
        let library = workspace.library
        let preferences = workspace.sidebar
        let window = workspace.window(for: state)
        var commands: [PaletteCommand] = [
            PaletteCommand(id: "new-note", title: "New Note", systemImage: "square.and.pencil", shortcut: "⌘N",
                           keywords: ["create", "write"], isSuggested: true) { workspace.newNote() },
            PaletteCommand(id: "new-folder", title: "New Folder", systemImage: "folder.badge.plus", shortcut: "⇧⌘N",
                           keywords: ["create", "group"], isSuggested: true) { workspace.newFolder(window: window) },
            PaletteCommand(id: "new-tab", title: "New Tab", systemImage: "plus.square.on.square", shortcut: "⌘T") { workspace.newTab(in: window) },
            PaletteCommand(id: "sidebar", title: state.isSidebarVisible ? "Hide Sidebar" : "Show Sidebar",
                           systemImage: "sidebar.left", keywords: ["toggle", "library"]) {
                withAnimation(ChromeMotion.move) { state.isSidebarVisible.toggle() }
            },
        ]
        for grouping in LibraryView.Grouping.allCases where preferences.view.groupBy != grouping {
            commands.append(PaletteCommand(id: "group-\(grouping.rawValue)", title: "Group by \(grouping.displayName)",
                                           systemImage: "rectangle.3.group", keywords: ["view", "group"]) {
                withAnimation(ChromeMotion.move) { preferences.view.groupBy = grouping }
            })
        }
        let order = library.sortOrder(of: state.scope)
        for sort in NoteSort.allCases where order.sort != sort {
            commands.append(PaletteCommand(id: "sort-\(sort.rawValue)", title: "Sort by \(sort.displayName)",
                                           systemImage: "arrow.up.arrow.down", keywords: ["order", "view"]) {
                withAnimation(ChromeMotion.move) { library.setSort(SortOrder(sort, reversed: false), for: state.scope) }
            })
        }
        if !state.scope.isRoot {
            commands.append(PaletteCommand(id: "show-all", title: "Show All Notes", systemImage: "tray.full",
                                           keywords: ["library", "scope", "back"], isSuggested: true) { state.scope = .root })
        }
        if library.isUnlocked {
            commands.append(PaletteCommand(id: "lock-now", title: "Lock Now", systemImage: "lock", shortcut: "⌃⌘L",
                                           keywords: ["password", "secure"]) { workspace.lock.lockNow() })
        }
        commands.append(PaletteCommand(id: "reveal-library", title: "Show Library in Finder", systemImage: "folder",
                                       keywords: ["finder", "files"]) { NSWorkspace.shared.open(library.directory) })
        return commands
    }
}
