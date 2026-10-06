import Foundation
@testable import MinoteKit

/// A temporary library folder plus a fake Trash, removed on deinit.
final class TemporaryLibrary: @unchecked Sendable {
    let root: URL
    let notes: URL
    let trash: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MinoteTests-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        notes = root.appendingPathComponent("Notes", isDirectory: true)
        trash = root.appendingPathComponent("Trash", isDirectory: true)
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    /// Moves files into our own Trash folder so tests never touch the real one.
    func makeStore() -> NoteFileStore {
        let trash = self.trash
        return NoteFileStore(directory: notes) { url in
            let destination = trash.appendingPathComponent("\(UUID().uuidString)-\(url.lastPathComponent)")
            try FileManager.default.moveItem(at: url, to: destination)
            return destination
        }
    }

    var fileNames: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: notes.path)) ?? [])
            .filter { !$0.hasPrefix(".") }
            .sorted()
    }

    var trashedCount: Int {
        ((try? FileManager.default.contentsOfDirectory(atPath: trash.path)) ?? []).count
    }

    func contents(of name: String) -> String? {
        try? String(contentsOf: notes.appendingPathComponent(name), encoding: .utf8)
    }

    func write(_ text: String, to name: String) throws {
        try text.write(to: notes.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }
}

/// Stands in for the AppKit editor.
@MainActor
final class FakeEditor: NoteEditor {
    var displayedNoteID: Note.ID?
    var text = ""
    var caretOffset = 0
    var reloadCount = 0
    var focusCount = 0

    func display(_ note: Note?) {
        displayedNoteID = note?.id
        text = note?.text ?? ""
        caretOffset = 0
    }

    func currentText() -> String { text }

    var isCaretInTitleLine: Bool {
        guard let first = text.firstIndex(where: { !$0.isWhitespace }) else { return true }
        let lineEnd = text[first...].firstIndex(where: \.isNewline) ?? text.endIndex
        return caretOffset <= text.distance(from: text.startIndex, to: lineEnd)
    }

    func reloadText(_ text: String) {
        self.text = text
        reloadCount += 1
    }

    func focus() { focusCount += 1 }

    /// Simulates typing: replaces the text and reports the edit to the library.
    func type(_ newText: String, caretAtEnd: Bool = true, in library: Library) {
        text = newText
        caretOffset = caretAtEnd ? newText.count : 0
        guard let id = displayedNoteID else { return }
        library.editorDidChange(noteID: id, prefix: newText.prefix(NoteNaming.prefixLength))
    }
}

extension LibraryTiming {
    static let fast = LibraryTiming(
        saveDebounce: .milliseconds(20),
        maxSaveLatency: .milliseconds(200),
        rescanDebounce: .milliseconds(10),
        retryDelay: .milliseconds(50)
    )
}

func freshDefaults() -> UserDefaults {
    let name = "MinoteTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}
