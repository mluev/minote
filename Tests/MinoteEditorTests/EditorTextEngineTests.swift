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
        #expect(engine.markupDeletion(for: NSRange(location: 7, length: 0))?.applied(to: "text\n- item") == "text\nitem")
    }

    /// Markup is ordinary text in the source view and inside code blocks.
    @Test func sourceViewAndCodeKeepMarkupOrdinary() {
        let (source, _) = engine("- item", showsSyntax: true)
        #expect(source.adjustedSelection(NSRange(location: 0, length: 0), previous: nil) == NSRange(location: 0, length: 0))
        let (code, _) = engine("```\n- item\n```")
        #expect(code.adjustedSelection(NSRange(location: 4, length: 0), previous: nil) == NSRange(location: 4, length: 0))
        #expect(code.markupDeletion(for: NSRange(location: 6, length: 0)) == nil)
        #expect(code.newlineEdit(for: NSRange(location: 10, length: 0)) == nil)
        #expect(code.listShiftEdit(for: NSRange(location: 10, length: 0), outdent: false) == nil)
        let (list, _) = engine("- item")
        #expect(list.newlineEdit(for: NSRange(location: 6, length: 0))?.applied(to: "- item") == "- item\n- ")
        #expect(list.listShiftEdit(for: NSRange(location: 6, length: 0), outdent: false)?.applied(to: "- item") == "  - item")
    }

    @Test func previewNeitherRevealsNorEdits() {
        let (engine, storage) = engine("**bold** and - x", preview: true)
        engine.selectionDidChange(NSRange(location: 3, length: 0))
        let font = storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        #expect((font?.pointSize ?? 18) < 1)              // ** stays hidden under the caret
        #expect(engine.markupDeletion(for: NSRange(location: 2, length: 0)) == nil)
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

    @Test func typingStylesTheLineOnce() {
        let (engine, storage) = engine("Some **bold** text\nnext")
        engine.selectionDidChange(NSRange(location: 9, length: 0))
        storage.replaceCharacters(in: NSRange(location: 9, length: 0), with: "x")

        // Restyling a line resets its attributes, which would drop this probe.
        let probe = NSAttributedString.Key("Probe")
        storage.addAttribute(probe, value: true, range: NSRange(location: 0, length: 4))
        engine.selectionDidChange(NSRange(location: 10, length: 0))
        #expect(storage.attribute(probe, at: 0, effectiveRange: nil) != nil)
        func markupSize() -> CGFloat { (storage.attribute(.font, at: 5, effectiveRange: nil) as? NSFont)?.pointSize ?? 0 }
        #expect(markupSize() > 1)                          // ** shows under the caret

        // Moving to another line still restyles the one it left.
        engine.selectionDidChange(NSRange(location: 21, length: 0))
        #expect(markupSize() < 1)
    }

    /// A table header's look depends on the row below it: only a table row
    /// above an edited line is restyled with it.
    @Test func onlyATableRowAboveTheEditIsRestyled() {
        func isBold(_ storage: NSTextStorage, at index: Int) -> Bool {
            (storage.attribute(.font, at: index, effectiveRange: nil) as? NSFont)?.fontDescriptor.symbolicTraits.contains(.bold) == true
        }
        let (table, storage) = engine("| a |\n| b |")
        #expect(!isBold(storage, at: 2))
        storage.replaceCharacters(in: NSRange(location: 8, length: 1), with: "-")   // "| - |": now a delimiter row
        #expect(isBold(storage, at: 2))
        _ = table

        let (prose, text) = engine("above\nline")
        let probe = NSAttributedString.Key("Probe")
        text.addAttribute(probe, value: true, range: NSRange(location: 0, length: 5))
        text.replaceCharacters(in: NSRange(location: 6, length: 0), with: "x")      // typed at the start of the line below
        #expect(text.attribute(probe, at: 0, effectiveRange: nil) != nil)
        _ = prose
    }

    @Test func printingTurnsDrawingsIntoCharacters() {
        let (engine, _) = engine("- a\n- [x] b\n\n---\n")
        let copy = engine.printableCopy().string
        #expect(copy.hasPrefix("• a\n☑ [x] b"))
        #expect(copy.contains("─"))
    }
}
