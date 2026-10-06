import Foundation

/// How a piece of a line should look.
public enum MarkdownStyle: UInt8, Sendable {
    /// Markup characters: `#`, `**`, `>`, brackets, fences… shown dimmed.
    case syntax
    case strong
    case emphasis
    case strikethrough
    case code
    case link
    /// A bare or autolinked URL: part of the text.
    case url
    /// Where a `[text](…)` link or image points: markup, hidden in rendered view.
    case destination
}

/// A styled range inside one line, in UTF-16 offsets (the unit of NSString).
public struct MarkdownSpan: Equatable, Sendable {
    public var range: Range<Int>
    public var style: MarkdownStyle

    public init(_ range: Range<Int>, _ style: MarkdownStyle) {
        self.range = range
        self.style = style
    }
}

/// The block role of a line.
public enum MarkdownLineKind: Equatable, Sendable {
    case blank
    case paragraph
    case heading(level: Int)
    case listItem(ordered: Bool)
    case taskItem(done: Bool)
    case blockquote
    /// An opening or closing ``` / ~~~ line.
    case fence
    /// A line inside a fenced code block.
    case code
    case thematicBreak
    case table
    case linkDefinition
}

/// A list item's leading markup.
public struct MarkdownListMarker: Equatable, Sendable {
    /// The bullet (`-`, `*`, `+`) or the number with its delimiter (`12.`).
    public var marker: Range<Int>
    public var ordered: Bool
    /// The task box, `[ ]` or `[x]`.
    public var taskBox: Range<Int>?
    public var isDone: Bool
    /// Columns of indentation before the marker (tabs count as four).
    public var indentColumns: Int
}

/// Where a link points, as written.
public enum MarkdownLinkTarget: Equatable, Sendable {
    /// An inline destination, autolink, bare URL or definition URL.
    case url(String)
    /// `[text][label]` (or `[text][]`, whose label is the text).
    case reference(String)
    /// `[^id]`.
    case footnote(String)
}

/// A link on one line: all of its markup and where it points.
public struct MarkdownLink: Equatable, Sendable {
    public var range: Range<Int>
    public var target: MarkdownLinkTarget

    public init(_ range: Range<Int>, _ target: MarkdownLinkTarget) {
        self.range = range
        self.target = target
    }
}

/// The result of lexing one line.
public struct MarkdownLine: Equatable, Sendable {
    public var kind: MarkdownLineKind
    /// Where the line's text starts after block markup (heading hashes, list
    /// bullet, quote marker). Wrapped lines hang at this offset.
    public var contentStart: Int
    public var spans: [MarkdownSpan]
    /// The list marker, for list and task items (also inside a quote).
    public var list: MarkdownListMarker? = nil
    /// How many `>` a quote line starts with.
    public var quoteDepth: Int = 0
    public var links: [MarkdownLink] = []
}

/// A fast, line-at-a-time Markdown lexer for styling text while it's typed.
/// It follows CommonMark and GitHub Flavored Markdown closely for everything a
/// writer sees (emphasis rules, code spans, links, lists, tasks, quotes,
/// fences, tables), without building a document tree.
public enum MarkdownLexer {
    /// Lexes a line given as UTF-16 code units (no line terminator).
    public static func lex(_ chars: [UInt16], insideFence: Bool) -> MarkdownLine {
        var lexer = LineLexer(chars: chars)
        return lexer.run(insideFence: insideFence)
    }

    /// Convenience for strings.
    public static func lex(_ line: String, insideFence: Bool = false) -> MarkdownLine {
        lex(Array(line.utf16), insideFence: insideFence)
    }

    /// Whether a line opens or closes a code fence: up to three spaces, then
    /// three or more backticks or tildes. Returns the fence character and length.
    public static func fence(in chars: [UInt16]) -> (char: UInt16, length: Int, isBare: Bool)? {
        var i = 0
        while i < chars.count, chars[i] == .space, i < 3 { i += 1 }
        guard i < chars.count, chars[i] == .backtick || chars[i] == .tilde else { return nil }
        let char = chars[i]
        var j = i
        while j < chars.count, chars[j] == char { j += 1 }
        let length = j - i
        guard length >= 3 else { return nil }
        let rest = chars[j...]
        // A backtick fence's info string can't contain backticks.
        if char == .backtick, rest.contains(.backtick) { return nil }
        let isBare = rest.allSatisfy { $0 == .space || $0 == .tab }
        return (char, length, isBare)
    }
}

// MARK: - Line lexer

private struct LineLexer {
    let chars: [UInt16]
    var spans: [MarkdownSpan] = []
    var links: [MarkdownLink] = []
    /// Characters already claimed by code spans, escapes, URLs and link markup.
    var protected: [Bool]

    init(chars: [UInt16]) {
        self.chars = chars
        protected = Array(repeating: false, count: chars.count)
    }

    var count: Int { chars.count }

    mutating func run(insideFence: Bool) -> MarkdownLine {
        let indentEnd = leadingWhitespaceEnd(from: 0)

        if insideFence {
            if MarkdownLexer.fence(in: chars) != nil {
                return line(.fence, contentStart: indentEnd, syntax: 0..<count)
            }
            return MarkdownLine(kind: .code, contentStart: 0, spans: [])
        }
        if indentEnd == count {
            return MarkdownLine(kind: .blank, contentStart: count, spans: [])
        }

        let columns = indentColumns(upTo: indentEnd)
        if columns <= 3 {
            if MarkdownLexer.fence(in: chars) != nil {
                return line(.fence, contentStart: indentEnd, syntax: 0..<count)
            }
            if let heading = heading(at: indentEnd) { return heading }
            if isThematicBreak(from: indentEnd) {
                return line(.thematicBreak, contentStart: indentEnd, syntax: indentEnd..<count)
            }
            if chars[indentEnd] == .greaterThan { return blockquote(at: indentEnd) }
            if let definition = linkDefinition(at: indentEnd) { return definition }
            if chars[indentEnd] == .pipe { return tableRow(at: indentEnd) }
        }
        if let item = listItem(at: indentEnd) { return item }

        parseInline(indentEnd..<count)
        return MarkdownLine(kind: .paragraph, contentStart: indentEnd, spans: spans, links: links)
    }

    private func line(_ kind: MarkdownLineKind, contentStart: Int, syntax: Range<Int>) -> MarkdownLine {
        MarkdownLine(kind: kind, contentStart: contentStart, spans: syntax.isEmpty ? [] : [MarkdownSpan(syntax, .syntax)])
    }

    // MARK: Blocks

    private mutating func heading(at start: Int) -> MarkdownLine? {
        var i = start
        while i < count, chars[i] == .hash { i += 1 }
        let level = i - start
        guard (1...6).contains(level), i == count || chars[i].isWhitespace else { return nil }
        let contentStart = leadingWhitespaceEnd(from: i)

        // Optional closing sequence: whitespace, #'s, whitespace to the end.
        var end = count
        while end > contentStart, chars[end - 1].isWhitespace { end -= 1 }
        var closing = end
        while closing > contentStart, chars[closing - 1] == .hash { closing -= 1 }
        if closing < end, closing == contentStart || chars[closing - 1].isWhitespace {
            var contentEnd = closing
            while contentEnd > contentStart, chars[contentEnd - 1].isWhitespace { contentEnd -= 1 }
            spans.append(MarkdownSpan(closing..<end, .syntax))
            end = contentEnd
        }

        spans.insert(MarkdownSpan(start..<contentStart, .syntax), at: 0)
        parseInline(contentStart..<end)
        return MarkdownLine(kind: .heading(level: level), contentStart: contentStart, spans: spans, links: links)
    }

    private func isThematicBreak(from start: Int) -> Bool {
        let marker = chars[start]
        guard marker == .hyphen || marker == .asterisk || marker == .underscore else { return false }
        var markers = 0
        for c in chars[start...] {
            if c == marker {
                markers += 1
            } else if !c.isWhitespace {
                return false
            }
        }
        return markers >= 3
    }

    private mutating func blockquote(at start: Int) -> MarkdownLine {
        var i = start
        var markerEnd = start
        var depth = 0
        while i < count, chars[i] == .greaterThan {
            depth += 1
            i += 1
            if i < count, chars[i] == .space || chars[i] == .tab { i += 1 }
            markerEnd = i
            i = leadingWhitespaceEnd(from: i)
            if i < count, chars[i] != .greaterThan { break }
        }
        spans.append(MarkdownSpan(start..<markerEnd, .syntax))

        // A list inside the quote: "> - item" hangs after the bullet.
        if let marker = listMarker(at: i) {
            spans.append(MarkdownSpan(i..<marker.end, .syntax))
            parseInline(marker.end..<count)
            return MarkdownLine(kind: .blockquote, contentStart: marker.end, spans: spans,
                                list: marker.info(indentColumns: 0), quoteDepth: depth, links: links)
        }
        parseInline(i..<count)
        return MarkdownLine(kind: .blockquote, contentStart: markerEnd, spans: spans, quoteDepth: depth, links: links)
    }

    private mutating func listItem(at start: Int) -> MarkdownLine? {
        guard let marker = listMarker(at: start) else { return nil }
        spans.append(MarkdownSpan(start..<marker.end, .syntax))
        let info = marker.info(indentColumns: indentColumns(upTo: start))
        if let done = marker.task, done {
            parseInline(marker.end..<count)
            spans.append(MarkdownSpan(marker.end..<count, .strikethrough))
            return MarkdownLine(kind: .taskItem(done: true), contentStart: marker.end, spans: spans, list: info, links: links)
        }
        parseInline(marker.end..<count)
        let kind: MarkdownLineKind = marker.task != nil ? .taskItem(done: false) : .listItem(ordered: marker.ordered)
        return MarkdownLine(kind: kind, contentStart: marker.end, spans: spans, list: info, links: links)
    }

    private struct ListMarkerScan {
        var markerRange: Range<Int>
        var end: Int
        var ordered: Bool
        var task: Bool?
        var box: Range<Int>?

        func info(indentColumns: Int) -> MarkdownListMarker {
            MarkdownListMarker(marker: markerRange, ordered: ordered, taskBox: box, isDone: task == true, indentColumns: indentColumns)
        }
    }

    /// `-`, `*`, `+` or `1.` / `1)` followed by a space (or the end of the
    /// line), with an optional `[ ]` / `[x]` task box.
    private func listMarker(at start: Int) -> ListMarkerScan? {
        guard start < count else { return nil }
        var i = start
        let ordered: Bool
        if chars[i] == .hyphen || chars[i] == .asterisk || chars[i] == .plus {
            i += 1
            ordered = false
        } else {
            while i < count, chars[i].isASCIIDigit, i - start < 9 { i += 1 }
            guard i > start, i < count, chars[i] == .period || chars[i] == .closeParen else { return nil }
            i += 1
            ordered = true
        }
        guard i == count || chars[i] == .space || chars[i] == .tab else { return nil }
        let markerRange = start..<i
        i = leadingWhitespaceEnd(from: i)

        var task: Bool?
        var box: Range<Int>?
        if i + 3 <= count, chars[i] == .openBracket, chars[i + 2] == .closeBracket,
           i + 3 == count || chars[i + 3] == .space || chars[i + 3] == .tab {
            let mark = chars[i + 1]
            if mark == .space {
                task = false
            } else if mark == .lowercaseX || mark == .uppercaseX {
                task = true
            }
            if task != nil {
                box = i..<i + 3
                i = leadingWhitespaceEnd(from: i + 3)
            }
        }
        return ListMarkerScan(markerRange: markerRange, end: i, ordered: ordered, task: task, box: box)
    }

    private mutating func linkDefinition(at start: Int) -> MarkdownLine? {
        guard chars[start] == .openBracket else { return nil }
        var i = start + 1
        while i < count, chars[i] != .closeBracket, chars[i] != .openBracket { i += 1 }
        guard i < count, chars[i] == .closeBracket, i > start + 1,
              i + 1 < count, chars[i + 1] == .colon else { return nil }
        let urlStart = leadingWhitespaceEnd(from: i + 2)
        guard urlStart < count else { return nil }
        var urlEnd = urlStart
        while urlEnd < count, !chars[urlEnd].isWhitespace { urlEnd += 1 }
        spans.append(MarkdownSpan(start..<start + 1, .syntax))
        spans.append(MarkdownSpan(start + 1..<i, .link))
        spans.append(MarkdownSpan(i..<i + 2, .syntax))
        spans.append(MarkdownSpan(urlStart..<urlEnd, .url))
        if urlEnd < count { spans.append(MarkdownSpan(urlEnd..<count, .syntax)) }
        links.append(MarkdownLink(urlStart..<urlEnd, .url(destination(urlStart..<urlEnd))))
        return MarkdownLine(kind: .linkDefinition, contentStart: start, spans: spans, links: links)
    }

    private mutating func tableRow(at start: Int) -> MarkdownLine {
        let isDelimiterRow = chars[start...].allSatisfy {
            $0 == .pipe || $0 == .hyphen || $0 == .colon || $0.isWhitespace
        }
        if isDelimiterRow {
            return line(.table, contentStart: start, syntax: start..<count)
        }
        parseInline(start..<count)
        for i in start..<count where chars[i] == .pipe && !protected[i] {
            spans.append(MarkdownSpan(i..<i + 1, .syntax))
        }
        return MarkdownLine(kind: .table, contentStart: start, spans: spans, links: links)
    }

    // MARK: Inline

    private mutating func parseInline(_ range: Range<Int>) {
        guard !range.isEmpty else { return }
        scanCodeSpansEscapesAndAutolinks(range)
        scanLinks(range)
        scanBareURLs(range)
        scanEmphasis(range)
    }

    private mutating func protect(_ range: Range<Int>) {
        for i in range { protected[i] = true }
    }

    private mutating func scanCodeSpansEscapesAndAutolinks(_ range: Range<Int>) {
        var i = range.lowerBound
        while i < range.upperBound {
            let c = chars[i]
            if c == .backslash, i + 1 < range.upperBound, chars[i + 1].isASCIIPunctuation {
                spans.append(MarkdownSpan(i..<i + 1, .syntax))
                protect(i..<i + 2)
                i += 2
                continue
            }
            if c == .backtick {
                var runEnd = i
                while runEnd < range.upperBound, chars[runEnd] == .backtick { runEnd += 1 }
                let length = runEnd - i
                if let closing = findBacktickRun(length: length, from: runEnd, in: range) {
                    spans.append(MarkdownSpan(i..<runEnd, .syntax))
                    if runEnd < closing { spans.append(MarkdownSpan(runEnd..<closing, .code)) }
                    spans.append(MarkdownSpan(closing..<closing + length, .syntax))
                    protect(i..<closing + length)
                    i = closing + length
                } else {
                    i = runEnd
                }
                continue
            }
            if c == .lessThan, let end = autolinkEnd(from: i, in: range) {
                spans.append(MarkdownSpan(i..<i + 1, .syntax))
                spans.append(MarkdownSpan(i + 1..<end, .url))
                spans.append(MarkdownSpan(end..<end + 1, .syntax))
                links.append(MarkdownLink(i..<end + 1, .url(text(i + 1..<end))))
                protect(i..<end + 1)
                i = end + 1
                continue
            }
            i += 1
        }
    }

    private func findBacktickRun(length: Int, from start: Int, in range: Range<Int>) -> Int? {
        var i = start
        while i < range.upperBound {
            if chars[i] == .backtick {
                var runEnd = i
                while runEnd < range.upperBound, chars[runEnd] == .backtick { runEnd += 1 }
                if runEnd - i == length { return i }
                i = runEnd
            } else {
                i += 1
            }
        }
        return nil
    }

    /// `<scheme:…>` or `<name@host>`: returns the index of the closing `>`.
    private func autolinkEnd(from start: Int, in range: Range<Int>) -> Int? {
        var i = start + 1
        var sawColon = false, sawAt = false
        while i < range.upperBound {
            let c = chars[i]
            if c == .greaterThan { return (sawColon || sawAt) && i > start + 1 ? i : nil }
            if c == .lessThan || c.isWhitespace { return nil }
            if c == .colon { sawColon = true }
            if c == .at { sawAt = true }
            i += 1
        }
        return nil
    }

    private mutating func scanLinks(_ range: Range<Int>) {
        var openers: [Int] = []
        var i = range.lowerBound
        while i < range.upperBound {
            guard !protected[i] else {
                i += 1
                continue
            }
            let c = chars[i]
            if c == .openBracket {
                openers.append(i)
            } else if c == .closeBracket, let open = openers.popLast() {
                let isImage = open > range.lowerBound && chars[open - 1] == .exclamation && !protected[open - 1]
                let markupStart = isImage ? open - 1 : open
                let next = i + 1

                if open + 1 < i, chars[open + 1] == .caret {
                    // Footnote reference [^id].
                    spans.append(MarkdownSpan(open..<open + 2, .syntax))
                    if open + 2 < i { spans.append(MarkdownSpan(open + 2..<i, .link)) }
                    spans.append(MarkdownSpan(i..<i + 1, .syntax))
                    links.append(MarkdownLink(open..<i + 1, .footnote(text(open + 2..<i))))
                    protect(open..<i + 1)
                } else if next < range.upperBound, chars[next] == .openParen,
                          let close = closingParen(from: next + 1, in: range) {
                    spans.append(MarkdownSpan(markupStart..<open + 1, .syntax))
                    if open + 1 < i { spans.append(MarkdownSpan(open + 1..<i, .link)) }
                    spans.append(MarkdownSpan(i..<next + 1, .syntax))
                    if next + 1 < close { spans.append(MarkdownSpan(next + 1..<close, .destination)) }
                    spans.append(MarkdownSpan(close..<close + 1, .syntax))
                    links.append(MarkdownLink(markupStart..<close + 1, .url(destination(next + 1..<close))))
                    protect(markupStart..<open + 1)
                    protect(i..<close + 1)
                    openers.removeAll() // Links don't nest.
                    i = close + 1
                    continue
                } else if next < range.upperBound, chars[next] == .openBracket,
                          let refEnd = firstIndex(of: .closeBracket, from: next + 1, in: range) {
                    // Reference link [text][ref].
                    spans.append(MarkdownSpan(markupStart..<open + 1, .syntax))
                    if open + 1 < i { spans.append(MarkdownSpan(open + 1..<i, .link)) }
                    spans.append(MarkdownSpan(i..<next + 1, .syntax))
                    if next + 1 < refEnd { spans.append(MarkdownSpan(next + 1..<refEnd, .destination)) }
                    spans.append(MarkdownSpan(refEnd..<refEnd + 1, .syntax))
                    let label = next + 1 < refEnd ? text(next + 1..<refEnd) : text(open + 1..<i)
                    links.append(MarkdownLink(markupStart..<refEnd + 1, .reference(label)))
                    protect(markupStart..<open + 1)
                    protect(i..<refEnd + 1)
                    openers.removeAll()
                    i = refEnd + 1
                    continue
                }
            }
            i += 1
        }
    }

    /// Finds the `)` closing a link destination, allowing balanced parentheses.
    private func closingParen(from start: Int, in range: Range<Int>) -> Int? {
        var depth = 0
        var i = start
        while i < range.upperBound {
            let c = chars[i]
            if c == .backslash { i += 2; continue }
            if c == .openParen { depth += 1 }
            if c == .closeParen {
                if depth == 0 { return i }
                depth -= 1
            }
            i += 1
        }
        return nil
    }

    private func firstIndex(of char: UInt16, from start: Int, in range: Range<Int>) -> Int? {
        var i = start
        while i < range.upperBound {
            if chars[i] == char { return i }
            i += 1
        }
        return nil
    }

    private mutating func scanBareURLs(_ range: Range<Int>) {
        var i = range.lowerBound
        while i < range.upperBound {
            guard !protected[i], i == range.lowerBound || !chars[i - 1].isWordCharacter,
                  let prefix = urlPrefixLength(at: i, in: range) else {
                i += 1
                continue
            }
            var end = i + prefix
            while end < range.upperBound, !chars[end].isWhitespace, chars[end] != .lessThan, !protected[end] { end += 1 }
            // Trailing punctuation belongs to the sentence, not the URL.
            while end > i + prefix, chars[end - 1].isTrailingURLPunctuation { end -= 1 }
            if end > i + prefix {
                spans.append(MarkdownSpan(i..<end, .url))
                links.append(MarkdownLink(i..<end, .url(text(i..<end))))
                protect(i..<end)
            }
            i = end
        }
    }

    private func urlPrefixLength(at i: Int, in range: Range<Int>) -> Int? {
        for prefix in Self.urlPrefixes where i + prefix.count <= range.upperBound {
            var matches = true
            for (offset, unit) in prefix.enumerated() where chars[i + offset] | 0x20 != unit {
                matches = false
                break
            }
            if matches { return prefix.count }
        }
        return nil
    }

    private static let urlPrefixes: [[UInt16]] = ["https://", "http://", "www."].map { Array($0.utf16) }

    // MARK: Emphasis (CommonMark "process emphasis", plus GFM strikethrough)

    private struct Delimiter {
        var position: Int
        var char: UInt16
        var length: Int
        let originalLength: Int
        let canOpen: Bool
        let canClose: Bool
    }

    private mutating func scanEmphasis(_ range: Range<Int>) {
        var delimiters: [Delimiter] = []
        var i = range.lowerBound
        while i < range.upperBound {
            let c = chars[i]
            guard !protected[i], c == .asterisk || c == .underscore || c == .tilde else {
                i += 1
                continue
            }
            var end = i
            while end < range.upperBound, chars[end] == c, !protected[end] { end += 1 }
            let before: UInt16 = i > range.lowerBound ? chars[i - 1] : .space
            let after: UInt16 = end < range.upperBound ? chars[end] : .space
            let leftFlanking = !after.isWhitespace && (!after.isPunctuation || before.isWhitespace || before.isPunctuation)
            let rightFlanking = !before.isWhitespace && (!before.isPunctuation || after.isWhitespace || after.isPunctuation)

            let canOpen: Bool, canClose: Bool
            switch c {
            case .underscore:
                canOpen = leftFlanking && (!rightFlanking || before.isPunctuation)
                canClose = rightFlanking && (!leftFlanking || after.isPunctuation)
            default:
                canOpen = leftFlanking
                canClose = rightFlanking
            }
            let length = end - i
            if c != .tilde || length <= 2 {
                delimiters.append(Delimiter(position: i, char: c, length: length, originalLength: length, canOpen: canOpen, canClose: canClose))
            }
            i = end
        }
        guard delimiters.count > 1 else { return }

        // CommonMark's delimiter stack as links between array slots, so matched
        // or used-up delimiters drop out, and "openers_bottom": where the search
        // for an opener may stop because nothing below can match. Together they
        // keep long lines full of `*` and `_` (pasted data, minified code) linear.
        var previous = Array(-1..<(delimiters.count - 1))
        var bottoms = [Int](repeating: -1, count: 18)
        func bottomKey(_ closer: Delimiter) -> Int {
            let kind = closer.char == .asterisk ? 0 : closer.char == .underscore ? 1 : 2
            return kind * 6 + (closer.canOpen ? 3 : 0) + closer.originalLength % 3
        }

        var closerIndex = 0
        while closerIndex < delimiters.count {
            let closer = delimiters[closerIndex]
            guard closer.canClose, closer.length > 0 else {
                closerIndex += 1
                continue
            }
            let key = bottomKey(closer)
            var match: Int?
            var openerIndex = previous[closerIndex]
            while openerIndex > bottoms[key] {
                let opener = delimiters[openerIndex]
                if opener.char == closer.char, opener.canOpen, opener.length > 0 {
                    if closer.char == .tilde {
                        if opener.length == closer.length {
                            match = openerIndex
                            break
                        }
                    } else {
                        let sumIsMultipleOf3 = (opener.originalLength + closer.originalLength) % 3 == 0
                        let bothMultiplesOf3 = opener.originalLength % 3 == 0 && closer.originalLength % 3 == 0
                        if !((opener.canClose || closer.canOpen) && sumIsMultipleOf3 && !bothMultiplesOf3) {
                            match = openerIndex
                            break
                        }
                    }
                }
                openerIndex = previous[openerIndex]
            }

            guard let openerIndex = match else {
                bottoms[key] = previous[closerIndex]
                // A closer that can't open is of no further use.
                if !closer.canOpen, closerIndex + 1 < delimiters.count {
                    previous[closerIndex + 1] = previous[closerIndex]
                }
                closerIndex += 1
                continue
            }

            var opener = delimiters[openerIndex]
            var current = closer
            let use: Int
            let style: MarkdownStyle
            if current.char == .tilde {
                use = current.length
                style = .strikethrough
            } else {
                use = opener.length >= 2 && current.length >= 2 ? 2 : 1
                style = use == 2 ? .strong : .emphasis
            }
            let openerUsed = (opener.position + opener.length - use)..<(opener.position + opener.length)
            let closerUsed = current.position..<(current.position + use)
            spans.append(MarkdownSpan(openerUsed, .syntax))
            spans.append(MarkdownSpan(closerUsed, .syntax))
            if openerUsed.upperBound < closerUsed.lowerBound {
                spans.append(MarkdownSpan(openerUsed.upperBound..<closerUsed.lowerBound, style))
            }

            opener.length -= use
            current.position += use
            current.length -= use
            delimiters[openerIndex] = opener
            delimiters[closerIndex] = current
            // Delimiters between a matched pair can no longer match anything;
            // a used-up opener or closer neither.
            previous[closerIndex] = opener.length > 0 ? openerIndex : previous[openerIndex]
            if current.length == 0 {
                if closerIndex + 1 < delimiters.count { previous[closerIndex + 1] = previous[closerIndex] }
                closerIndex += 1
            }
        }
    }

    // MARK: Helpers

    private func text(_ range: Range<Int>) -> String {
        String(decoding: chars[range], as: UTF16.self)
    }

    /// A link destination without its angle brackets or title.
    private func destination(_ range: Range<Int>) -> String {
        let raw = text(range).trimmingCharacters(in: .whitespaces)
        if raw.hasPrefix("<"), let close = raw.firstIndex(of: ">") {
            return String(raw[raw.index(after: raw.startIndex)..<close])
        }
        return String(raw.prefix { !$0.isWhitespace })
    }

    private func leadingWhitespaceEnd(from start: Int) -> Int {
        var i = start
        while i < count, chars[i] == .space || chars[i] == .tab { i += 1 }
        return i
    }

    private func indentColumns(upTo end: Int) -> Int {
        var columns = 0
        for i in 0..<end { columns += chars[i] == .tab ? 4 - columns % 4 : 1 }
        return columns
    }
}

// MARK: - UTF-16 character classes

extension UInt16 {
    static let tab: UInt16 = 0x09
    static let space: UInt16 = 0x20
    static let exclamation: UInt16 = 0x21
    static let hash: UInt16 = 0x23
    static let openParen: UInt16 = 0x28
    static let closeParen: UInt16 = 0x29
    static let asterisk: UInt16 = 0x2A
    static let plus: UInt16 = 0x2B
    static let hyphen: UInt16 = 0x2D
    static let period: UInt16 = 0x2E
    static let colon: UInt16 = 0x3A
    static let lessThan: UInt16 = 0x3C
    static let greaterThan: UInt16 = 0x3E
    static let at: UInt16 = 0x40
    static let uppercaseX: UInt16 = 0x58
    static let openBracket: UInt16 = 0x5B
    static let backslash: UInt16 = 0x5C
    static let closeBracket: UInt16 = 0x5D
    static let caret: UInt16 = 0x5E
    static let underscore: UInt16 = 0x5F
    static let backtick: UInt16 = 0x60
    static let lowercaseX: UInt16 = 0x78
    static let pipe: UInt16 = 0x7C
    static let tilde: UInt16 = 0x7E

    var isWhitespace: Bool {
        switch self {
        case 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20, 0x85, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000:
            return true
        default:
            return false
        }
    }

    var isASCIIDigit: Bool { self >= 0x30 && self <= 0x39 }

    var isASCIIPunctuation: Bool {
        (0x21...0x2F).contains(self) || (0x3A...0x40).contains(self) || (0x5B...0x60).contains(self) || (0x7B...0x7E).contains(self)
    }

    /// ASCII punctuation plus the common Unicode punctuation blocks.
    var isPunctuation: Bool {
        isASCIIPunctuation
            || (0x2010...0x2027).contains(self) || (0x2030...0x205E).contains(self)
            || (0x3001...0x3003).contains(self) || (0x3008...0x3011).contains(self)
            || self == 0xA1 || self == 0xA7 || self == 0xAB || self == 0xB6 || self == 0xB7 || self == 0xBB || self == 0xBF
    }

    var isWordCharacter: Bool { !isWhitespace && !isPunctuation }

    var isTrailingURLPunctuation: Bool {
        self == .period || self == 0x2C || self == 0x3B || self == .colon || self == .exclamation
            || self == 0x3F || self == .closeParen || self == 0x22 || self == 0x27 || self == .asterisk || self == .underscore
    }
}
