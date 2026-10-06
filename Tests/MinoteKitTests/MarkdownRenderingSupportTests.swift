import Foundation
import Testing
@testable import MinoteKit

@Suite("Rendered Markdown support")
struct MarkdownRenderingSupportTests {
    // MARK: Lexer details

    @Test func listMarkers() {
        let bullet = MarkdownLexer.lex("  - item")
        #expect(bullet.list == MarkdownListMarker(marker: 2..<3, ordered: false, taskBox: nil, isDone: false, indentColumns: 2))
        let task = MarkdownLexer.lex("- [x] done")
        #expect(task.list?.taskBox == 2..<5)
        #expect(task.list?.isDone == true)
        let number = MarkdownLexer.lex("12. twelve")
        #expect(number.list?.marker == 0..<3)
        #expect(number.list?.ordered == true)
        #expect(MarkdownLexer.lex("plain").list == nil)
    }

    @Test func quoteDepthAndListsInQuotes() {
        #expect(MarkdownLexer.lex("> a").quoteDepth == 1)
        #expect(MarkdownLexer.lex("> > a").quoteDepth == 2)
        let listInQuote = MarkdownLexer.lex("> - a")
        #expect(listInQuote.list?.marker == 2..<3)
        #expect(listInQuote.contentStart == 4)
    }

    @Test func links() {
        #expect(MarkdownLexer.lex("[a](https://x.com \"Title\")").links == [MarkdownLink(0..<26, .url("https://x.com"))])
        #expect(MarkdownLexer.lex("[a](<my file.md>)").links.first?.target == .url("my file.md"))
        #expect(MarkdownLexer.lex("![alt](pic.png)").links.first == MarkdownLink(0..<15, .url("pic.png")))
        #expect(MarkdownLexer.lex("<https://a.b>").links == [MarkdownLink(0..<13, .url("https://a.b"))])
        #expect(MarkdownLexer.lex("go www.a.org.").links == [MarkdownLink(3..<12, .url("www.a.org"))])
        #expect(MarkdownLexer.lex("[text][Ref]").links.first?.target == .reference("Ref"))
        #expect(MarkdownLexer.lex("[text][]").links.first?.target == .reference("text"))
        #expect(MarkdownLexer.lex("note[^1]").links == [MarkdownLink(4..<8, .footnote("1"))])
        #expect(MarkdownLexer.lex("[id]: https://d.e").links == [MarkdownLink(6..<17, .url("https://d.e"))])
        #expect(MarkdownLexer.lex("`[a](b)`").links.isEmpty)
    }

    // MARK: Link resolution

    @Test func resolvesDestinations() {
        let text = "# My Heading\n\n[Ref]: https://ref.org\n[^n]: A note\n" as NSString
        #expect(MarkdownLinks.resolve(.url("https://a.b/c"), in: text) == .external(URL(string: "https://a.b/c")!))
        #expect(MarkdownLinks.resolve(.url("www.a.b"), in: text) == .external(URL(string: "https://www.a.b")!))
        #expect(MarkdownLinks.resolve(.url("me@a.b"), in: text) == .external(URL(string: "mailto:me@a.b")!))
        #expect(MarkdownLinks.resolve(.url("Other%20note.md"), in: text) == .file("Other note.md"))
        #expect(MarkdownLinks.resolve(.url("#my-heading"), in: text) == .anchor(0))
        #expect(MarkdownLinks.resolve(.url("#missing"), in: text) == nil)
        #expect(MarkdownLinks.resolve(.reference("ref"), in: text) == .external(URL(string: "https://ref.org")!))
        #expect(MarkdownLinks.resolve(.reference("none"), in: text) == nil)
        #expect(MarkdownLinks.resolve(.footnote("n"), in: text) == .anchor(37))
    }

    @Test func headingAnchorsIgnoreClosingHashes() {
        let text = "## Setup ##\n\n### C#\n" as NSString
        #expect(MarkdownLinks.resolve(.url("#setup"), in: text) == .anchor(0))
        #expect(MarkdownLinks.resolve(.url("#c"), in: text) == .anchor(13))
        #expect(MarkdownLinks.headingTitle("Title  ###  ") == "Title")
        #expect(MarkdownLinks.headingTitle("C#") == "C#")
        #expect(MarkdownLinks.headingTitle("##") == "")
    }

    @Test func slugs() {
        #expect(MarkdownLinks.slug("Hello, World!") == "hello-world")
        #expect(MarkdownLinks.slug("Über 2 Things") == "über-2-things")
    }

    // MARK: Hidden markup

    @Test func hiddenMarkupZones() {
        let text = "## Title\n- item\n- [ ] task\n> quote\n---\nplain" as NSString
        #expect(MarkdownEditing.hiddenMarkup(in: text, at: 0, insideFence: false)?.home == 3)
        #expect(MarkdownEditing.hiddenMarkup(in: text, at: 9, insideFence: false)?.zone == NSRange(location: 9, length: 2))
        #expect(MarkdownEditing.hiddenMarkup(in: text, at: 16, insideFence: false)?.home == 22)
        #expect(MarkdownEditing.hiddenMarkup(in: text, at: 27, insideFence: false)?.home == 29)
        let rule = MarkdownEditing.hiddenMarkup(in: text, at: 35, insideFence: false)
        #expect(rule?.zone == NSRange(location: 35, length: 3))
        #expect(rule?.home == 38)
        #expect(MarkdownEditing.hiddenMarkup(in: text, at: 39, insideFence: false) == nil)
        #expect(MarkdownEditing.hiddenMarkup(in: text, at: 9, insideFence: true) == nil)
    }

    @Test func caretAdjustment() {
        let text = "- a\n- b" as NSString
        #expect(MarkdownEditing.adjustedCaret(0, previous: nil, in: text, insideFence: false) == 2)
        #expect(MarkdownEditing.adjustedCaret(1, previous: 2, in: text, insideFence: false) == 2)   // first line: nowhere to go
        #expect(MarkdownEditing.adjustedCaret(5, previous: 6, in: text, insideFence: false) == 3)   // to the line above
        #expect(MarkdownEditing.adjustedCaret(4, previous: 3, in: text, insideFence: false) == 6)   // Right arrow into the line
        #expect(MarkdownEditing.adjustedCaret(3, previous: nil, in: text, insideFence: false) == 3)
    }

    @Test(arguments: [
        ("## Head", 3, "Head", 0),
        ("- item", 2, "item", 0),
        ("  - nested", 4, "- nested", 2),
        ("- [ ] task", 6, "task", 0),
        ("1. one", 3, "one", 0),
        ("> quote", 2, "quote", 0),
        ("> > deep", 4, "> deep", 2),
        ("> - item", 4, "> item", 2),
        ("---", 3, "", 0),
    ])
    func deletingMarkup(text: String, caret: Int, expected: String, newCaret: Int) {
        let edit = MarkdownEditing.deleteMarkup(in: text as NSString, selection: NSRange(location: caret, length: 0), insideFence: false)
        #expect(edit?.applied(to: text) == expected)
        #expect(edit?.selection == NSRange(location: newCaret, length: 0))
    }

    @Test func ordinaryBackspaceIsLeftAlone() {
        #expect(MarkdownEditing.deleteMarkup(in: "- item", selection: NSRange(location: 3, length: 0), insideFence: false) == nil)
        #expect(MarkdownEditing.deleteMarkup(in: "- item", selection: NSRange(location: 2, length: 2), insideFence: false) == nil)
        #expect(MarkdownEditing.deleteMarkup(in: "plain", selection: NSRange(location: 0, length: 0), insideFence: false) == nil)
    }
}
