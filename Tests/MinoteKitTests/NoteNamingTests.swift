import Foundation
import Testing
@testable import MinoteKit

@Suite("Note naming")
struct NoteNamingTests {
    @Test("Title is the first non-blank line without Markdown markers", arguments: [
        ("Hello world", "Hello world"),
        ("\n\n  # Heading  \nbody", "Heading"),
        ("## Closing hashes ##", "Closing hashes"),
        ("# C#", "C#"),
        ("#hashtag is not a heading", "#hashtag is not a heading"),
        ("> > quoted", "quoted"),
        ("- list item", "list item"),
        ("* star", "star"),
        ("   \n\t\n", ""),
        ("", ""),
        ("Привет, мир\nвторая строка", "Привет, мир"),
    ])
    func title(text: String, expected: String) {
        #expect(NoteNaming.title(of: text) == expected)
    }

    @Test func excerptSkipsTitleAndCollapsesWhitespace() {
        let text = "# Title\n\nFirst   paragraph\nwraps here.\n\n## Section\nMore."
        #expect(NoteNaming.excerpt(of: text) == "First paragraph wraps here. Section More.")
        #expect(NoteNaming.excerpt(of: text, skippingTitleLine: false).hasPrefix("Title First paragraph"))
        #expect(NoteNaming.excerpt(of: "Only a title") == "")
    }

    @Test func titlesAndExcerptsHideMarkup() {
        #expect(NoteNaming.title(of: "# **Big** idea") == "Big idea")
        #expect(NoteNaming.title(of: "- [ ] Task title") == "Task title")
        let text = "Title\nWriting **bold**, _italic_ and a [link](https://x.com).\n```\n---"
        #expect(NoteNaming.excerpt(of: text) == "Writing bold, italic and a link.")
    }

    @Test func excerptIsLimited() {
        let text = "Title\n" + String(repeating: "word ", count: 200)
        #expect(NoteNaming.excerpt(of: text).count <= 240)
    }

    @Test("File stems are safe for the file system", arguments: [
        ("Hello: World/2", "Hello- World-2"),
        ("...hidden", "hidden"),
        ("Ends with dots...", "Ends with dots"),
        ("  lots   of\tspace  ", "lots of space"),
        ("", "Untitled"),
        ("...", "Untitled"),
        ("Café", "Café"),
        ("Заметка 🚀", "Заметка 🚀"),
    ])
    func fileStem(title: String, expected: String) {
        #expect(NoteNaming.fileStem(forTitle: title) == expected)
    }

    @Test func longTitlesAreCutOnAWordBoundary() {
        let title = String(repeating: "lorem ipsum ", count: 20)
        let stem = NoteNaming.fileStem(forTitle: title)
        #expect(stem.count <= NoteNaming.maxStemLength)
        #expect(stem.hasSuffix("ipsum") || stem.hasSuffix("lorem"))
    }

    @Test func stemsFitTheByteBudget() {
        let stem = NoteNaming.fileStem(forTitle: String(repeating: "👩‍👩‍👧‍👦", count: 80))
        #expect(stem.utf8.count <= NoteNaming.maxStemBytes)
        #expect(!stem.isEmpty)
    }

    @Test func uniqueStemAddsCounters() {
        let taken: Set<String> = ["Note", "Note 2"]
        #expect(NoteNaming.uniqueStem(base: "Note") { taken.contains($0) } == "Note 3")
        #expect(NoteNaming.uniqueStem(base: "Free") { taken.contains($0) } == "Free")
    }

    @Test func stemsMatchIgnoresCaseAndNormalization() {
        #expect(NoteNaming.stemsMatch("hello", "HELLO"))
        #expect(NoteNaming.stemsMatch("Cafe\u{301}", "Café"))
        #expect(!NoteNaming.stemsMatch("hello", "hello 2"))
    }

    @Test func sidebarDates() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        let locale = Locale(identifier: "en_US")
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 5, hour: 20)))
        let yesterday = try #require(calendar.date(byAdding: .day, value: -1, to: now))
        let threeDaysAgo = try #require(calendar.date(byAdding: .day, value: -3, to: now))
        let lastYear = try #require(calendar.date(from: DateComponents(year: 2025, month: 3, day: 9)))

        #expect(NoteDateText.string(for: yesterday, now: now, calendar: calendar, locale: locale) == "Yesterday")
        #expect(NoteDateText.string(for: threeDaysAgo, now: now, calendar: calendar, locale: locale) == "Friday")
        #expect(NoteDateText.string(for: lastYear, now: now, calendar: calendar, locale: locale).contains("2025"))
    }
}
