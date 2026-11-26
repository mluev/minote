import Foundation

/// Where a query matched in a piece of text, and how well.
public struct FuzzyMatch: Equatable, Sendable {
    /// Higher is better.
    public let score: Int
    /// The matched characters, in the text searched.
    public let ranges: [Range<String.Index>]

    public init(score: Int, ranges: [Range<String.Index>]) {
        self.score = score
        self.ranges = ranges
    }
}

/// Matching as a launcher does it: the query's letters in order, anywhere in
/// the text, scoring a whole-word or start-of-word hit above letters
/// scattered across it. Case and accents don't matter.
public enum Fuzzy {
    public static func match(_ query: String, in text: String) -> FuzzyMatch? {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty, !text.isEmpty else { return nil }

        // The query as it's written, somewhere in the text: the best kind of hit.
        if let range = text.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) {
            let offset = text.distance(from: text.startIndex, to: range.lowerBound)
            var score = 10_000 - min(offset, 500) * 4
            if range.lowerBound == text.startIndex { score += 3_000 } else if isWordStart(range.lowerBound, in: text) { score += 1_500 }
            if range.upperBound == text.endIndex { score += 200 }
            return FuzzyMatch(score: score, ranges: [range])
        }

        // Otherwise the letters in order, preferring the starts of words.
        let wanted = needle.filter { !$0.isWhitespace }.map(fold)
        var ranges: [Range<String.Index>] = []
        var score = 0
        var index = text.startIndex
        var previous: String.Index?
        for letter in wanted {
            // The next occurrence at the start of a word, else the next at all.
            var found: String.Index?
            var fallback: String.Index?
            var cursor = index
            while cursor < text.endIndex {
                if fold(text[cursor]) == letter {
                    if fallback == nil { fallback = cursor }
                    if isWordStart(cursor, in: text) || cursor == previous.map({ text.index(after: $0) }) {
                        found = cursor
                        break
                    }
                }
                cursor = text.index(after: cursor)
            }
            guard let at = found ?? fallback else { return nil }
            let next = text.index(after: at)
            if let previous, text.index(after: previous) == at, let last = ranges.indices.last {
                ranges[last] = ranges[last].lowerBound..<next
                score += 60
            } else {
                ranges.append(at..<next)
                score += isWordStart(at, in: text) ? 80 : 10
            }
            previous = at
            index = next
        }
        // Fewer, longer runs read as the intended word.
        score -= ranges.count * 15
        return FuzzyMatch(score: max(score, 1), ranges: ranges)
    }

    private static func fold(_ character: Character) -> String {
        String(character).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    private static func isWordStart(_ index: String.Index, in text: String) -> Bool {
        guard index > text.startIndex else { return true }
        let before = text[text.index(before: index)]
        let here = text[index]
        if !(before.isLetter || before.isNumber) { return true }
        // camelCase and digits after letters.
        return before.isLowercase && here.isUppercase || before.isLetter && here.isNumber
    }
}

/// A note found by a search: by its title, or by a line of its text.
@MainActor
public struct NoteHit: Identifiable {
    public let note: Note
    /// Where the query matched the title, if it did.
    public let titleMatch: FuzzyMatch?
    /// The line of the text that matched, shortened around the match.
    public let snippet: String?
    public let snippetMatch: Range<String.Index>?
    public let score: Int

    public nonisolated var id: Note.ID { noteID }
    private nonisolated let noteID: Note.ID

    init(note: Note, titleMatch: FuzzyMatch?, snippet: String?, snippetMatch: Range<String.Index>?, score: Int) {
        self.note = note
        self.titleMatch = titleMatch
        self.snippet = snippet
        self.snippetMatch = snippetMatch
        self.score = score
        noteID = note.id
    }
}

/// Searching the library from the search palette.
@MainActor
public enum LibrarySearch {
    /// Notes whose title matches, best first, then notes whose text has the
    /// query in it. A locked note while sealed matches by title only. With no
    /// query: the most recently updated notes.
    public static func notes(_ query: String, in notes: [Note], limit: Int = 30) -> [NoteHit] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidates = notes.filter { !$0.isBlankDraft }
        guard !query.isEmpty else {
            return candidates.sorted { $0.modified > $1.modified }.prefix(limit)
                .map { NoteHit(note: $0, titleMatch: nil, snippet: nil, snippetMatch: nil, score: 0) }
        }
        var hits: [NoteHit] = []
        for note in candidates {
            let title = Fuzzy.match(query, in: note.displayTitle)
            let line = note.text.flatMap { snippet(for: query, in: $0, skippingTitle: true) }
            // Letters scattered through a title aren't worth showing next to a real hit in the text.
            let strongTitle = title.map { $0.score >= 1_000 || line == nil } ?? false
            guard strongTitle || line != nil else { continue }
            let score = (strongTitle ? 20_000 + (title?.score ?? 0) : 0) + (line != nil ? 1_000 : 0)
            hits.append(NoteHit(note: note, titleMatch: strongTitle ? title : nil, snippet: line?.text, snippetMatch: line?.match, score: score))
        }
        hits.sort { $0.score != $1.score ? $0.score > $1.score : $0.note.modified > $1.note.modified }
        return Array(hits.prefix(limit))
    }

    /// Folders whose name (or path) matches, best first.
    public static func folders(_ query: String, in folders: [FolderPath], limit: Int = 8) -> [(folder: FolderPath, match: FuzzyMatch)] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        var found: [(folder: FolderPath, match: FuzzyMatch)] = []
        for folder in folders {
            if let match = Fuzzy.match(query, in: folder.name ?? "") { found.append((folder, match)) }
        }
        found.sort { a, b in
            if a.match.score != b.match.score { return a.match.score > b.match.score }
            return a.folder.depth < b.folder.depth
        }
        return Array(found.prefix(limit))
    }

    /// The line of `text` holding `query`, cut to about `width` characters
    /// around it, with its Markdown markers stripped.
    public static func snippet(for query: String, in text: String, skippingTitle: Bool = false, width: Int = 90)
        -> (text: String, match: Range<String.Index>)? {
        var found: (String, Range<String.Index>)?
        var isFirst = true
        text.enumerateLines { line, stop in
            defer { isFirst = false }
            if skippingTitle && isFirst && !line.trimmingCharacters(in: .whitespaces).isEmpty { return }
            let stripped = String(NoteNaming.stripLineMarkers(Substring(line))).trimmingCharacters(in: .whitespaces)
            guard let range = stripped.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) else { return }
            found = (stripped, range)
            stop = true
        }
        guard let (line, range) = found else { return nil }
        guard line.count > width else { return (line, range) }

        // Keep the match in view, with some words before it.
        let before = line.distance(from: line.startIndex, to: range.lowerBound)
        let start = max(0, min(before - width / 3, line.count - width))
        let lower = line.index(line.startIndex, offsetBy: start)
        let upper = line.index(lower, offsetBy: width, limitedBy: line.endIndex) ?? line.endIndex
        let prefix = start > 0 ? "…" : ""
        let suffix = upper < line.endIndex ? "…" : ""
        let cut = prefix + line[lower..<upper] + suffix
        guard let match = cut.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) else { return (cut, cut.startIndex..<cut.startIndex) }
        return (cut, match)
    }
}
