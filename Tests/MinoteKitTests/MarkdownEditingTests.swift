import Foundation
import Testing
@testable import MinoteKit

/// Applies an editing function to text where `|` marks the caret and
/// `[` `]` mark a selection, and renders the result the same way.
private func run(_ marked: String, _ operation: (NSString, NSRange) -> TextEdit?) -> String? {
    var text = marked
    let selection: NSRange
    if let caret = text.range(of: "|") {
        let location = text.utf16.distance(from: text.startIndex, to: caret.lowerBound)
        text.removeSubrange(caret)
        selection = NSRange(location: location, length: 0)
    } else if let open = text.range(of: "["), let close = text.range(of: "]", range: open.upperBound..<text.endIndex) {
        let start = text.utf16.distance(from: text.startIndex, to: open.lowerBound)
        let end = text.utf16.distance(from: text.startIndex, to: close.lowerBound) - 1
        text.removeSubrange(close)
        text.removeSubrange(open)
        selection = NSRange(location: start, length: end - start)
    } else {
        selection = NSRange(location: 0, length: 0)
    }
    guard let edit = operation(text as NSString, selection) else { return nil }
    let result = NSMutableString(string: edit.applied(to: text))
    if edit.selection.length == 0 {
        result.insert("|", at: edit.selection.location)
    } else {
        result.insert("]", at: NSMaxRange(edit.selection))
        result.insert("[", at: edit.selection.location)
    }
    return result as String
}

@Suite("Markdown editing")
struct MarkdownEditingTests {
    // MARK: Inline

    @Test func boldWrapsAndUnwrapsASelection() {
        #expect(run("make [this] bold") { MarkdownEditing.toggleInline("**", in: $0, selection: $1) } == "make **[this]** bold")
        #expect(run("make **[this]** bold") { MarkdownEditing.toggleInline("**", in: $0, selection: $1) } == "make [this] bold")
        #expect(run("make [**this**] bold") { MarkdownEditing.toggleInline("**", in: $0, selection: $1) } == "make [this] bold")
    }

    @Test func selectionWhitespaceStaysOutside() {
        #expect(run("a[ word ]b") { MarkdownEditing.toggleInline("_", in: $0, selection: $1) } == "a _[word]_ b")
    }

    @Test func caretInAWordWrapsTheWord() {
        #expect(run("an emp|hasis here") { MarkdownEditing.toggleInline("_", in: $0, selection: $1) } == "an _emp|hasis_ here")
    }

    @Test func caretWithNoWordInsertsAPair() {
        #expect(run("end |") { MarkdownEditing.toggleInline("**", in: $0, selection: $1) } == "end **|**")
        #expect(run("end **|**") { MarkdownEditing.toggleInline("**", in: $0, selection: $1) } == "end |")
    }

    @Test func multiLineSelectionWrapsEachLine() {
        #expect(run("[one\ntwo]") { MarkdownEditing.toggleInline("~~", in: $0, selection: $1) } == "~~[one~~\n~~two]~~")
    }

    @Test func links() {
        #expect(run("read [docs] now") { MarkdownEditing.insertLink(in: $0, selection: $1, url: nil) } == "read [docs](|) now")
        #expect(run("read [docs] now") { MarkdownEditing.insertLink(in: $0, selection: $1, url: "https://x.com") } == "read [docs](https://x.com)| now")
        #expect(run("[https://x.com]") { MarkdownEditing.insertLink(in: $0, selection: $1, url: nil) } == "[|](https://x.com)")
        #expect(run("|") { MarkdownEditing.insertLink(in: $0, selection: $1, url: nil) } == "[|]()")
    }

    // MARK: Lines

    @Test func headings() {
        #expect(run("Title|") { MarkdownEditing.toggleHeading(level: 2, in: $0, selection: $1) } == "## Title|")
        #expect(run("## Title|") { MarkdownEditing.toggleHeading(level: 2, in: $0, selection: $1) } == "Title|")
        #expect(run("### Ti|tle") { MarkdownEditing.toggleHeading(level: 1, in: $0, selection: $1) } == "# Ti|tle")
        #expect(run("# Title|") { MarkdownEditing.toggleHeading(level: 0, in: $0, selection: $1) } == "Title|")
    }

    @Test func bulletsAndNumbers() {
        #expect(run("[a\nb]") { MarkdownEditing.toggle(.bullet, in: $0, selection: $1) } == "[- a\n- b]")
        #expect(run("[- a\n- b]") { MarkdownEditing.toggle(.bullet, in: $0, selection: $1) } == "[a\nb]")
        #expect(run("[- a\n- b]") { MarkdownEditing.toggle(.numbered, in: $0, selection: $1) } == "[1. a\n2. b]")
        #expect(run("[a\n\nb]") { MarkdownEditing.toggle(.task, in: $0, selection: $1) } == "[- [ ] a\n\n- [ ] b]")
    }

    @Test func quotesStackOnLists() {
        #expect(run("- item|") { MarkdownEditing.toggle(.quote, in: $0, selection: $1) } == "> - item|")
        #expect(run("> - item|") { MarkdownEditing.toggle(.quote, in: $0, selection: $1) } == "- item|")
    }

    @Test func taskDone() {
        #expect(run("- [ ] milk|") { MarkdownEditing.toggleTaskDone(in: $0, selection: $1) } == "- [x] milk|")
        #expect(run("- [x] milk|") { MarkdownEditing.toggleTaskDone(in: $0, selection: $1) } == "- [ ] milk|")
        #expect(run("plain|") { MarkdownEditing.toggleTaskDone(in: $0, selection: $1) } == nil)
    }

    @Test func codeBlocks() {
        #expect(run("[let x = 1]") { MarkdownEditing.toggleCodeBlock(in: $0, selection: $1) } == "```\n[let x = 1]\n```")
        #expect(run("```\n[let x = 1]\n```") { MarkdownEditing.toggleCodeBlock(in: $0, selection: $1) } == "[let x = 1]")
        #expect(run("|") { MarkdownEditing.toggleCodeBlock(in: $0, selection: $1) } == "```\n|\n```")
    }

    @Test func horizontalRule() {
        #expect(run("text|") { MarkdownEditing.insertHorizontalRule(in: $0, selection: $1) } == "text\n\n---\n|")
        #expect(run("a\n|") { MarkdownEditing.insertHorizontalRule(in: $0, selection: $1) } == "a\n---|")
    }

    // MARK: Typing

    @Test func returnContinuesLists() {
        #expect(run("- one|") { MarkdownEditing.newline(in: $0, selection: $1) } == "- one\n- |")
        #expect(run("  * one|") { MarkdownEditing.newline(in: $0, selection: $1) } == "  * one\n  * |")
        #expect(run("9. nine|") { MarkdownEditing.newline(in: $0, selection: $1) } == "9. nine\n10. |")
        #expect(run("- [x] done|") { MarkdownEditing.newline(in: $0, selection: $1) } == "- [x] done\n- [ ] |")
        #expect(run("> quote|") { MarkdownEditing.newline(in: $0, selection: $1) } == "> quote\n> |")
        #expect(run("- spl|it") { MarkdownEditing.newline(in: $0, selection: $1) } == "- spl\n- |it")
    }

    @Test func returnOnAnEmptyItemEndsTheList() {
        #expect(run("- one\n- |") { MarkdownEditing.newline(in: $0, selection: $1) } == "- one\n|")
        #expect(run("1. a\n2. |") { MarkdownEditing.newline(in: $0, selection: $1) } == "1. a\n|")
    }

    @Test func returnOutsideListsIsDefault() {
        #expect(run("plain|") { MarkdownEditing.newline(in: $0, selection: $1) } == nil)
        #expect(run("|- item") { MarkdownEditing.newline(in: $0, selection: $1) } == nil)
    }

    @Test func tabIndentsListItems() {
        #expect(run("- item|") { MarkdownEditing.shiftLines(in: $0, selection: $1, outdent: false, listsOnly: true) } == "  - item|")
        #expect(run("  - item|") { MarkdownEditing.shiftLines(in: $0, selection: $1, outdent: true, listsOnly: true) } == "- item|")
        #expect(run("10. item|") { MarkdownEditing.shiftLines(in: $0, selection: $1, outdent: false, listsOnly: true) } == "    10. item|")
        #expect(run("plain|") { MarkdownEditing.shiftLines(in: $0, selection: $1, outdent: false, listsOnly: true) } == nil)
        #expect(run("plain|") { MarkdownEditing.shiftLines(in: $0, selection: $1, outdent: false, listsOnly: false) } == "    plain|")
    }
}
