import Foundation
import Testing
@testable import MinoteKit

private func outline(_ text: String) -> [OutlineHeading] {
    let string = text as NSString
    return MarkdownOutline.headings(in: string, fences: FenceIndex(text: string))
}

private func titles(_ text: String) -> [String] {
    outline(text).map(\.title)
}

@Suite("Markdown outline")
struct MarkdownOutlineTests {
    @Test func listsHeadingsWithTheirLevels() {
        let headings = outline("# One\ntext\n## Two\n###### Six\n### Three")
        #expect(headings.map(\.title) == ["One", "Two", "Six", "Three"])
        #expect(headings.map(\.level) == [1, 2, 6, 3])
        #expect(headings.map(\.location) == [0, 11, 18, 29])
        #expect(headings.map(\.contentLocation) == [2, 14, 25, 33])
    }

    @Test func onlyWhatThePageDrawsAsAHeading() {
        #expect(titles("#tag\n####### seven\n    # indented code\n> # quoted\n- # in a list\nTitle\n===") == [])
        #expect(titles("   # three spaces\n\t# tab") == ["three spaces"])
        #expect(titles("#\n##   \n# ##") == [])
    }

    @Test func skipsHeadingsInsideCodeBlocks() {
        #expect(titles("# Before\n```\n# comment\n```\n# After") == ["Before", "After"])
        #expect(titles("~~~sh\n# comment\n~~~\n## Tilde") == ["Tilde"])
        #expect(titles("# Before\n```\n# never closed") == ["Before"])
        // A shorter fence doesn't close a longer one.
        #expect(titles("````\n```\n# inside\n````\n# out") == ["out"])
    }

    @Test func titlesAreTheRenderedText() {
        #expect(titles("## Closing ##") == ["Closing"])
        #expect(titles("# C#") == ["C#"])
        #expect(titles("## **Bold** [link](https://example.com) `code`") == ["Bold link code"])
        #expect(titles("# A [ref][label] and ![image](a.png)") == ["A ref and image"])
        #expect(titles("#   spaced    out   ") == ["spaced out"])
        #expect(titles("# \\*escaped\\*") == ["*escaped*"])
    }

    @Test func duplicateTitlesKeepDistinctStableIDs() {
        let first = outline("# Notes\n## Notes\n# Other\n# Notes")
        #expect(Set(first.map(\.id)).count == 4)
        // Adding text elsewhere keeps the ids.
        let second = outline("intro\n\n# Notes\n## Notes\nmore\n# Other\n# Notes")
        #expect(second.map(\.id) == first.map(\.id))
    }

    @Test func offsetsAreUTF16() {
        let text = "😀 emoji\r\n# Title\r\n## Next"
        let headings = outline(text)
        #expect(headings.map(\.title) == ["Title", "Next"])
        let string = text as NSString
        #expect(string.substring(from: headings[0].contentLocation).hasPrefix("Title"))
        #expect(string.substring(from: headings[1].location).hasPrefix("## Next"))
    }

    @Test func sectionIsTheLastHeadingAtOrBefore() {
        let headings = outline("intro\n# A\ntext\n# B\ntext")
        #expect(MarkdownOutline.section(at: 0, in: headings) == nil)
        #expect(MarkdownOutline.section(at: headings[0].location, in: headings) == 0)
        #expect(MarkdownOutline.section(at: headings[1].location - 1, in: headings) == 0)
        #expect(MarkdownOutline.section(at: headings[1].location, in: headings) == 1)
        #expect(MarkdownOutline.section(at: 10_000, in: headings) == 1)
        #expect(MarkdownOutline.section(at: 5, in: []) == nil)
    }

    @Test func longNotesStayFast() {
        var text = ""
        for i in 0..<10_000 {
            text += "## Section \(i)\nSome **text** with a [link](x) and `code`.\n\n```\n# not a heading\n```\n"
        }
        let string = text as NSString
        let fences = FenceIndex(text: string)
        let clock = ContinuousClock()
        var headings: [OutlineHeading] = []
        let elapsed = clock.measure {
            headings = MarkdownOutline.headings(in: string, fences: fences)
        }
        #expect(headings.count == 10_000)
        #expect(elapsed < .seconds(1))
    }
}
