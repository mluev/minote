import Foundation

/// A heading as the outline lists it.
public struct OutlineHeading: Equatable, Identifiable, Sendable {
    /// Stays the same while the note is unchanged around it: the title and
    /// how many earlier headings share it.
    public var id: String
    /// 1–6, the number of `#`.
    public var level: Int
    /// The text as the rendered page shows it: no hashes, no inline markup.
    public var title: String
    /// Where the heading's line starts (UTF-16 offset).
    public var location: Int
    /// Where its text starts, after the hashes.
    public var contentLocation: Int

    public init(id: String, level: Int, title: String, location: Int, contentLocation: Int) {
        self.id = id
        self.level = level
        self.title = title
        self.location = location
        self.contentLocation = contentLocation
    }
}

/// The headings of a note, for the outline beside the page: what the
/// rendered view draws as headings (ATX headings outside code blocks).
public enum MarkdownOutline {
    /// Every heading with a visible title, in order. Linear in the text's
    /// length: only lines that can be headings are lexed.
    public static func headings(in text: NSString, fences: FenceIndex) -> [OutlineHeading] {
        var headings: [OutlineHeading] = []
        var occurrences: [String: Int] = [:]
        text.forEachLine(in: NSRange(location: 0, length: text.length)) { start, contentsEnd, _, _ in
            guard mayBeHeading(text, from: start, to: contentsEnd), !fences.contains(start),
                  let heading = heading(text, from: start, to: contentsEnd) else { return }
            let occurrence = occurrences[heading.title, default: 0]
            occurrences[heading.title] = occurrence + 1
            headings.append(OutlineHeading(id: "\(heading.title)\u{1F}\(occurrence)", level: heading.level, title: heading.title,
                                           location: start, contentLocation: start + heading.contentStart))
        }
        return headings
    }

    /// The heading whose section contains `offset`: the last one starting at
    /// or before it. Nil before the first heading.
    public static func section(at offset: Int, in headings: [OutlineHeading]) -> Int? {
        var low = 0, high = headings.count
        while low < high {
            let mid = (low + high) / 2
            if headings[mid].location <= offset { low = mid + 1 } else { high = mid }
        }
        return low == 0 ? nil : low - 1
    }

    /// Cheap pre-check, the lexer's rule for block markup: at most three
    /// columns of indentation (a tab counts to the next multiple of four), then `#`.
    private static func mayBeHeading(_ text: NSString, from start: Int, to end: Int) -> Bool {
        var columns = 0
        var i = start
        while i < end {
            switch text.character(at: i) {
            case 0x20: columns += 1
            case 0x09: columns += 4 - columns % 4
            case 0x23: return columns <= 3
            default: return false
            }
            guard columns <= 3 else { return false }
            i += 1
        }
        return false
    }

    private static func heading(_ text: NSString, from start: Int, to end: Int) -> (level: Int, title: String, contentStart: Int)? {
        let chars = text.characters(in: start..<end)
        let line = MarkdownLexer.lex(chars, insideFence: false)
        guard case .heading(let level) = line.kind else { return nil }
        // What the page shows: everything after the hashes but the markup
        // (hashes, emphasis delimiters, link brackets and destinations).
        var hidden = [Bool](repeating: false, count: chars.count)
        for span in line.spans where span.style == .syntax || span.style == .destination {
            for i in span.range where i < hidden.count { hidden[i] = true }
        }
        var visible: [UInt16] = []
        visible.reserveCapacity(chars.count - line.contentStart)
        for i in line.contentStart..<chars.count where !hidden[i] { visible.append(chars[i]) }
        let title = String(decoding: visible, as: UTF16.self)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard !title.isEmpty else { return nil }
        return (level, title, line.contentStart)
    }
}
