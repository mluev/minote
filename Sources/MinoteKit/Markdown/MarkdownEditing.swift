import Foundation

/// One replacement, in the coordinates of the text before the edit.
public struct TextReplacement: Equatable, Sendable {
    public var range: NSRange
    public var string: String

    public init(_ range: NSRange, _ string: String) {
        self.range = range
        self.string = string
    }
}

/// A set of non-overlapping replacements plus where the selection ends up
/// (in the coordinates of the text after the edit).
public struct TextEdit: Equatable, Sendable {
    public var replacements: [TextReplacement]
    public var selection: NSRange

    public init(_ replacements: [TextReplacement], selection: NSRange) {
        self.replacements = replacements.sorted { $0.range.location < $1.range.location }
        self.selection = selection
    }

    /// The text after applying the edit (used by tests and previews).
    public func applied(to text: String) -> String {
        let result = NSMutableString(string: text)
        for replacement in replacements.reversed() {
            result.replaceCharacters(in: replacement.range, with: replacement.string)
        }
        return result as String
    }
}

/// Markdown formatting as pure text transformations: the editor applies the
/// returned edit as one undoable change. Everything here works on NSString
/// (UTF-16) ranges, like the text system.
public enum MarkdownEditing {
    // MARK: Inline

    /// Bold (`**`), italic (`_`), strikethrough (`~~`), code (`` ` ``): wraps the
    /// selection or the word at the caret, or unwraps it if already wrapped.
    /// With nothing to wrap, inserts a marker pair and puts the caret inside.
    public static func toggleInline(_ marker: String, in text: NSString, selection: NSRange) -> TextEdit {
        let m = marker.utf16.count
        var selection = selection
        let caretOnly = selection.length == 0
        let caretLocation = selection.location

        if caretOnly {
            let p = selection.location
            if p >= m, p + m <= text.length,
               text.substring(with: NSRange(location: p - m, length: m)) == marker,
               text.substring(with: NSRange(location: p, length: m)) == marker {
                // Caret between an empty pair: remove it.
                return TextEdit([TextReplacement(NSRange(location: p - m, length: 2 * m), "")],
                                selection: NSRange(location: p - m, length: 0))
            }
            let word = wordRange(at: p, in: text)
            guard word.length > 0 else {
                return TextEdit([TextReplacement(NSRange(location: p, length: 0), marker + marker)],
                                selection: NSRange(location: p + m, length: 0))
            }
            selection = word
        }

        let segments = lineSegments(of: selection, in: text)
        guard let first = segments.first else {
            return TextEdit([], selection: selection)
        }
        let unwrap = isWrapped(first, marker: marker, in: text)

        var replacements: [TextReplacement] = []
        for segment in segments {
            if unwrap {
                if isWrappedOutside(segment, marker: marker, in: text) {
                    replacements.append(TextReplacement(NSRange(location: segment.location - m, length: m), ""))
                    replacements.append(TextReplacement(NSRange(location: NSMaxRange(segment), length: m), ""))
                } else if isWrappedInside(segment, marker: marker, in: text) {
                    replacements.append(TextReplacement(NSRange(location: segment.location, length: m), ""))
                    replacements.append(TextReplacement(NSRange(location: NSMaxRange(segment) - m, length: m), ""))
                }
            } else {
                replacements.append(TextReplacement(NSRange(location: segment.location, length: 0), marker))
                replacements.append(TextReplacement(NSRange(location: NSMaxRange(segment), length: 0), marker))
            }
        }

        if caretOnly {
            let caret = map(caretLocation, through: replacements, preferAfterInsertion: true)
            return TextEdit(replacements, selection: NSRange(location: caret, length: 0))
        }
        // Select the same words afterwards, without the markers.
        let start = map(segments[0].location, through: replacements, preferAfterInsertion: true)
        let end = map(NSMaxRange(segments[segments.count - 1]), through: replacements, preferAfterInsertion: false)
        return TextEdit(replacements, selection: NSRange(location: start, length: max(0, end - start)))
    }

    /// Wraps the selection in a link. A selected URL becomes the destination;
    /// otherwise `url` (e.g. from the clipboard) is used when given.
    public static func insertLink(in text: NSString, selection: NSRange, url: String?) -> TextEdit {
        let selected = trimmed(selection, in: text)
        let selectedText = text.substring(with: selected)
        if selected.length == 0 {
            let insert = "[](\(url ?? ""))"
            return TextEdit([TextReplacement(selection, insert)], selection: NSRange(location: selection.location + 1, length: 0))
        }
        if looksLikeURL(selectedText) {
            let insert = "[](\(selectedText))"
            return TextEdit([TextReplacement(selected, insert)], selection: NSRange(location: selected.location + 1, length: 0))
        }
        let destination = url ?? ""
        let insert = "[\(selectedText)](\(destination))"
        let textLength = selectedText.utf16.count
        let caret = url == nil
            ? NSRange(location: selected.location + textLength + 3, length: 0)
            : NSRange(location: selected.location + insert.utf16.count, length: 0)
        return TextEdit([TextReplacement(selected, insert)], selection: caret)
    }

    // MARK: Lines

    /// Makes the selected lines headings of `level` (1–6), or plain text if they
    /// already are (and for level 0).
    public static func toggleHeading(level: Int, in text: NSString, selection: NSRange) -> TextEdit {
        let lines = selectedLines(selection, in: text, skipBlank: true)
        let allAtLevel = level > 0 && lines.allSatisfy { headingPrefix(of: $0, in: text)?.level == level }
        var replacements: [TextReplacement] = []
        for line in lines {
            let existing = headingPrefix(of: line, in: text)
            let prefixRange = existing?.range ?? NSRange(location: line.location, length: 0)
            let newPrefix = (allAtLevel || level == 0) ? "" : String(repeating: "#", count: level) + " "
            if text.substring(with: prefixRange) != newPrefix {
                replacements.append(TextReplacement(prefixRange, newPrefix))
            }
        }
        return TextEdit(replacements, selection: mapSelection(selection, through: replacements))
    }

    public enum LineStyle: Sendable {
        case bullet, numbered, task, quote
    }

    /// Turns the selected lines into a list (or quote), or back into plain text.
    public static func toggle(_ style: LineStyle, in text: NSString, selection: NSRange) -> TextEdit {
        var lines = selectedLines(selection, in: text, skipBlank: true)
        if lines.isEmpty { lines = selectedLines(selection, in: text, skipBlank: false) }
        let infos = lines.map { LinePrefix(line: $0, in: text) }
        let allHave = infos.allSatisfy { $0.has(style) }

        var replacements: [TextReplacement] = []
        for (index, info) in infos.enumerated() {
            if style == .quote {
                if allHave {
                    replacements.append(TextReplacement(info.quoteRange, ""))
                } else if !info.has(.quote) {
                    replacements.append(TextReplacement(NSRange(location: info.line.location, length: 0), "> "))
                }
                continue
            }
            let marker: String
            switch style {
            case .bullet: marker = "- "
            case .numbered: marker = "\(index + 1). "
            case .task: marker = "- [ ] "
            case .quote: marker = ""
            }
            let target = allHave ? "" : marker
            if text.substring(with: info.listRange) != target {
                replacements.append(TextReplacement(info.listRange, target))
            }
        }
        return TextEdit(replacements, selection: mapSelection(selection, through: replacements))
    }

    /// Toggles a task between `[ ]` and `[x]`.
    public static func toggleTaskDone(in text: NSString, selection: NSRange) -> TextEdit? {
        var replacements: [TextReplacement] = []
        for line in selectedLines(selection, in: text, skipBlank: true) {
            let info = LinePrefix(line: line, in: text)
            guard let box = info.taskBox else { continue }
            replacements.append(TextReplacement(box, info.taskDone ? " " : "x"))
        }
        guard !replacements.isEmpty else { return nil }
        return TextEdit(replacements, selection: selection)
    }

    /// Wraps the selected lines in a ``` fence, or removes the fence around them.
    public static func toggleCodeBlock(in text: NSString, selection: NSRange) -> TextEdit {
        let block = text.lineRange(for: selection)
        // Already fenced: the lines right before and after are fences.
        if block.location > 0, NSMaxRange(block) < text.length {
            let before = text.lineRange(for: NSRange(location: block.location - 1, length: 0))
            let after = text.lineRange(for: NSRange(location: NSMaxRange(block), length: 0))
            if isFenceLine(before, in: text), isFenceLine(after, in: text) {
                // A closing fence on the last line takes the line break before it along.
                let afterEndsWithNewline = text.substring(with: after).hasSuffix("\n")
                let closing = afterEndsWithNewline
                    ? after
                    : NSRange(location: after.location - 1, length: after.length + 1)
                let replacements = [TextReplacement(before, ""), TextReplacement(closing, "")]
                return TextEdit(replacements, selection: mapSelection(selection, through: replacements, keepInsertionsInside: false))
            }
        }
        let content = text.substring(with: block)
        if content.isBlank {
            let replacement = TextReplacement(selection.length == 0 ? NSRange(location: block.location, length: (content as NSString).length - (content.hasSuffix("\n") ? 1 : 0)) : block, "```\n\n```")
            return TextEdit([replacement], selection: NSRange(location: block.location + 4, length: 0))
        }
        let endsWithNewline = content.hasSuffix("\n")
        let replacements = [
            TextReplacement(NSRange(location: block.location, length: 0), "```\n"),
            TextReplacement(NSRange(location: NSMaxRange(block), length: 0), endsWithNewline ? "```\n" : "\n```"),
        ]
        return TextEdit(replacements, selection: mapSelection(selection, through: replacements, keepInsertionsInside: false))
    }

    /// Inserts a `---` rule on its own line below the caret's line.
    public static func insertHorizontalRule(in text: NSString, selection: NSRange) -> TextEdit {
        let line = text.lineRange(for: NSRange(location: selection.location, length: 0))
        let content = text.substring(with: line)
        if content.isBlank {
            let contentsEnd = NSMaxRange(line) - (content.hasSuffix("\n") ? 1 : 0)
            let replacement = TextReplacement(NSRange(location: line.location, length: contentsEnd - line.location), "---")
            return TextEdit([replacement], selection: NSRange(location: line.location + 3, length: 0))
        }
        let endsWithNewline = content.hasSuffix("\n")
        let insertAt = NSMaxRange(line) - (endsWithNewline ? 1 : 0)
        let insertion = "\n\n---\n"
        return TextEdit([TextReplacement(NSRange(location: insertAt, length: 0), insertion)],
                        selection: NSRange(location: insertAt + insertion.utf16.count, length: 0))
    }

    // MARK: Typing

    /// Return inside a list or quote continues it; Return on an empty item ends
    /// it. Returns nil when the default newline should be used.
    public static func newline(in text: NSString, selection: NSRange) -> TextEdit? {
        guard selection.length == 0 else { return nil }
        let line = text.lineRange(for: selection)
        let info = LinePrefix(line: line, in: text)
        guard info.hasAnyMarker, selection.location >= info.contentStart else { return nil }

        let contentEnd = info.contentsEnd
        let content = text.substring(with: NSRange(location: info.contentStart, length: contentEnd - info.contentStart))
        if content.isBlank, selection.location >= contentEnd || selection.location == info.contentStart {
            // Empty item: end the list (or quote) by removing the marker.
            let range = NSRange(location: line.location, length: contentEnd - line.location)
            return TextEdit([TextReplacement(range, "")], selection: NSRange(location: line.location, length: 0))
        }
        let prefix = info.continuationPrefix(in: text)
        let insertion = "\n" + prefix
        return TextEdit([TextReplacement(selection, insertion)],
                        selection: NSRange(location: selection.location + insertion.utf16.count, length: 0))
    }

    // MARK: Rendered view

    /// The block markup at the start of a line that the rendered view hides
    /// (heading hashes, list bullet, task box, quote marker) or draws instead
    /// (a `---` rule). The caret never rests inside `zone`; it goes to `home`.
    public struct HiddenMarkup: Equatable, Sendable {
        /// The line, without its terminator.
        public var line: NSRange
        public var zone: NSRange
        /// Where the caret rests: where the text starts (after a rule: its end).
        public var home: Int
    }

    public static func hiddenMarkup(in text: NSString, at location: Int, insideFence: Bool) -> HiddenMarkup? {
        guard text.length > 0, !insideFence else { return nil }
        var start = 0, contentsEnd = 0
        text.getLineStart(&start, end: nil, contentsEnd: &contentsEnd, for: NSRange(location: min(location, text.length), length: 0))
        let line = NSRange(location: start, length: contentsEnd - start)
        guard line.length > 0 else { return nil }
        let lexed = MarkdownLexer.lex(FenceIndex.characters(text, start..<contentsEnd), insideFence: false)
        switch lexed.kind {
        case .heading, .listItem, .taskItem, .blockquote:
            guard lexed.contentStart > 0 else { return nil }
            return HiddenMarkup(line: line, zone: NSRange(location: start, length: lexed.contentStart), home: start + lexed.contentStart)
        case .thematicBreak:
            return HiddenMarkup(line: line, zone: line, home: contentsEnd)
        default:
            return nil
        }
    }

    /// Backspace right after hidden markup takes the markup away as one unit:
    /// a heading becomes text, a nested item moves out a level, an item or a
    /// quote level ends, a rule disappears. Nil when it's an ordinary backspace.
    public static func deleteMarkup(in text: NSString, selection: NSRange, insideFence: Bool) -> TextEdit? {
        guard selection.length == 0,
              let markup = hiddenMarkup(in: text, at: selection.location, insideFence: insideFence),
              selection.location == markup.home else { return nil }
        let start = markup.line.location
        let lexed = MarkdownLexer.lex(FenceIndex.characters(text, start..<NSMaxRange(markup.line)), insideFence: false)
        func removing(_ range: NSRange) -> TextEdit {
            let replacement = TextReplacement(range, "")
            return TextEdit([replacement], selection: NSRange(location: map(selection.location, through: [replacement], preferAfterInsertion: true), length: 0))
        }
        switch lexed.kind {
        case .listItem, .taskItem:
            if let list = lexed.list, list.indentColumns > 0,
               let outdent = shiftLines(in: text, selection: selection, outdent: true, listsOnly: true), !outdent.replacements.isEmpty {
                return outdent
            }
            return removing(markup.zone)
        case .blockquote:
            if let list = lexed.list {
                return removing(NSRange(location: start + list.marker.lowerBound, length: lexed.contentStart - list.marker.lowerBound))
            }
            // One quote level: the first ">" and the space after it.
            let units = FenceIndex.characters(text, start..<NSMaxRange(markup.line))
            guard let first = units.firstIndex(of: 0x3E) else { return removing(markup.zone) }
            let end = first + 1 < units.count && units[first + 1] == 0x20 ? first + 2 : first + 1
            return removing(NSRange(location: start, length: end))
        default:
            return removing(markup.zone)
        }
    }

    /// Where a caret that landed inside hidden markup goes: to where the text
    /// starts, or, when it just stepped back from there, to the end of the
    /// line above (so the Left arrow can leave the line).
    public static func adjustedCaret(_ location: Int, previous: Int?, in text: NSString, insideFence: Bool) -> Int {
        guard let markup = hiddenMarkup(in: text, at: location, insideFence: insideFence),
              location >= markup.zone.location, location < markup.home else { return location }
        if let previous, previous == markup.home, location == previous - 1, markup.line.location > 0 {
            return markup.line.location - 1
        }
        return markup.home
    }

    /// Indents (or outdents) the selected lines. With `listsOnly`, does nothing
    /// unless the caret is in a list item (so Tab still types a tab elsewhere).
    public static func shiftLines(in text: NSString, selection: NSRange, outdent: Bool, listsOnly: Bool) -> TextEdit? {
        let lines = selectedLines(selection, in: text, skipBlank: true)
        let infos = lines.map { LinePrefix(line: $0, in: text) }
        if listsOnly, !(infos.first?.isListItem ?? false) { return nil }

        var replacements: [TextReplacement] = []
        for info in infos {
            let unit = info.isListItem ? max(2, info.listMarkerWidth) : 4
            if outdent {
                let indent = text.substring(with: NSRange(location: info.line.location, length: info.indentEnd - info.line.location))
                if indent.hasPrefix("\t") {
                    replacements.append(TextReplacement(NSRange(location: info.line.location, length: 1), ""))
                } else {
                    let spaces = min(unit, indent.prefix(while: { $0 == " " }).count)
                    if spaces > 0 { replacements.append(TextReplacement(NSRange(location: info.line.location, length: spaces), "")) }
                }
            } else {
                replacements.append(TextReplacement(NSRange(location: info.line.location, length: 0), String(repeating: " ", count: unit)))
            }
        }
        guard !replacements.isEmpty else { return listsOnly ? TextEdit([], selection: selection) : nil }
        return TextEdit(replacements, selection: mapSelection(selection, through: replacements))
    }

    // MARK: - Helpers

    /// Maps a location in the old text to the new text.
    static func map(_ location: Int, through replacements: [TextReplacement], preferAfterInsertion: Bool) -> Int {
        var offset = 0
        for replacement in replacements.sorted(by: { $0.range.location < $1.range.location }) {
            let range = replacement.range
            let newLength = replacement.string.utf16.count
            if location > NSMaxRange(range) || (location == NSMaxRange(range) && (range.length > 0 || preferAfterInsertion)) {
                offset += newLength - range.length
            } else if location > range.location {
                // Inside replaced text: clamp into the replacement.
                return range.location + offset + min(location - range.location, newLength)
            } else {
                break
            }
        }
        return location + offset
    }

    /// Maps a selection through line-prefix edits. A caret moves past text
    /// inserted at its position; a selection starting at a line start keeps
    /// the new prefix inside it (so the whole lines stay selected).
    static func mapSelection(_ selection: NSRange, through replacements: [TextReplacement], keepInsertionsInside: Bool = true) -> NSRange {
        guard selection.length > 0 else {
            return NSRange(location: map(selection.location, through: replacements, preferAfterInsertion: true), length: 0)
        }
        let start = map(selection.location, through: replacements, preferAfterInsertion: !keepInsertionsInside)
        let end = map(NSMaxRange(selection), through: replacements, preferAfterInsertion: keepInsertionsInside)
        return NSRange(location: start, length: max(0, end - start))
    }

    /// Lines touched by the selection, without their terminators.
    static func selectedLines(_ selection: NSRange, in text: NSString, skipBlank: Bool) -> [NSRange] {
        var lines: [NSRange] = []
        let block = text.lineRange(for: selection)
        var location = block.location
        repeat {
            var lineEnd = 0, contentsEnd = 0
            text.getLineStart(nil, end: &lineEnd, contentsEnd: &contentsEnd, for: NSRange(location: location, length: 0))
            let line = NSRange(location: location, length: contentsEnd - location)
            if !skipBlank || !text.substring(with: line).isBlank { lines.append(line) }
            if lineEnd <= location { break }
            location = lineEnd
        } while location < NSMaxRange(block)
        return lines
    }

    /// The selection split per line and trimmed of surrounding whitespace.
    private static func lineSegments(of selection: NSRange, in text: NSString) -> [NSRange] {
        var segments: [NSRange] = []
        for line in selectedLines(selection, in: text, skipBlank: true) {
            let intersection = NSIntersectionRange(line, selection)
            let segment = trimmed(intersection, in: text)
            if segment.length > 0 { segments.append(segment) }
        }
        if segments.isEmpty, selection.length > 0 {
            let segment = trimmed(selection, in: text)
            if segment.length > 0 { segments.append(segment) }
        }
        return segments
    }

    private static func isWrapped(_ range: NSRange, marker: String, in text: NSString) -> Bool {
        isWrappedOutside(range, marker: marker, in: text) || isWrappedInside(range, marker: marker, in: text)
    }

    private static func isWrappedOutside(_ range: NSRange, marker: String, in text: NSString) -> Bool {
        let m = marker.utf16.count
        guard range.location >= m, NSMaxRange(range) + m <= text.length else { return false }
        return text.substring(with: NSRange(location: range.location - m, length: m)) == marker
            && text.substring(with: NSRange(location: NSMaxRange(range), length: m)) == marker
    }

    private static func isWrappedInside(_ range: NSRange, marker: String, in text: NSString) -> Bool {
        let m = marker.utf16.count
        guard range.length >= 2 * m + 1 else { return false }
        let content = text.substring(with: range)
        return content.hasPrefix(marker) && content.hasSuffix(marker)
    }

    private static func trimmed(_ range: NSRange, in text: NSString) -> NSRange {
        var start = range.location, end = NSMaxRange(range)
        while start < end, text.character(at: start).isWhitespace { start += 1 }
        while end > start, text.character(at: end - 1).isWhitespace { end -= 1 }
        return NSRange(location: start, length: end - start)
    }

    /// The word around the caret (letters, digits, apostrophes inside words).
    static func wordRange(at location: Int, in text: NSString) -> NSRange {
        func isWordUnit(_ index: Int) -> Bool {
            guard index >= 0, index < text.length else { return false }
            let unit = text.character(at: index)
            if UTF16.isLeadSurrogate(unit) || UTF16.isTrailSurrogate(unit) { return true }
            guard let scalar = Unicode.Scalar(unit) else { return false }
            return CharacterSet.alphanumerics.contains(scalar) || scalar == "'" || scalar == "’"
        }
        var start = location, end = location
        while isWordUnit(start - 1) { start -= 1 }
        while isWordUnit(end) { end += 1 }
        return NSRange(location: start, length: end - start)
    }

    private static func looksLikeURL(_ string: String) -> Bool {
        let lower = string.lowercased()
        return !string.contains(where: \.isWhitespace)
            && (lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("mailto:") || lower.hasPrefix("www."))
    }

    private static func headingPrefix(of line: NSRange, in text: NSString) -> (level: Int, range: NSRange)? {
        let chars = FenceIndex.characters(text, line.location..<NSMaxRange(line))
        var i = 0
        while i < chars.count, i < 3, chars[i] == .space { i += 1 }
        let hashesStart = i
        while i < chars.count, chars[i] == .hash { i += 1 }
        let level = i - hashesStart
        guard (1...6).contains(level), i == chars.count || chars[i] == .space || chars[i] == .tab else { return nil }
        while i < chars.count, chars[i] == .space || chars[i] == .tab { i += 1 }
        return (level, NSRange(location: line.location, length: i))
    }

    private static func isFenceLine(_ line: NSRange, in text: NSString) -> Bool {
        var end = NSMaxRange(line)
        while end > line.location, text.character(at: end - 1) == 0x0A || text.character(at: end - 1) == 0x0D { end -= 1 }
        return MarkdownLexer.fence(in: FenceIndex.characters(text, line.location..<end)) != nil
    }
}

/// The leading markup of one line: indentation, quote markers, list marker, task box.
struct LinePrefix {
    let line: NSRange
    /// End of leading indentation.
    let indentEnd: Int
    /// Quote markers ("> > "), possibly empty, located after the indentation.
    let quoteRange: NSRange
    /// List marker ("- ", "1. ", "- [ ] "), possibly empty, after quote markers.
    let listRange: NSRange
    let contentStart: Int
    let contentsEnd: Int
    let bullet: UInt16?
    let number: Int?
    let numberDelimiter: UInt16?
    let taskBox: NSRange?
    let taskDone: Bool

    init(line lineRange: NSRange, in text: NSString) {
        var contentsEnd = NSMaxRange(lineRange)
        while contentsEnd > lineRange.location,
              text.character(at: contentsEnd - 1) == 0x0A || text.character(at: contentsEnd - 1) == 0x0D {
            contentsEnd -= 1
        }
        self.contentsEnd = contentsEnd
        line = NSRange(location: lineRange.location, length: contentsEnd - lineRange.location)
        let chars = FenceIndex.characters(text, line.location..<contentsEnd)
        let base = line.location

        var i = 0
        while i < chars.count, chars[i] == .space || chars[i] == .tab { i += 1 }
        indentEnd = base + i

        let quoteStart = i
        while i < chars.count, chars[i] == .greaterThan {
            i += 1
            if i < chars.count, chars[i] == .space { i += 1 }
        }
        quoteRange = NSRange(location: base + quoteStart, length: i - quoteStart)

        let listStart = i
        var bullet: UInt16?, number: Int?, delimiter: UInt16?
        var j = i
        if j < chars.count, chars[j] == .hyphen || chars[j] == .asterisk || chars[j] == .plus,
           j + 1 == chars.count || chars[j + 1] == .space {
            bullet = chars[j]
            j += 1
        } else {
            var digits = 0
            var value = 0
            while j < chars.count, chars[j].isASCIIDigit, digits < 9 {
                value = value * 10 + Int(chars[j] - 0x30)
                j += 1
                digits += 1
            }
            if digits > 0, j < chars.count, chars[j] == .period || chars[j] == .closeParen,
               j + 1 == chars.count || chars[j + 1] == .space {
                number = value
                delimiter = chars[j]
                j += 1
            } else {
                j = i
            }
        }
        var taskBox: NSRange?
        var taskDone = false
        if bullet != nil || number != nil {
            if j < chars.count, chars[j] == .space { j += 1 }
            if j + 2 < chars.count, chars[j] == .openBracket, chars[j + 2] == .closeBracket,
               chars[j + 1] == .space || chars[j + 1] == .lowercaseX || chars[j + 1] == .uppercaseX,
               j + 3 == chars.count || chars[j + 3] == .space {
                taskBox = NSRange(location: base + j + 1, length: 1)
                taskDone = chars[j + 1] != .space
                j += 3
                if j < chars.count, chars[j] == .space { j += 1 }
            }
            i = j
        }
        self.bullet = bullet
        self.number = number
        numberDelimiter = delimiter
        self.taskBox = taskBox
        self.taskDone = taskDone
        listRange = NSRange(location: base + listStart, length: i - listStart)
        contentStart = base + i
    }

    var isListItem: Bool { bullet != nil || number != nil }
    var hasAnyMarker: Bool { isListItem || quoteRange.length > 0 }
    var listMarkerWidth: Int { listRange.length - (taskBox != nil ? 4 : 0) }

    func has(_ style: MarkdownEditing.LineStyle) -> Bool {
        switch style {
        case .bullet: bullet != nil && taskBox == nil
        case .numbered: number != nil
        case .task: taskBox != nil
        case .quote: quoteRange.length > 0
        }
    }

    /// What the next line should start with after Return.
    func continuationPrefix(in text: NSString) -> String {
        var prefix = text.substring(with: NSRange(location: line.location, length: indentEnd - line.location))
        prefix += text.substring(with: quoteRange)
        if let bullet {
            prefix += String(UnicodeScalar(UInt8(bullet))) + " "
        } else if let number, let numberDelimiter {
            prefix += "\(number + 1)" + String(UnicodeScalar(UInt8(numberDelimiter))) + " "
        }
        if taskBox != nil { prefix += "[ ] " }
        return prefix
    }
}
