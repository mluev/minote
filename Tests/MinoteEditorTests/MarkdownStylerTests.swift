import AppKit
import CoreText
import MinoteKit
import Testing
@testable import MinoteEditor

@MainActor
@Suite("Markdown styler")
struct MarkdownStylerTests {
    private func styled(_ text: String, reveal: NSRange? = nil, showsSyntax: Bool = false, focus: NSRange? = nil,
                        width: CGFloat? = nil) -> (NSTextStorage, EditorStyleSheet) {
        let sheet = EditorStyleSheet(family: .sfMono, size: 18)
        let styler = MarkdownStyler(styleSheet: sheet)
        styler.revealRange = reveal
        styler.showsSyntax = showsSyntax
        styler.focusRange = focus
        if let width { styler.availableWidth = width }
        let storage = NSTextStorage(string: text)
        styler.style(storage, range: NSRange(location: 0, length: storage.length), fences: FenceIndex(text: storage.mutableString))
        return (storage, sheet)
    }

    private func isHidden(_ storage: NSTextStorage, at index: Int) -> Bool {
        let font = storage.attribute(.font, at: index, effectiveRange: nil) as? NSFont
        let color = storage.attribute(.foregroundColor, at: index, effectiveRange: nil) as? NSColor
        return (font?.pointSize ?? 18) < 1 && color == .clear
    }

    private func font(_ storage: NSTextStorage, at index: Int) -> NSFont? {
        storage.attribute(.font, at: index, effectiveRange: nil) as? NSFont
    }

    @Test func markupIsHiddenAndStyleShows() {
        let (storage, _) = styled("a **bold** and _it_")
        #expect(isHidden(storage, at: 2) && isHidden(storage, at: 3))   // **
        #expect(isHidden(storage, at: 8) && isHidden(storage, at: 9))   // **
        #expect(font(storage, at: 4)?.fontDescriptor.symbolicTraits.contains(.bold) == true)
        #expect(font(storage, at: 16)?.fontDescriptor.symbolicTraits.contains(.italic) == true)
        #expect(!isHidden(storage, at: 0))
    }

    @Test func highlightedTextIsMarkedAndItsMarkupHidden() {
        func background(_ storage: NSTextStorage, at index: Int) -> NSColor? {
            storage.attribute(.backgroundColor, at: index, effectiveRange: nil) as? NSColor
        }
        let (storage, _) = styled("a ==mark== b")
        #expect(isHidden(storage, at: 2) && isHidden(storage, at: 8))
        #expect(background(storage, at: 4) == EditorPalette.standard.highlight)
        #expect(background(storage, at: 2) == nil && background(storage, at: 11) == nil)
        // Under the caret the markup shows, unmarked.
        let (near, _) = styled("a ==mark== b", reveal: NSRange(location: 5, length: 0))
        #expect(!isHidden(near, at: 2) && background(near, at: 2) == nil)
        #expect(background(near, at: 5) == EditorPalette.standard.highlight)
        let (source, _) = styled("a ==mark== b", showsSyntax: true)
        #expect(color(source, at: 2) == EditorPalette.standard.syntax)
        #expect(background(source, at: 4) == EditorPalette.standard.highlight)
    }

    @Test func onlyTheFormattingUnderTheCaretShowsItsMarkup() {
        let text = "**one** plain _two_\n**three**"
        let (storage, _) = styled(text, reveal: NSRange(location: 3, length: 0))  // inside "one"
        #expect(!isHidden(storage, at: 0))                               // ** around "one": shown
        #expect(storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == EditorPalette.standard.syntax)
        #expect(!isHidden(storage, at: 5))
        #expect(isHidden(storage, at: 14))                               // _ around "two": hidden
        #expect(isHidden(storage, at: 20))                               // other line: hidden

        let (plain, _) = styled(text, reveal: NSRange(location: 10, length: 0))  // inside "plain"
        #expect(isHidden(plain, at: 0) && isHidden(plain, at: 14))
    }

    @Test func caretAfterTheLineBreakBelongsToTheNextLine() {
        let (storage, _) = styled("**one**\n", reveal: NSRange(location: 8, length: 0))
        #expect(isHidden(storage, at: 0))
    }

    @Test func headingsAreLargerAndTheirMarkersNeverShow() {
        let (storage, sheet) = styled("# Title\n## A **b** c", reveal: NSRange(location: 4, length: 0))
        #expect(isHidden(storage, at: 0))                 // # stays hidden under the caret
        #expect(font(storage, at: 2)?.pointSize == sheet.heading(level: 1).font.pointSize)
        #expect((font(storage, at: 2)?.pointSize ?? 0) > (font(storage, at: 11)?.pointSize ?? 0))
        #expect((font(storage, at: 11)?.pointSize ?? 0) > 18)
        #expect(isHidden(storage, at: 13))                // ** away from the caret
        let (near, _) = styled("## A **b** c", reveal: NSRange(location: 6, length: 0))
        #expect(isHidden(near, at: 0) && !isHidden(near, at: 5))
    }

    @Test func sourceViewNeitherHidesNorDraws() {
        let (storage, _) = styled("# Title **x**\n- [ ] a\n> q", showsSyntax: true)
        #expect(!isHidden(storage, at: 0))
        #expect(font(storage, at: 2)?.pointSize == 18)
        #expect(mark(storage, at: 14) == nil)
        #expect(block(storage, at: 22) == nil)
        #expect(color(storage, at: 14) == EditorPalette.standard.syntax)
    }

    private func mark(_ storage: NSTextStorage, at index: Int) -> MarkdownMark? {
        (storage.attribute(.minoteMark, at: index, effectiveRange: nil) as? String).flatMap(MarkdownMark.init(rawValue:))
    }

    private func block(_ storage: NSTextStorage, at index: Int) -> MarkdownBlock? {
        (storage.attribute(.minoteBlock, at: index, effectiveRange: nil) as? String).flatMap(MarkdownBlock.init(rawValue:))
    }

    private func color(_ storage: NSTextStorage, at index: Int) -> NSColor? {
        storage.attribute(.foregroundColor, at: index, effectiveRange: nil) as? NSColor
    }

    @Test func bulletsAreDrawnAndNumbersStayText() {
        let (storage, _) = styled("- item\n  - nested\n1. one", reveal: NSRange(location: 3, length: 0))
        #expect(mark(storage, at: 0) == .bullet(level: 0))
        #expect(color(storage, at: 0) == .clear)
        #expect(!isHidden(storage, at: 0))                // keeps its width: the text doesn't move
        #expect(mark(storage, at: 9) == .bullet(level: 1))
        #expect(mark(storage, at: 2) == nil)
        #expect(color(storage, at: 18) == EditorPalette.standard.listMarker)
        #expect(mark(storage, at: 18) == nil)
    }

    @Test func taskBoxesAreDrawnAndTheirBracketsHidden() {
        let (storage, _) = styled("- [ ] open\n- [x] done", reveal: NSRange(location: 7, length: 0))
        #expect(mark(storage, at: 0) == .checkbox(done: false))
        #expect(isHidden(storage, at: 2) && isHidden(storage, at: 4) && isHidden(storage, at: 5))
        #expect(mark(storage, at: 11) == .checkbox(done: true))
        #expect(storage.attribute(.strikethroughStyle, at: 17, effectiveRange: nil) != nil)
        #expect(color(storage, at: 17) == EditorPalette.standard.doneTask)
    }

    @Test func quotesHideTheirMarkerAndGetABar() {
        let (storage, _) = styled("> > deep", reveal: NSRange(location: 5, length: 0))
        #expect(isHidden(storage, at: 0) && isHidden(storage, at: 2))
        #expect(block(storage, at: 4) == .quote(depth: 2))
    }

    @Test func rulesAreDrawn() {
        let (storage, _) = styled("a\n\n---\n")
        #expect(isHidden(storage, at: 3))
        #expect(mark(storage, at: 3) == .rule)
    }

    /// While a table is edited (the caret on one of its rows), its rows are
    /// text over a grid.
    @Test func tablePipesBecomeLines() {
        let (storage, _) = styled("| a | b |\n|---|---|\n| 1 | 2 |", reveal: NSRange(location: 24, length: 0))
        #expect(mark(storage, at: 0) == .tablePipe)
        #expect(color(storage, at: 0) == .clear)
        #expect(font(storage, at: 2)?.fontDescriptor.symbolicTraits.contains(.bold) == true)  // header row
        #expect(font(storage, at: 22)?.fontDescriptor.symbolicTraits.contains(.bold) != true)
        // The delimiter row: invisible dashes that keep their width, pipes still lines.
        #expect(color(storage, at: 11) == .clear && !isHidden(storage, at: 11))
        #expect(mark(storage, at: 11) == nil && mark(storage, at: 14) == .tablePipe)
    }

    @Test func tableRowsDrawTheirPartOfTheGrid() {
        let (storage, _) = styled("| a | b |\n|---|---|\n| 1 | 2 |\n| 3 | 4 |\n\nafter", reveal: NSRange(location: 32, length: 0))
        #expect(block(storage, at: 0) == .tableRow(top: true, bottom: false, header: true, delimiter: false))
        #expect(block(storage, at: 10) == .tableRow(top: false, bottom: false, header: false, delimiter: true))
        #expect(block(storage, at: 20) == .tableRow(top: false, bottom: true, header: false, delimiter: false))
        #expect(block(storage, at: 30) == .tableRow(top: false, bottom: true, header: false, delimiter: false))
        #expect(block(storage, at: 41) == nil)
        #expect(MarkdownBlock(rawValue: MarkdownBlock.tableRow(top: true, bottom: false, header: true, delimiter: false).rawValue)
            == .tableRow(top: true, bottom: false, header: true, delimiter: false))
    }

    /// Where each pipe's glyph of every row sits along its line, kerning
    /// included. (Caret offsets won't do: they sit halfway through kerning.)
    static func pipePositions(_ storage: NSTextStorage) -> [[Double]] {
        var rows: [[Double]] = []
        var location = 0
        for contents in storage.string.components(separatedBy: "\n") {
            let length = contents.utf16.count
            let line = CTLineCreateWithAttributedString(storage.attributedSubstring(from: NSRange(location: location, length: length)))
            var x: [Int: Double] = [:]
            for run in CTLineGetGlyphRuns(line) as? [CTRun] ?? [] {
                let count = CTRunGetGlyphCount(run)
                var positions = [CGPoint](repeating: .zero, count: count)
                var indices = [CFIndex](repeating: 0, count: count)
                CTRunGetPositions(run, CFRange(location: 0, length: 0), &positions)
                CTRunGetStringIndices(run, CFRange(location: 0, length: 0), &indices)
                for (index, position) in zip(indices, positions) { x[index] = position.x }
            }
            rows.append(MarkdownLexer.lex(contents).tablePipes.map { x[$0] ?? -1 })
            location += length + 1
        }
        return rows
    }

    static func lineUp(_ rows: [[Double]]) -> Bool {
        rows.allSatisfy { row in row.count == rows[0].count && zip(row, rows[0]).allSatisfy { abs($0 - $1) < 0.01 } }
    }

    @Test(arguments: [EditorFontFamily.sfMono, .sfPro])
    func tableColumnsLineUp(_ family: EditorFontFamily) {
        let text = "| Name | **Role** | Score |\n|:-----|:-:|---:|\n| Alice Smith | Engineer | 42 |\n| Bob | [PM](https://x.com) | 1000 |"
        let styler = MarkdownStyler(styleSheet: EditorStyleSheet(family: family, size: 18))
        styler.revealRange = NSRange(location: (text as NSString).range(of: "Alice").location, length: 0)
        let storage = NSTextStorage(string: text)
        styler.style(storage, range: NSRange(location: 0, length: storage.length), fences: FenceIndex(text: storage.mutableString))
        let rows = Self.pipePositions(storage)
        #expect(rows.count == 4 && rows[0].count == 4)
        #expect(Self.lineUp(rows))
        // The widest cell sets its column's width: nothing pads "Alice Smith".
        #expect(storage.attribute(.kern, at: (text as NSString).range(of: "Smith ").upperBound - 1, effectiveRange: nil) == nil)
    }

    @Test func aTableRowUnderTheCaretStillLinesUp() {
        let (storage, _) = styled("| **a** | b |\n| cc | d |", reveal: NSRange(location: 4, length: 0))
        #expect(!isHidden(storage, at: 2))                // its ** show…
        #expect(Self.lineUp(Self.pipePositions(storage))) // …and the other row makes room
    }

    @Test func tableMarkupIsHiddenButEscapedPipesAreText() {
        let (storage, _) = styled("| **a** | x \\| y |\n|---|---|", reveal: NSRange(location: 22, length: 0))
        #expect(isHidden(storage, at: 2) && isHidden(storage, at: 5))       // ** away from the caret
        #expect(isHidden(storage, at: 12))                                   // the escaping backslash
        #expect(mark(storage, at: 13) == nil && color(storage, at: 13) != .clear)
        #expect(font(storage, at: 13)?.fontDescriptor.symbolicTraits.contains(.bold) == true)
    }

    /// Lining up a table restyles all of it on every keystroke: a huge pasted
    /// table keeps its grid but not its columns.
    @Test func onlyTablesUpToTwoHundredRowsLineUp() {
        func hasKerning(rows: Int) -> Bool {
            let text = "| wide cell | b |\n" + String(repeating: "| a | b |\n", count: rows - 1)
            let (storage, _) = styled(text)
            var found = false
            storage.enumerateAttribute(.kern, in: NSRange(location: 0, length: storage.length)) { value, _, stop in
                if value != nil { found = true; stop.pointee = true }
            }
            #expect(mark(storage, at: storage.length - 2) == .tablePipe)
            return found
        }
        #expect(hasKerning(rows: 200))
        #expect(!hasKerning(rows: 201))
    }

    private func tableLine(_ storage: NSTextStorage, at index: Int) -> RenderedTable.Line? {
        storage.attribute(.minoteTable, at: index, effectiveRange: nil) as? RenderedTable.Line
    }

    private func hasAttribute(_ key: NSAttributedString.Key, in storage: NSTextStorage) -> Bool {
        var found = false
        storage.enumerateAttribute(key, in: NSRange(location: 0, length: storage.length)) { value, _, stop in
            if value != nil { found = true; stop.pointee = true }
        }
        return found
    }

    /// A table nobody is editing is drawn in place of its rows: their text is
    /// hidden and each source line is as tall as its part of the table.
    @Test func anUneditedTableIsDrawnInPlaceOfItsRows() {
        let text = "| **Name** | [Role](https://x.com) |\n|---|:-:|\n| Alice | Engineer |\n| Bob \\| Eve | `PM` |\n\nafter"
        let (storage, sheet) = styled(text)
        let string = text as NSString
        let after = string.range(of: "after").location
        for i in 0..<(after - 1) { #expect(isHidden(storage, at: i)) }
        #expect(!isHidden(storage, at: after) && tableLine(storage, at: after) == nil)

        var lineStarts: [Int] = []
        string.enumerateSubstrings(in: NSRange(location: 0, length: after - 1), options: [.byLines, .substringNotRequired]) { _, range, _, _ in
            lineStarts.append(range.location)
        }
        let lines = lineStarts.compactMap { tableLine(storage, at: $0) }
        #expect(lines.map(\.part) == [.row(0), .rule, .row(1), .row(2)])
        guard let table = lines.first?.table else { return }
        #expect(lines.allSatisfy { $0.table === table })
        for (start, line) in zip(lineStarts, lines) {
            let style = storage.attribute(.paragraphStyle, at: start, effectiveRange: nil) as? NSParagraphStyle
            #expect(style?.maximumLineHeight == line.height && style?.minimumLineHeight == line.height)
        }

        // The cells show their text as styled, without the markup.
        #expect(table.rows.map { $0.cells.map(\.string) } == [["Name", "Role"], ["Alice", "Engineer"], ["Bob | Eve", "PM"]])
        let name = table.rows[0].cells[0], role = table.rows[0].cells[1]
        #expect((name.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.fontDescriptor.symbolicTraits.contains(.bold) == true)
        #expect(role.attribute(.underlineStyle, at: 0, effectiveRange: nil) != nil)
        #expect(table.rows[2].cells[1].attribute(.backgroundColor, at: 0, effectiveRange: nil) as? NSColor == EditorPalette.standard.codeBackground)
        #expect(table.width <= sheet.columnWidth)
    }

    /// The caret on any row shows the whole table as text.
    @Test func editingAnyRowShowsTheWholeTableAsText() {
        let text = "| a | b |\n|---|---|\n| 1 | 2 |\n| 3 | 4 |"
        for row in [0, 10, 20, 30] {
            let (storage, _) = styled(text, reveal: NSRange(location: row + 2, length: 0))
            #expect(!hasAttribute(.minoteTable, in: storage))
            #expect(!isHidden(storage, at: 2) && !isHidden(storage, at: 32))
        }
        // So does a selection reaching into it.
        let (selected, _) = styled("x\n" + text, reveal: NSRange(location: 0, length: 4))
        #expect(!hasAttribute(.minoteTable, in: selected))
    }

    @Test func aTableWithoutADelimiterRowIsNeverDrawn() {
        let (storage, _) = styled("| a | b |\n| c | d |")
        #expect(!hasAttribute(.minoteTable, in: storage))
        #expect(mark(storage, at: 0) == .tablePipe && !isHidden(storage, at: 2))
    }

    /// On a narrow page a long cell wraps inside its column, and its row grows.
    @Test func aDrawnTableFitsThePageAndItsCellsWrap() {
        let long = Array(repeating: "words", count: 30).joined(separator: " ")
        let text = "| Ask | What |\n|---|---|\n| Short | \(long) |"
        func table(width: CGFloat) -> RenderedTable? {
            let (storage, _) = styled(text, width: width)
            return tableLine(storage, at: 0)?.table
        }
        guard let wide = table(width: 4000), let narrow = table(width: 300) else {
            Issue.record("no drawn table")
            return
        }
        #expect(narrow.width <= 300)
        #expect(wide.rows[1].height == wide.rows[0].height)            // one line each
        #expect(narrow.rows[1].height > 3 * wide.rows[1].height)        // the long cell wraps
        #expect(narrow.rows[0].height == wide.rows[0].height)           // the header still fits on a line
        #expect(narrow.columnWidths[0] == wide.columnWidths[0])         // so does the short column
    }

    @Test func aTableInsideCodeIsCode() {
        let (storage, _) = styled("```\n| a |\n```")
        #expect(mark(storage, at: 4) == nil)
        #expect(block(storage, at: 4) == .code(top: false, bottom: false))
    }

    @Test func linksShowTheirTextAndCarryTheirTarget() {
        let (storage, _) = styled("see [site](https://x.com) and www.y.org")
        #expect(isHidden(storage, at: 4))                 // [
        #expect(!isHidden(storage, at: 5))                // s
        #expect(storage.attribute(.underlineStyle, at: 5, effectiveRange: nil) != nil)
        #expect(isHidden(storage, at: 12))                // inside the destination
        #expect(LinkAttribute.decode(storage.attribute(.minoteLink, at: 4, effectiveRange: nil)) == .url("https://x.com"))
        #expect(LinkAttribute.decode(storage.attribute(.minoteLink, at: 32, effectiveRange: nil)) == .url("www.y.org"))
        #expect(storage.attribute(.minoteLink, at: 1, effectiveRange: nil) == nil)
    }

    @Test func footnoteDefinitionsShowTheirTextAndAQuietLabel() {
        let text = "[^1]: The footnote, *see* [site](https://x.com)."
        let (storage, _) = styled(text)
        #expect(isHidden(storage, at: 0) && isHidden(storage, at: 1))      // [^
        #expect(color(storage, at: 2) == EditorPalette.standard.syntax)   // 1
        #expect(isHidden(storage, at: 3) && isHidden(storage, at: 4))      // ]:
        let body = (text as NSString).range(of: "The footnote")
        for i in body.location..<NSMaxRange(body) { #expect(!isHidden(storage, at: i)) }
        #expect(color(storage, at: body.location) == EditorPalette.standard.text)
        #expect(font(storage, at: (text as NSString).range(of: "see").location)?.fontDescriptor.symbolicTraits.contains(.italic) == true)
        #expect(storage.attribute(.underlineStyle, at: (text as NSString).range(of: "site").location, effectiveRange: nil) != nil)
        // A link definition's label is just as quiet: no underline.
        let (definition, _) = styled("[ref]: https://x.com")
        #expect(color(definition, at: 1) == EditorPalette.standard.syntax)
        #expect(definition.attribute(.underlineStyle, at: 1, effectiveRange: nil) == nil)
    }

    @Test func codeBlocksHideFencesAndSitInABox() {
        let (storage, _) = styled("```\nlet x = 1\n\n```\nafter")
        #expect(isHidden(storage, at: 0))
        #expect(block(storage, at: 0) == .code(top: true, bottom: false))
        #expect(block(storage, at: 4) == .code(top: false, bottom: false))
        #expect(block(storage, at: 14) == .code(top: false, bottom: false))   // the blank line inside
        #expect(block(storage, at: 15) == .code(top: false, bottom: true))
        #expect(block(storage, at: 19) == nil)
        #expect(storage.attribute(.backgroundColor, at: 4, effectiveRange: nil) == nil)
    }

    @Test func aFenceShowsWhenTheCaretIsOnIt() {
        let (storage, _) = styled("```swift\ncode\n```", reveal: NSRange(location: 3, length: 0))
        #expect(!isHidden(storage, at: 3))
        #expect(isHidden(storage, at: 14))
    }

    @Test func focusFadingKeepsHiddenMarkupHidden() {
        let (storage, _) = styled("**a**\nfocused", focus: NSRange(location: 6, length: 7))
        #expect(isHidden(storage, at: 0))
        #expect(storage.attribute(.minoteFaded, at: 2, effectiveRange: nil) != nil)
        #expect(storage.attribute(.minoteFaded, at: 7, effectiveRange: nil) == nil)
        #expect(storage.attribute(.foregroundColor, at: 2, effectiveRange: nil) as? NSColor == EditorPalette.standard.faded)
        #expect(storage.attribute(.foregroundColor, at: 6, effectiveRange: nil) as? NSColor != EditorPalette.standard.faded)
    }

    @Test(arguments: EditorFontFamily.allCases)
    func hiddenMarkupTakesNoRoomInEveryFont(_ family: EditorFontFamily) {
        let sheet = EditorStyleSheet(family: family, size: 18)
        // New York's private name doesn't resolve: a lookup by name fell back to full size.
        #expect(sheet.hiddenFont.pointSize < 1)
    }
}
