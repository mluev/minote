import AppKit
import MinoteKit
import Testing
@testable import MinoteEditor

@MainActor
@Suite("Markdown styler")
struct MarkdownStylerTests {
    private func styled(_ text: String, reveal: NSRange? = nil, showsSyntax: Bool = false, focus: NSRange? = nil) -> (NSTextStorage, EditorStyleSheet) {
        let sheet = EditorStyleSheet(family: .sfMono, size: 18)
        let styler = MarkdownStyler(styleSheet: sheet)
        styler.revealRange = reveal
        styler.showsSyntax = showsSyntax
        styler.focusRange = focus
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

    @Test func onlyTheFormattingUnderTheCaretShowsItsMarkup() {
        let text = "**one** plain _two_\n**three**"
        let (storage, _) = styled(text, reveal: NSRange(location: 3, length: 0))  // inside "one"
        #expect(!isHidden(storage, at: 0))                               // ** around "one": shown
        #expect(storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == EditorTheme.syntax)
        #expect(!isHidden(storage, at: 5))
        #expect(isHidden(storage, at: 14))                               // _ around "two": hidden
        #expect(isHidden(storage, at: 20))                               // other line: hidden

        let (plain, _) = styled(text, reveal: NSRange(location: 10, length: 0))  // inside "plain"
        #expect(isHidden(plain, at: 0) && isHidden(plain, at: 14))
    }

    @Test func headingMarkersNeverShowEvenUnderTheCaret() {
        let (storage, sheet) = styled("# Title", reveal: NSRange(location: 4, length: 0))
        #expect(isHidden(storage, at: 0))
        #expect(font(storage, at: 3)?.pointSize == sheet.heading(level: 1).font.pointSize)
    }

    @Test func inlineMarkupInAHeadingRevealsOnlyAroundTheCaret() {
        let (storage, _) = styled("## A **b** c", reveal: NSRange(location: 6, length: 0))
        #expect(isHidden(storage, at: 0))                 // ## stays hidden
        #expect(!isHidden(storage, at: 5))                // ** around b shows
        let (away, _) = styled("## A **b** c", reveal: NSRange(location: 3, length: 0))
        #expect(isHidden(away, at: 5))
    }

    @Test func caretAfterTheLineBreakBelongsToTheNextLine() {
        let (storage, _) = styled("**one**\n", reveal: NSRange(location: 8, length: 0))
        #expect(isHidden(storage, at: 0))
    }

    @Test func sourceViewNeverHides() {
        let (storage, _) = styled("# Title **x**", showsSyntax: true)
        #expect(!isHidden(storage, at: 0))
        #expect(font(storage, at: 2)?.pointSize == 18)
    }

    @Test func headingsAreLargerWithTheirMarkersHidden() {
        let (storage, sheet) = styled("# Title\n## Sub")
        #expect(isHidden(storage, at: 0))
        #expect(font(storage, at: 2)?.pointSize == sheet.heading(level: 1).font.pointSize)
        #expect((font(storage, at: 2)?.pointSize ?? 0) > (font(storage, at: 11)?.pointSize ?? 0))
        #expect((font(storage, at: 11)?.pointSize ?? 0) > 18)
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

    @Test func bulletsAreDrawnInPlaceOfTheirMarker() {
        let (storage, _) = styled("- item\n  - nested", reveal: NSRange(location: 3, length: 0))
        #expect(mark(storage, at: 0) == .bullet(level: 0))
        #expect(color(storage, at: 0) == .clear)
        #expect(!isHidden(storage, at: 0))                // keeps its width: the text doesn't move
        #expect(mark(storage, at: 9) == .bullet(level: 1))
        #expect(mark(storage, at: 2) == nil)
    }

    @Test func numbersStayAsText() {
        let (storage, _) = styled("1. one")
        #expect(color(storage, at: 0) == EditorTheme.listMarker)
        #expect(mark(storage, at: 0) == nil)
    }

    @Test func taskBoxesAreDrawnAndTheirBracketsHidden() {
        let (storage, _) = styled("- [ ] open\n- [x] done", reveal: NSRange(location: 7, length: 0))
        #expect(mark(storage, at: 0) == .checkbox(done: false))
        #expect(isHidden(storage, at: 2) && isHidden(storage, at: 4) && isHidden(storage, at: 5))
        #expect(mark(storage, at: 11) == .checkbox(done: true))
        #expect(storage.attribute(.strikethroughStyle, at: 17, effectiveRange: nil) != nil)
        #expect(color(storage, at: 17) == EditorTheme.doneTask)
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

    @Test func tablePipesBecomeLines() {
        let (storage, _) = styled("| a | b |\n|---|---|\n| 1 | 2 |")
        #expect(mark(storage, at: 0) == .tablePipe)
        #expect(color(storage, at: 0) == .clear)
        #expect(font(storage, at: 2)?.fontDescriptor.symbolicTraits.contains(.bold) == true)  // header row
        #expect(mark(storage, at: 11) == .tableRule)
        #expect(font(storage, at: 22)?.fontDescriptor.symbolicTraits.contains(.bold) != true)
    }

    @Test func linksCarryTheirTarget() {
        let (storage, _) = styled("see [site](https://x.com) and www.y.org")
        #expect(LinkAttribute.decode(storage.attribute(.minoteLink, at: 5, effectiveRange: nil)) == .url("https://x.com"))
        #expect(LinkAttribute.decode(storage.attribute(.minoteLink, at: 4, effectiveRange: nil)) == .url("https://x.com"))
        #expect(LinkAttribute.decode(storage.attribute(.minoteLink, at: 32, effectiveRange: nil)) == .url("www.y.org"))
        #expect(storage.attribute(.minoteLink, at: 1, effectiveRange: nil) == nil)
    }

    @Test func sourceViewDrawsNothing() {
        let (storage, _) = styled("- [ ] a\n> q", showsSyntax: true)
        #expect(mark(storage, at: 0) == nil)
        #expect(block(storage, at: 8) == nil)
        #expect(color(storage, at: 0) == EditorTheme.syntax)
    }

    @Test func linksShowOnlyTheirText() {
        let (storage, _) = styled("see [site](https://x.com)")
        #expect(isHidden(storage, at: 4))   // [
        #expect(!isHidden(storage, at: 5))  // s
        #expect(storage.attribute(.underlineStyle, at: 5, effectiveRange: nil) != nil)
        #expect(isHidden(storage, at: 12))  // inside the destination
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
        #expect(storage.attribute(.foregroundColor, at: 2, effectiveRange: nil) as? NSColor == EditorTheme.faded)
        #expect(storage.attribute(.foregroundColor, at: 6, effectiveRange: nil) as? NSColor != EditorTheme.faded)
    }
}
