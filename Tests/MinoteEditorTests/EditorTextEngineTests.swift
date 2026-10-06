import AppKit
import MinoteKit
import Testing
@testable import MinoteEditor

@MainActor
@Suite("Editor engine")
struct EditorTextEngineTests {
    /// The engine holds its storage weakly (the text view owns it); tests keep it here.
    private static var storages: [NSTextStorage] = []

    private func engine(_ text: String, preview: Bool = false, showsSyntax: Bool = false) -> (EditorTextEngine, NSTextStorage) {
        let storage = NSTextStorage()
        Self.storages.append(storage)
        let configuration = EditorConfiguration(family: .sfMono, size: 18, focus: .off, typewriter: false,
                                                partsOfSpeech: false, showsSyntax: showsSyntax, preview: preview)
        let engine = EditorTextEngine(storage: storage, configuration: configuration)
        engine.prepareForNewText()
        storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: text)
        return (engine, storage)
    }

    @Test func theCaretSkipsHiddenMarkup() {
        let (engine, _) = engine("text\n- item")
        #expect(engine.adjustedSelection(NSRange(location: 5, length: 0), previous: nil) == NSRange(location: 7, length: 0))
        #expect(engine.adjustedSelection(NSRange(location: 6, length: 0), previous: nil) == NSRange(location: 7, length: 0))
        // Left arrow from the item's text leaves the line.
        #expect(engine.adjustedSelection(NSRange(location: 6, length: 0), previous: NSRange(location: 7, length: 0)) == NSRange(location: 4, length: 0))
        // Selections are left alone.
        #expect(engine.adjustedSelection(NSRange(location: 5, length: 3), previous: nil) == NSRange(location: 5, length: 3))
        #expect(engine.markupLineStart(ifCaretAtHome: 7) == 5)
        #expect(engine.markupLineStart(ifCaretAtHome: 8) == nil)
    }

    @Test func markupShowsWhenItsSyntaxIsShownOrInsideCode() {
        let (source, _) = engine("- item", showsSyntax: true)
        #expect(source.adjustedSelection(NSRange(location: 0, length: 0), previous: nil) == NSRange(location: 0, length: 0))
        let (code, _) = engine("```\n- item\n```")
        #expect(code.adjustedSelection(NSRange(location: 4, length: 0), previous: nil) == NSRange(location: 4, length: 0))
        #expect(code.markupDeletion(for: NSRange(location: 6, length: 0)) == nil)
    }

    @Test func previewNeitherRevealsNorEdits() {
        let (engine, storage) = engine("**bold** and - x", preview: true)
        engine.selectionDidChange(NSRange(location: 3, length: 0))
        let font = storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        #expect((font?.pointSize ?? 18) < 1)              // ** stays hidden under the caret
        #expect(engine.markupDeletion(for: NSRange(location: 2, length: 0)) == nil)
    }

    @Test func backspaceRemovesHiddenMarkup() {
        let (engine, _) = engine("## Heading")
        let edit = engine.markupDeletion(for: NSRange(location: 3, length: 0))
        #expect(edit?.applied(to: "## Heading") == "Heading")
        #expect(edit?.selection == NSRange(location: 0, length: 0))
    }

    @Test func linksResolveThroughTheNote() {
        let (engine, _) = engine("[a][x] and [b](#notes)\n\n## Notes\n\n[x]: https://example.com")
        guard let reference = engine.link(at: 1) else {
            Issue.record("no link")
            return
        }
        #expect(reference.range == NSRange(location: 0, length: 6))
        #expect(engine.destination(of: reference.target) == .external(URL(string: "https://example.com")!))
        #expect(engine.displayAddress(of: reference.target) == "https://example.com")
        guard let anchor = engine.link(at: 12) else {
            Issue.record("no anchor link")
            return
        }
        #expect(engine.destination(of: anchor.target) == .anchor(24))
        #expect(engine.displayAddress(of: anchor.target) == "Section “Notes”")
    }

    @Test func printingTurnsDrawingsIntoCharacters() {
        let (engine, _) = engine("- a\n- [x] b\n\n---\n")
        let copy = engine.printableCopy().string
        #expect(copy.hasPrefix("• a\n☑ [x] b"))
        #expect(copy.contains("─"))
    }
}
