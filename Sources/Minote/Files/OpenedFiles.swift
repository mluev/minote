import AppKit
import MinoteKit
import SwiftUI
import UniformTypeIdentifiers

/// Markdown files opened from anywhere on the Mac (Finder, File ▸ Open…, the
/// Dock), each in its own window and saved in place. They never join the
/// library, and their windows don't come back at the next launch.
@Observable
final class OpenedFiles {
    /// The opened file whose window is in front, if any: the menus act on it.
    private(set) var frontSession: FileSession?
    /// File ▸ Open Recent, newest first. The system keeps the app's access to
    /// these files across launches.
    private(set) var recents: [URL] = []

    @ObservationIgnored private var sessions: [FileSession] = []
    /// Windows that closed while their last save was still on its way.
    @ObservationIgnored private var closing: [FileSession] = []
    @ObservationIgnored private weak var library: Library?
    @ObservationIgnored private var showLibrary: (() -> Void)?
    @ObservationIgnored private var accessedRecents: Set<URL> = []

    /// What File ▸ Open… offers: the kinds of files the library lists.
    static let contentTypes: [UTType] = Array(Set(NoteNaming.supportedExtensions.compactMap { UTType(filenameExtension: $0) }))

    /// The library window appeared: a file that is one of its notes opens there.
    func libraryWindowAppeared(_ library: Library, show: @escaping () -> Void) {
        self.library = library
        showLibrary = show
    }

    // MARK: Opening

    func open(_ urls: [URL]) {
        for url in urls { open(url) }
    }

    /// Shows the file in its own window, or brings its window to the front.
    func open(_ url: URL) {
        let url = url.standardizedFileURL.resolvingSymlinksInPath()
        guard Self.canOpen(url) else {
            NSSound.beep()
            return
        }
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        refreshRecents()

        // One of the library's own notes: two editors on one file would overwrite each other.
        if let library, let showLibrary, let note = library.notes.first(where: { $0.fileURL?.path == url.path }) {
            library.selectedID = note.id
            showLibrary()
            return
        }
        if let session = sessions.first(where: { $0.url == url }) {
            session.window.makeKeyAndOrderFront(nil)
            return
        }
        let session = FileSession(url: url)
        session.onMainChange = { [weak self] session, isMain in
            self?.mainWindowChanged(session, isMain: isMain)
        }
        session.onClose = { [weak self] session in
            self?.closed(session)
        }
        let previous = sessions.last?.window
        sessions.append(session)
        session.show(after: previous?.isVisible == true ? previous : nil)
    }

    /// Markdown and other plain text; anything else isn't Minote's to edit.
    static func canOpen(_ url: URL) -> Bool {
        NoteNaming.isNoteFile(url) || UTType(filenameExtension: url.pathExtension)?.conforms(to: .plainText) == true
    }

    /// File ▸ Open…
    func showOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = Self.contentTypes
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        open(panel.urls)
    }

    // MARK: Recent files

    func openRecent(_ url: URL) {
        // Recent files may come back as security-scoped URLs.
        if !accessedRecents.contains(url), url.startAccessingSecurityScopedResource() {
            accessedRecents.insert(url)
        }
        open(url)
    }

    func clearRecents() {
        NSDocumentController.shared.clearRecentDocuments(nil)
        refreshRecents()
    }

    /// The file's name, with its folder when another recent file has the same name.
    func recentTitle(for url: URL) -> String {
        let name = url.lastPathComponent
        let sameName = recents.filter { $0.lastPathComponent == name }.count
        guard sameName > 1 else { return name }
        return "\(name) — \(url.deletingLastPathComponent().lastPathComponent)"
    }

    /// Reads File ▸ Open Recent from the system (at launch, and after changes).
    func refreshRecents() {
        recents = NSDocumentController.shared.recentDocumentURLs
    }

    // MARK: Windows

    private func mainWindowChanged(_ session: FileSession, isMain: Bool) {
        if isMain {
            frontSession = session
        } else if frontSession === session {
            frontSession = nil
        }
    }

    private func closed(_ session: FileSession) {
        sessions.removeAll { $0 === session }
        if frontSession === session { frontSession = nil }
        closing.append(session)
        Task {
            await session.finish()
            // A save that failed keeps retrying; quitting asks about it.
            if !session.library.hasUnsavedChanges {
                closing.removeAll { $0 === session }
            }
        }
    }

    // MARK: Saving

    private var all: [FileSession] { sessions + closing }

    var hasUnsavedChanges: Bool {
        all.contains { $0.library.hasUnsavedChanges }
    }

    func saveAll() async {
        for session in all { await session.library.saveNow() }
    }

    func prepareForTermination() async {
        for session in all { await session.library.prepareForTermination() }
    }

    func cancelTermination() {
        for session in all { session.library.cancelTermination() }
    }
}

extension View {
    /// Lets opened files find the library window (see `OpenedFiles.open`).
    func registersLibraryWindow(_ library: Library, with openedFiles: OpenedFiles) -> some View {
        modifier(LibraryWindowRegistration(library: library, openedFiles: openedFiles))
    }
}

private struct LibraryWindowRegistration: ViewModifier {
    let library: Library
    let openedFiles: OpenedFiles
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.onAppear {
            let open = self.openWindow
            openedFiles.libraryWindowAppeared(library) { open(id: "main") }
        }
    }
}
