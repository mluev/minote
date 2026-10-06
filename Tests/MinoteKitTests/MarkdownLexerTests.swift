import Foundation
import Testing
@testable import MinoteKit

/// Renders spans as a compact string for readable assertions:
/// each styled range becomes `style(text)`.
private func describe(_ line: String, insideFence: Bool = false) -> [String] {
    let result = MarkdownLexer.lex(line, insideFence: insideFence)
    let units = Array(line.utf16)
    return result.spans
        .sorted { ($0.range.lowerBound, $0.style.rawValue) < ($1.range.lowerBound, $1.style.rawValue) }
        .map { span in
            let text = String(decoding: units[span.range], as: UTF16.self)
            return "\(span.style)(\(text))"
        }
}

@Suite("Markdown lexer")
struct MarkdownLexerTests {
    // MARK: Blocks

    @Test func headings() {
        let line = MarkdownLexer.lex("## Hello world")
        #expect(line.kind == .heading(level: 2))
        #expect(line.contentStart == 3)
        #expect(line.hangingMarkerLength == 3)
        #expect(describe("## Hello world") == ["syntax(## )"])
        #expect(describe("# Title #") == ["syntax(# )", "syntax(#)"])
        #expect(MarkdownLexer.lex("#hashtag").kind == .paragraph)
        #expect(MarkdownLexer.lex("####### seven").kind == .paragraph)
        #expect(MarkdownLexer.lex("#").kind == .heading(level: 1))
    }

    @Test func lists() {
        #expect(MarkdownLexer.lex("- item").kind == .listItem(ordered: false))
        #expect(MarkdownLexer.lex("  * nested").kind == .listItem(ordered: false))
        #expect(MarkdownLexer.lex("12. twelve").kind == .listItem(ordered: true))
        #expect(MarkdownLexer.lex("1) paren").kind == .listItem(ordered: true))
        #expect(MarkdownLexer.lex("-not a list").kind == .paragraph)
        #expect(MarkdownLexer.lex("- item").contentStart == 2)
        #expect(describe("- item") == ["syntax(- )"])
    }

    @Test func tasks() {
        let open = MarkdownLexer.lex("- [ ] buy milk")
        #expect(open.kind == .taskItem(done: false))
        #expect(open.contentStart == 6)
        let done = MarkdownLexer.lex("- [x] call mom")
        #expect(done.kind == .taskItem(done: true))
        #expect(describe("- [x] call mom").contains("strikethrough(call mom)"))
    }

    @Test func blockquotes() {
        let quote = MarkdownLexer.lex("> quoted *text*")
        #expect(quote.kind == .blockquote)
        #expect(quote.contentStart == 2)
        #expect(describe("> quoted *text*") == ["syntax(> )", "syntax(*)", "emphasis(text)", "syntax(*)"])
        #expect(MarkdownLexer.lex("> - item in quote").contentStart == 4)
    }

    @Test func fencesAndCode() {
        #expect(MarkdownLexer.lex("```swift").kind == .fence)
        #expect(MarkdownLexer.lex("~~~").kind == .fence)
        #expect(MarkdownLexer.lex("``").kind == .paragraph)
        #expect(MarkdownLexer.lex("let x = *y*", insideFence: true).kind == .code)
        #expect(describe("let x = *y*", insideFence: true).isEmpty)
        #expect(MarkdownLexer.lex("```", insideFence: true).kind == .fence)
    }

    @Test func thematicBreaks() {
        #expect(MarkdownLexer.lex("---").kind == .thematicBreak)
        #expect(MarkdownLexer.lex("* * *").kind == .thematicBreak)
        #expect(MarkdownLexer.lex("___").kind == .thematicBreak)
        #expect(MarkdownLexer.lex("--").kind == .paragraph)
    }

    @Test func tables() {
        #expect(MarkdownLexer.lex("| a | b |").kind == .table)
        #expect(describe("|---|:-:|") == ["syntax(|---|:-:|)"])
        #expect(describe("| *a* | b |").filter { $0 == "syntax(|)" }.count == 3)
    }

    @Test func blankLines() {
        #expect(MarkdownLexer.lex("   ").kind == .blank)
        #expect(MarkdownLexer.lex("").kind == .blank)
    }

    // MARK: Inline

    @Test("Emphasis follows CommonMark", arguments: [
        ("*em*", ["syntax(*)", "emphasis(em)", "syntax(*)"]),
        ("_em_", ["syntax(_)", "emphasis(em)", "syntax(_)"]),
        ("**strong**", ["syntax(**)", "strong(strong)", "syntax(**)"]),
        ("__strong__", ["syntax(__)", "strong(strong)", "syntax(__)"]),
        ("~~gone~~", ["syntax(~~)", "strikethrough(gone)", "syntax(~~)"]),
        ("snake_case_name", []),
        ("2 * 3 * 4", []),
        ("* not emphasis*", ["syntax(* )"]),
        ("**unclosed", []),
    ])
    func emphasis(input: String, expected: [String]) {
        #expect(describe(input) == expected)
    }

    @Test func longLinesFullOfDelimitersStayFast() {
        // Pasted data and minified code: thousands of delimiters on one line
        // once took quadratic time on every keystroke.
        let lines = [
            String(repeating: "a* ", count: 20_000),
            String(repeating: "*a ", count: 20_000),
            String(repeating: "_x *y ", count: 10_000) + String(repeating: "z* ", count: 10_000),
        ]
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            for line in lines { _ = MarkdownLexer.lex(line) }
        }
        #expect(elapsed < .seconds(2))
        #expect(describe("*a* " + String(repeating: "b* ", count: 1_000)).prefix(3) == ["syntax(*)", "emphasis(a)", "syntax(*)"])
    }

    @Test func nestedEmphasis() {
        let spans = describe("***both***")
        #expect(spans.contains("strong(both)"))
        #expect(spans.contains { $0.hasPrefix("emphasis(") })
        #expect(describe("**bold _and italic_**").contains("emphasis(and italic)"))
    }

    @Test func codeSpansProtectTheirContent() {
        #expect(describe("use `*args*` here") == ["syntax(`)", "code(*args*)", "syntax(`)"])
        #expect(describe("``a ` b``") == ["syntax(``)", "code(a ` b)", "syntax(``)"])
        #expect(describe("`unclosed").isEmpty)
    }

    @Test func escapes() {
        #expect(describe("\\*not em\\*") == ["syntax(\\)", "syntax(\\)"])
    }

    @Test func links() {
        #expect(describe("see [the docs](https://example.com) now") ==
            ["syntax([)", "link(the docs)", "syntax(]()", "destination(https://example.com)", "syntax())"])
        let image = describe("![alt](img.png)")
        #expect(image.first == "syntax(![)")
        #expect(image.contains("destination(img.png)"))
        #expect(describe("[ref][1]").contains("destination(1)"))
        #expect(describe("note[^1]") == ["syntax([^)", "link(1)", "syntax(])"])
        #expect(describe("[a](b(c)d)").contains("destination(b(c)d)"))
    }

    @Test func bareAndAutoLinks() {
        #expect(describe("visit https://ia.net.") == ["url(https://ia.net)"])
        #expect(describe("<mailto:me@x.com>") == ["syntax(<)", "url(mailto:me@x.com)", "syntax(>)"])
        #expect(describe("a_b https://x.com/a_b_c_ d").contains("url(https://x.com/a_b_c)"))
    }

    @Test func linkDefinitions() {
        let line = MarkdownLexer.lex("[1]: https://example.com \"Title\"")
        #expect(line.kind == .linkDefinition)
        #expect(describe("[1]: https://example.com").contains("url(https://example.com)"))
    }

    @Test func emphasisInsideHeadingsAndLists() {
        #expect(describe("# A *b*").contains("emphasis(b)"))
        #expect(describe("- **bold** item").contains("strong(bold)"))
    }

    @Test func nonASCIIText() {
        #expect(describe("*Привет* мир") == ["syntax(*)", "emphasis(Привет)", "syntax(*)"])
        #expect(describe("**😀 emoji**") == ["syntax(**)", "strong(😀 emoji)", "syntax(**)"])
    }
}

@Suite("Fence index")
struct FenceIndexTests {
    @Test func findsBlocks() {
        let text = "a\n```\ncode\n```\nb\n~~~~\nx\n~~~\nstill\n" as NSString
        let index = FenceIndex(text: text)
        // Second block: a ~~~ (3) can't close a ~~~~ (4) fence, so it runs to the end.
        #expect(index.blocks.count == 2)
        #expect(index.contains(text.range(of: "code").location))
        #expect(!index.contains(text.range(of: "b\n").location))
        #expect(index.contains(text.range(of: "still").location))
    }

    @Test func plainTypingOnlyShifts() {
        let original = "intro\n```\ncode\n```\n" as NSString
        var index = FenceIndex(text: original)
        let edited = "intro typed\n```\ncode\n```\n" as NSString
        let invalidated = index.update(edited, editedRange: NSRange(location: 5, length: 6), changeInLength: 6)
        #expect(invalidated == nil)
        #expect(index.blocks == FenceIndex(text: edited).blocks)
    }

    @Test func typingAFenceInvalidatesWhatFollows() {
        let original = "a\nb\nc\n" as NSString
        var index = FenceIndex(text: original)
        let edited = "```\na\nb\nc\n" as NSString
        let invalidated = index.update(edited, editedRange: NSRange(location: 0, length: 4), changeInLength: 4)
        #expect(invalidated != nil)
        #expect(index.contains(edited.range(of: "c").location))
    }

    @Test func editingInsideABlockKeepsItConsistent() {
        let original = "```\nab\n```\nafter\n" as NSString
        var index = FenceIndex(text: original)
        let edited = "```\naXb\n```\nafter\n" as NSString
        _ = index.update(edited, editedRange: NSRange(location: 5, length: 1), changeInLength: 1)
        #expect(index.blocks == FenceIndex(text: edited).blocks)
        #expect(!index.contains(edited.range(of: "after").location))
    }

    @Test func deletingAClosingFenceReopensTheBlock() {
        let original = "```\ncode\n```\nafter\n" as NSString
        var index = FenceIndex(text: original)
        let edited = "```\ncode\n\nafter\n" as NSString
        let invalidated = index.update(edited, editedRange: NSRange(location: 9, length: 0), changeInLength: -3)
        #expect(invalidated != nil)
        #expect(index.contains(edited.range(of: "after").location))
    }
}

@Suite("Text statistics")
struct TextStatisticsTests {
    @Test func countsWordsLikeAWriter() {
        #expect(TextStatistics("").words == 0)
        #expect(TextStatistics("# Hello, *world*!").words == 2)
        #expect(TextStatistics("don't stop well-known").words == 3)
        #expect(TextStatistics("- [ ] buy milk\n- [ ] done").words == 3)
        #expect(TextStatistics("Привет мир").words == 2)
        #expect(TextStatistics("日本語").words == 3)
    }

    @Test func charactersExcludeLineBreaks() {
        #expect(TextStatistics("ab\ncd").characters == 4)
        #expect(TextStatistics("👩‍👩‍👧‍👦").characters == 1)
    }

    @Test func readingTime() {
        #expect(TextStatistics(words: 0, characters: 0).readingMinutes == 0)
        #expect(TextStatistics(words: 10, characters: 50).readingMinutes == 1)
        #expect(TextStatistics(words: 2380, characters: 0).readingMinutes == 10)
    }
}
