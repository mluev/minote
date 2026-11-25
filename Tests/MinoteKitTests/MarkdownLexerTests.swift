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

    @Test("A table row is what the lexer lexes as one", arguments: [
        "| a |", "   | a", "    | a", "\t| a", " \t| a", "a | b", "|", "", "  ", "> | a",
    ])
    func tableRowsAgreeWithTheLexer(line: String) {
        #expect(MarkdownLexer.isTableRow(Array(line.utf16)) == (MarkdownLexer.lex(line).kind == .table))
    }

    @Test func tablePipesAreTheCellBorders() {
        #expect(MarkdownLexer.lex("| a | b |").tablePipes == [0, 4, 8])
        #expect(MarkdownLexer.lex("|:--|--:|").tablePipes == [0, 4, 8])
        // An escaped pipe and one inside code are text.
        #expect(MarkdownLexer.lex("| a \\| b | `x|y` |").tablePipes == [0, 9, 17])
        #expect(MarkdownLexer.lex("a | b").tablePipes.isEmpty)
    }

    @Test func tableCells() {
        func cells(_ row: String) -> [String] {
            let chars = Array(row.utf16)
            return MarkdownTable.cells(of: MarkdownLexer.lex(chars, insideFence: false), in: chars)
                .map { String(decoding: chars[$0], as: UTF16.self) }
        }
        #expect(cells("| a | bb |") == [" a ", " bb "])
        #expect(cells("| a || c |") == [" a ", "", " c "])
        #expect(cells("| a | b") == [" a ", " b"])        // no closing pipe: the rest is a cell
        #expect(cells("| a |   ") == [" a "])              // trailing spaces are not
        #expect(cells("| a \\| b |") == [" a \\| b "])
    }

    @Test func tableAlignments() {
        let row = "| :-- | :-: | --: | --- | : |"
        let chars = Array(row.utf16)
        #expect(MarkdownTable.alignments(delimiterRow: MarkdownLexer.lex(chars, insideFence: false), in: chars)
            == [.left, .center, .right, .left, .left])
    }

    @Test func tablePaddingWidensEveryColumnToItsWidestCell() {
        typealias Pad = MarkdownTable.CellPadding
        let pads = MarkdownTable.padding(widths: [[10, 4, 6], [6, 8, 2], [3]], alignments: [.left, .right, .center])
        #expect(pads[0] == [Pad(leading: 0, trailing: 0), Pad(leading: 4, trailing: 0), Pad(leading: 0, trailing: 0)])
        #expect(pads[1] == [Pad(leading: 0, trailing: 4), Pad(leading: 0, trailing: 0), Pad(leading: 2, trailing: 2)])
        #expect(pads[2] == [Pad(leading: 0, trailing: 7)])   // a short row pads the cells it has
        // Every row's cells add up to the same widths.
        let widths: [[Double]] = [[10, 4, 6], [6, 8, 2]]
        let totals = zip(widths, pads).map { row, pad in zip(row, pad).map { $0 + $1.leading + $1.trailing } }
        #expect(totals[0] == totals[1])
        // Columns past the delimiter row's are left-aligned.
        #expect(MarkdownTable.padding(widths: [[1, 1], [3, 3]], alignments: [.right])[0][1] == Pad(leading: 0, trailing: 2))
    }

    @Test func aTableThatFitsKeepsItsNaturalColumns() {
        #expect(MarkdownTable.fitColumns(natural: [100, 200], minimum: [50, 80], available: 400) == [100, 200])
        #expect(MarkdownTable.fitColumns(natural: [100, 200], minimum: [50, 80], available: 300) == [100, 200])
    }

    /// Too wide: a short column keeps its width, the long ones wrap, sharing
    /// what's left by how much each lacks, never below their longest word.
    @Test func aWideTableIsFittedToThePage() {
        let natural: [Double] = [100, 600, 500], minimum: [Double] = [60, 90, 80]
        let widths = MarkdownTable.fitColumns(natural: natural, minimum: minimum, available: 600)
        #expect(abs(widths.reduce(0, +) - 600) < 0.001)
        #expect(widths[0] == 100)
        #expect(widths[1] > minimum[1] && widths[2] > minimum[2])
        #expect(widths[1] < natural[1] && widths[2] < natural[2])
        #expect(abs((widths[1] - minimum[1]) / (widths[2] - minimum[2]) - 510.0 / 420.0) < 0.001)
    }

    @Test func oneLongWordDoesNotStarveTheOtherColumns() {
        // A 900-point URL can't have its way: it breaks, and the prose column
        // gets more than its longest word.
        let widths = MarkdownTable.fitColumns(natural: [900, 800], minimum: [900, 60], available: 500)
        #expect(abs(widths.reduce(0, +) - 500) < 0.001)
        #expect(widths[0] < 900)
        #expect(widths[1] > 2 * 60)
    }

    @Test func aFittedTableNeverOverflowsThePage() {
        for available in [0.0, 30, 100, 250] {
            let widths = MarkdownTable.fitColumns(natural: [300, 300, 40], minimum: [200, 200, 40], available: available)
            #expect(widths.count == 3)
            #expect(widths.reduce(0, +) <= available + 0.001)
            #expect(widths.allSatisfy { $0 >= 0 })
        }
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
        ("==marked==", ["syntax(==)", "highlight(marked)", "syntax(==)"]),
        ("a ==b **c**== d", ["syntax(==)", "highlight(b **c**)", "syntax(**)", "strong(c)", "syntax(**)", "syntax(==)"]),
        ("=one=", []),
        ("===three===", []),
        ("==unequal===", []),
        ("x == y == z", []),
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
            String(repeating: "a== ", count: 20_000),
            String(repeating: "==a ~~b ", count: 10_000) + String(repeating: "c== ", count: 10_000),
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
        #expect(describe("[1]: https://example.com") == ["syntax([)", "label(1)", "syntax(]:)", "url(https://example.com)"])
    }

    @Test func footnoteDefinitions() {
        let line = MarkdownLexer.lex("[^1]: The footnote.")
        #expect(line.kind == .footnoteDefinition)
        #expect(line.contentStart == 6)
        #expect(describe("[^1]: The footnote.") == ["syntax([^)", "label(1)", "syntax(]:)"])
        // The text is inline text like any other.
        #expect(describe("[^note]: See *this* [site](x.com).").contains("emphasis(this)"))
        #expect(MarkdownLexer.lex("[^note]: [site](x.com)").links.map(\.target) == [.url("x.com")])
        #expect(MarkdownLexer.lex("[^1]:").kind == .footnoteDefinition)
        #expect(MarkdownLexer.lex("[^]: x").kind != .footnoteDefinition)
        #expect(MarkdownLexer.lex("[^1] not a definition").kind == .paragraph)
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
