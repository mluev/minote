import AppKit
import MinoteKit
import UniformTypeIdentifiers

/// One Markdown file opened from elsewhere (Finder, File ▸ Open…, the Dock):
/// a library holding just that file, saved in place and watched for changes.
/// It never joins the library list, and its tab doesn't come back at the
/// next launch.
final class OpenedFile {
    let url: URL
    let library: Library
    private let watcher: PathWatcher

    init(url: URL) {
        self.url = url
        let store = NoteFileStore(file: url, backupDirectory: LibraryLocation.backupDirectory())
        let watcher = PathWatcher(url: store.singleFile ?? url)
        self.watcher = watcher
        library = Library(store: store, watcher: watcher)
    }

    /// The file's tab closed: saves what its editor had, then stops watching.
    func finish(editor: any NoteEditor) async {
        library.detach(editor)
        await library.saveNow()
        await library.waitUntilIdle()
        watcher.stop()
    }

    /// What File ▸ Open… offers: the kinds of files the library lists.
    static let contentTypes: [UTType] = Array(Set(NoteNaming.supportedExtensions.compactMap { UTType(filenameExtension: $0) }))

    /// Markdown and other plain text; anything else isn't Minote's to edit.
    static func canOpen(_ url: URL) -> Bool {
        NoteNaming.isNoteFile(url) || UTType(filenameExtension: url.pathExtension)?.conforms(to: .plainText) == true
    }
}
