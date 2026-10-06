#if os(macOS)
import AppKit
#else
import UIKit
#endif
import MinoteKit
import NaturalLanguage

/// Turns Markdown into its look, one line at a time.
///
/// Rendered view (the default): markup is hidden and only its effect shows —
/// larger bold headings, real bold and italic, underlined links, drawn
/// bullets, task boxes, quote bars, rules and code boxes (see
/// `MarkdownLayoutFragment`). Only the inline formatting under the caret
/// (`revealRange`) shows its markup, dimmed, so it can be edited. Source view
/// (`showsSyntax`) dims markup everywhere, the way iA Writer does.
///
/// Only the lines that changed are restyled, so typing cost doesn't grow
/// with the document.
public final class MarkdownStyler {
    public var styleSheet: EditorStyleSheet
    /// Colors adjectives, nouns, adverbs, verbs and conjunctions.
    public var highlightsPartsOfSpeech = false
    /// Focus mode: text outside this range is faded. nil when focus is off.
    public var focusRange: NSRange?
    /// Show markup everywhere instead of rendering it.
    public var showsSyntax = false
    /// Lines touching this range show their markup in rendered view.
    public var revealRange: NSRange?

    private lazy var tagger = NLTagger(tagSchemes: [.lexicalClass])

    public init(styleSheet: EditorStyleSheet) {
        self.styleSheet = styleSheet
    }

    // Per-character style flags.
    private struct Flags: OptionSet {
        let rawValue: UInt16
        static let syntax = Flags(rawValue: 1 << 0)
        static let strong = Flags(rawValue: 1 << 1)
        static let emphasis = Flags(rawValue: 1 << 2)
        static let strikethrough = Flags(rawValue: 1 << 3)
        static let code = Flags(rawValue: 1 << 4)
        static let url = Flags(rawValue: 1 << 5)
        static let link = Flags(rawValue: 1 << 6)
        static let destination = Flags(rawValue: 1 << 7)
        /// Markup that disappears in rendered view.
        static let hidden = Flags(rawValue: 1 << 8)
    }

    /// Restyles every line touching `range`. Call inside an editing session
    /// (or from `willProcessEditing`).
    public func style(_ storage: NSTextStorage, range: NSRange, fences: FenceIndex) {
        let string = storage.mutableString
        guard string.length > 0 else { return }
        let clamped = NSIntersectionRange(range, NSRange(location: 0, length: string.length))
        let block = string.lineRange(for: clamped)
        storage.setAttributes(styleSheet.baseAttributes, range: block)

        var location = block.location
        let end = NSMaxRange(block)
        var buffer: [UInt16] = []
        let rendered = !showsSyntax
        while location < end {
            var lineEnd = 0, contentsEnd = 0
            string.getLineStart(nil, end: &lineEnd, contentsEnd: &contentsEnd, for: NSRange(location: location, length: 0))
            let length = contentsEnd - location
            var codeEdges: (top: Bool, bottom: Bool)?
            if rendered, let fenced = fences.block(containing: location) {
                codeEdges = (location == fenced.location, lineEnd >= NSMaxRange(fenced))
            }
            if length > 0 {
                buffer = [UInt16](repeating: 0, count: length)
                string.getCharacters(&buffer, range: NSRange(location: location, length: length))
                let line = MarkdownLexer.lex(buffer, insideFence: fences.contains(location))
                let reveal = rendered && isRevealed(lineStart: location, lineEnd: lineEnd, endsWithBreak: lineEnd > contentsEnd)
                    ? localReveal(lineStart: location, length: length)
                    : nil
                let tableHeader = line.kind == .table && Self.isTableDelimiterRow(startingAt: lineEnd, in: string)
                apply(line, chars: buffer, at: location, lineEnd: lineEnd, rendered: rendered, reveal: reveal,
                      codeEdges: codeEdges, tableHeader: tableHeader, to: storage)
                if let focusRange {
                    fade(NSRange(location: location, length: length), outside: focusRange, in: storage)
                }
            } else if let codeEdges, lineEnd > location {
                // A blank line inside a code block is still part of its box.
                styleCodeLine(NSRange(location: location, length: lineEnd - location), edges: codeEdges, in: storage)
            }
            if lineEnd <= location { break }
            location = lineEnd
        }
    }

    /// Whether the caret or selection is on the line [start, end) (end
    /// includes the line break). A caret right after the break belongs to the
    /// next line, except at the very end of the document.
    private func isRevealed(lineStart start: Int, lineEnd end: Int, endsWithBreak: Bool) -> Bool {
        guard let reveal = revealRange else { return false }
        if reveal.length == 0 {
            let caret = reveal.location
            return caret >= start && (caret < end || (caret == end && !endsWithBreak))
        }
        return reveal.location < end && NSMaxRange(reveal) > start
    }

    /// The caret or selection in line-local offsets.
    private func localReveal(lineStart: Int, length: Int) -> Range<Int>? {
        guard let reveal = revealRange else { return nil }
        let start = min(max(reveal.location - lineStart, 0), length)
        let end = min(max(NSMaxRange(reveal) - lineStart, 0), length)
        return start..<max(start, end)
    }

    /// `| --- | :-: |`: the row under a table's header.
    static func isTableDelimiterRow(startingAt location: Int, in string: NSString) -> Bool {
        guard location < string.length else { return false }
        var contentsEnd = 0
        string.getLineStart(nil, end: nil, contentsEnd: &contentsEnd, for: NSRange(location: location, length: 0))
        var sawPipe = false, sawDash = false
        for i in location..<contentsEnd {
            switch string.character(at: i) {
            case 0x7C: sawPipe = true
            case 0x2D: sawDash = true
            case 0x3A, 0x20, 0x09: break
            default: return false
            }
        }
        return sawPipe && sawDash
    }

    // MARK: Lines

    /// `reveal` (line-local) is the caret or selection when it's on this line:
    /// the inline markup it touches shows, so it can be edited. Block markup
    /// (heading hashes, bullets, task boxes, quote markers, rules) never shows
    /// in rendered view: it is hidden, or drawn as what it means.
    private func apply(_ line: MarkdownLine, chars: [UInt16], at lineStart: Int, lineEnd: Int, rendered: Bool, reveal: Range<Int>?,
                       codeEdges: (top: Bool, bottom: Bool)?, tableHeader: Bool, to storage: NSTextStorage) {
        let fullLine = NSRange(location: lineStart, length: lineEnd - lineStart)
        let textRange = NSRange(location: lineStart, length: chars.count)
        let sheet = styleSheet
        func range(_ local: Range<Int>) -> NSRange { NSRange(location: lineStart + local.lowerBound, length: local.count) }
        func text(_ local: Range<Int>) -> String { String(decoding: chars[local], as: UTF16.self) }

        // Where links point, in both views (⌘-click follows them).
        for link in line.links where !link.range.isEmpty {
            storage.addAttribute(.minoteLink, value: LinkAttribute.encode(link.target), range: range(link.range))
        }

        // Geometry and block markup.
        var headingLevel: Int?
        /// Block markup before `contentStart` that is styled here, not by spans.
        var blockMarkupEnd = 0
        switch line.kind {
        case .heading(let level):
            headingLevel = level
            let heading = rendered ? sheet.heading(level: level) : nil
            let style = sheet.paragraphStyle(
                firstLineIndent: rendered ? 0 : -sheet.width(of: text(0..<line.contentStart)),
                headIndent: 0,
                lineHeight: heading?.lineHeight,
                spacingBefore: heading?.spacingBefore ?? 0
            )
            storage.addAttribute(.paragraphStyle, value: style, range: fullLine)
            if let heading {
                storage.addAttributes([.font: heading.font, .baselineOffset: heading.baselineOffset], range: textRange)
                hide(range(0..<line.contentStart), in: storage)
                blockMarkupEnd = line.contentStart
            }
        case .listItem, .taskItem:
            if rendered, let list = line.list {
                let indent = sheet.width(of: text(0..<list.marker.lowerBound))
                let cell = styleListMarker(list, line: line, chars: chars, at: lineStart, in: storage)
                storage.addAttribute(.paragraphStyle, value: sheet.paragraphStyle(firstLineIndent: 0, headIndent: indent + cell), range: fullLine)
                blockMarkupEnd = line.contentStart
            } else {
                storage.addAttribute(.paragraphStyle, value: sheet.paragraphStyle(firstLineIndent: 0, headIndent: sheet.width(of: text(0..<line.contentStart))), range: fullLine)
            }
        case .blockquote:
            if rendered {
                let indent = CGFloat(max(1, line.quoteDepth)) * sheet.quoteIndent
                storage.addAttribute(.foregroundColor, value: EditorTheme.quote, range: textRange)
                hide(range(0..<(line.list?.marker.lowerBound ?? line.contentStart)), in: storage)
                var headIndent = indent
                if let list = line.list {
                    headIndent += styleListMarker(list, line: line, chars: chars, at: lineStart, in: storage)
                }
                storage.addAttribute(.paragraphStyle, value: sheet.paragraphStyle(firstLineIndent: indent, headIndent: headIndent), range: fullLine)
                storage.addAttribute(.minoteBlock, value: MarkdownBlock.quote(depth: line.quoteDepth).rawValue, range: fullLine)
                blockMarkupEnd = line.contentStart
            } else {
                storage.addAttribute(.paragraphStyle, value: sheet.paragraphStyle(firstLineIndent: 0, headIndent: sheet.width(of: text(0..<line.contentStart))), range: fullLine)
            }
        default:
            break
        }

        switch line.kind {
        case .blank:
            return
        case .code:
            if rendered, let codeEdges { styleCodeLine(fullLine, edges: codeEdges, in: storage) }
            return
        case .fence:
            if rendered, let codeEdges { styleCodeLine(fullLine, edges: codeEdges, in: storage) }
            if rendered && reveal == nil {
                hide(textRange, in: storage)
            } else {
                storage.addAttribute(.foregroundColor, value: EditorTheme.syntax, range: textRange)
            }
            return
        case .thematicBreak:
            if rendered {
                hide(textRange, in: storage)
                storage.addAttribute(.minoteMark, value: MarkdownMark.rule.rawValue, range: textRange)
            } else {
                storage.addAttribute(.foregroundColor, value: EditorTheme.syntax, range: textRange)
            }
            return
        default:
            break
        }

        // Per-character flags from the lexer's inline spans.
        var flags = [Flags](repeating: [], count: chars.count)
        let doneContent: Range<Int>? = line.kind == .taskItem(done: true) ? line.contentStart..<chars.count : nil
        var closingHashes: Range<Int>?
        for span in line.spans {
            // Block markup was styled above.
            if blockMarkupEnd > 0, span.range.upperBound <= blockMarkupEnd { continue }
            if rendered, span.style == .strikethrough, span.range == doneContent { continue }
            if rendered, headingLevel != nil, span.style == .syntax, isClosingHashes(span.range, in: chars, after: line.contentStart) {
                closingHashes = span.range
                continue
            }
            let flag: Flags
            switch span.style {
            case .syntax: flag = .syntax
            case .strong: flag = .strong
            case .emphasis: flag = .emphasis
            case .strikethrough: flag = .strikethrough
            case .code: flag = .code
            case .url: flag = .url
            case .link: flag = .link
            case .destination: flag = .destination
            }
            for i in span.range where i < flags.count { flags[i].insert(flag) }
        }

        // What disappears in rendered view: inline markup, except where the
        // caret is (so it can be edited). Table pipes are drawn as lines below.
        if rendered {
            let keepsMarkers = line.kind == .table
            let shown = reveal.map { revealedRange(around: $0, flags: flags, from: blockMarkupEnd) } ?? 0..<0
            for i in flags.indices where flags[i].contains(.syntax) || flags[i].contains(.destination) {
                if i < blockMarkupEnd || keepsMarkers || shown.contains(i) { continue }
                flags[i].insert(.hidden)
            }
            if let closingHashes {
                for i in closingHashes where i < flags.count { flags[i] = [.hidden] }
            }
        }
        if headingLevel != nil {
            for i in line.contentStart..<chars.count where !flags[i].contains(.hidden) { flags[i].insert(.strong) }
        }
        if tableHeader {
            for i in line.contentStart..<chars.count where chars[i] != 0x7C { flags[i].insert(.strong) }
        }

        // Coalesce runs of identical flags into attribute ranges.
        var runStart = blockMarkupEnd
        while runStart < flags.count {
            let current = flags[runStart]
            var runEnd = runStart + 1
            while runEnd < flags.count, flags[runEnd] == current { runEnd += 1 }
            if !current.isEmpty {
                applyRun(current, NSRange(location: lineStart + runStart, length: runEnd - runStart), heading: headingLevel, rendered: rendered, to: storage)
            }
            runStart = runEnd
        }

        if rendered, let doneContent, !doneContent.isEmpty {
            storage.addAttributes([
                .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                .strikethroughColor: EditorTheme.doneTask,
                .foregroundColor: EditorTheme.doneTask,
            ], range: range(doneContent))
        }
        if rendered, line.kind == .table {
            styleTable(line, chars: chars, at: lineStart, in: storage)
        }
        if rendered, line.kind == .linkDefinition {
            // A reference's label is a quiet name, not a link.
            for span in line.spans where span.style == .link {
                storage.removeAttribute(.underlineStyle, range: range(span.range))
                storage.addAttribute(.foregroundColor, value: EditorTheme.syntax, range: range(span.range))
            }
        }

        if highlightsPartsOfSpeech {
            colorPartsOfSpeech(chars: chars, flags: flags, from: line.contentStart, at: lineStart, in: storage)
        }
    }

    /// A list marker in rendered view: a drawn bullet or task box, or the
    /// number. Returns the width of the marker's cell (the text starts after it).
    private func styleListMarker(_ list: MarkdownListMarker, line: MarkdownLine, chars: [UInt16], at lineStart: Int, in storage: NSTextStorage) -> CGFloat {
        let sheet = styleSheet
        func range(_ local: Range<Int>) -> NSRange { NSRange(location: lineStart + local.lowerBound, length: local.count) }
        func text(_ local: Range<Int>) -> String { String(decoding: chars[local], as: UTF16.self) }

        if let box = list.taskBox {
            // The marker's cell (marker and spaces) holds the drawn box; the
            // "[ ]" itself disappears.
            let cell = list.marker.lowerBound..<box.lowerBound
            storage.addAttributes([
                .foregroundColor: PlatformColor.clear,
                .minoteMark: MarkdownMark.checkbox(done: list.isDone).rawValue,
            ], range: range(list.marker))
            var width = sheet.width(of: text(cell))
            let needed = sheet.checkboxSize + (sheet.fonts.regular.pointSize * 0.5).rounded()
            if width < needed, cell.count > 0 {
                storage.addAttribute(.kern, value: needed - width, range: range(cell.upperBound - 1..<cell.upperBound))
                width = needed
            }
            hide(range(box.lowerBound..<line.contentStart), in: storage)
            return width
        }
        if list.ordered {
            storage.addAttribute(.foregroundColor, value: EditorTheme.listMarker, range: range(list.marker))
        } else {
            storage.addAttributes([
                .foregroundColor: PlatformColor.clear,
                .minoteMark: MarkdownMark.bullet(level: list.indentColumns / 2).rawValue,
            ], range: range(list.marker))
        }
        return sheet.width(of: text(list.marker.lowerBound..<line.contentStart))
    }

    /// A line of a fenced code block in rendered view: inset inside a box.
    private func styleCodeLine(_ fullLine: NSRange, edges: (top: Bool, bottom: Bool), in storage: NSTextStorage) {
        let indent = styleSheet.codeIndent
        storage.addAttributes([
            .paragraphStyle: styleSheet.paragraphStyle(firstLineIndent: indent, headIndent: indent),
            .minoteBlock: MarkdownBlock.code(top: edges.top, bottom: edges.bottom).rawValue,
        ], range: fullLine)
    }

    /// Table pipes become thin lines; the delimiter row becomes a rule.
    private func styleTable(_ line: MarkdownLine, chars: [UInt16], at lineStart: Int, in storage: NSTextStorage) {
        let isDelimiterRow = chars[line.contentStart...].allSatisfy { $0 == 0x7C || $0 == 0x2D || $0 == 0x3A || $0 == 0x20 || $0 == 0x09 }
        var i = line.contentStart
        while i < chars.count {
            let isPipe = chars[i] == 0x7C
            var end = i + 1
            if !isPipe { while end < chars.count, chars[end] != 0x7C { end += 1 } }
            let run = NSRange(location: lineStart + i, length: end - i)
            if isPipe {
                storage.addAttributes([.foregroundColor: PlatformColor.clear, .minoteMark: MarkdownMark.tablePipe.rawValue], range: run)
            } else if isDelimiterRow {
                storage.addAttributes([.foregroundColor: PlatformColor.clear, .minoteMark: MarkdownMark.tableRule.rawValue], range: run)
            }
            i = end
        }
    }

    /// A heading's optional closing `###`.
    private func isClosingHashes(_ range: Range<Int>, in chars: [UInt16], after contentStart: Int) -> Bool {
        guard range.lowerBound > contentStart || (range.lowerBound == contentStart && range.upperBound <= chars.count),
              !range.isEmpty, range.allSatisfy({ chars[$0] == 0x23 }) else { return false }
        return chars[range.upperBound...].allSatisfy { $0 == 0x20 || $0 == 0x09 }
    }

    /// Which inline markup shows around the caret: the formatted run it's in
    /// or touching (e.g. all of `**bold**`, or a whole link).
    private func revealedRange(around reveal: Range<Int>, flags: [Flags], from start: Int) -> Range<Int> {
        let styled: Flags = [.syntax, .strong, .emphasis, .strikethrough, .code, .link, .destination, .url]
        func isStyled(_ i: Int) -> Bool {
            i >= start && i < flags.count && !flags[i].isDisjoint(with: styled)
        }
        var lower = reveal.lowerBound, upper = reveal.upperBound
        while isStyled(lower - 1) { lower -= 1 }
        while isStyled(upper) { upper += 1 }
        return lower < upper ? lower..<upper : 0..<0
    }

    private func applyRun(_ flags: Flags, _ range: NSRange, heading: Int?, rendered: Bool, to storage: NSTextStorage) {
        if flags.contains(.hidden) {
            hide(range, in: storage)
            return
        }
        let strong = flags.contains(.strong), emphasis = flags.contains(.emphasis)
        if let heading, rendered {
            if emphasis {
                let font = styleSheet.heading(level: heading).font
                storage.addAttribute(.font, value: Self.italic(font), range: range)
            }
        } else if strong || emphasis {
            storage.addAttribute(.font, value: styleSheet.fonts.font(strong: strong, emphasis: emphasis), range: range)
        }
        if flags.contains(.syntax) || flags.contains(.destination) || (flags.contains(.url) && !rendered) {
            storage.addAttribute(.foregroundColor, value: EditorTheme.syntax, range: range)
        }
        if flags.contains(.strikethrough), !flags.contains(.syntax) {
            storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range)
        }
        if rendered, flags.contains(.code) {
            storage.addAttribute(.backgroundColor, value: EditorTheme.codeBackground, range: range)
        }
        if rendered, flags.contains(.link) || flags.contains(.url) {
            storage.addAttributes([
                .underlineStyle: NSUnderlineStyle.single.rawValue,
                .underlineColor: EditorTheme.linkUnderline,
            ], range: range)
        }
    }

    /// Markup in rendered view: a practically zero-width, invisible font.
    private func hide(_ range: NSRange, in storage: NSTextStorage) {
        storage.addAttributes([
            .font: styleSheet.hiddenFont,
            .foregroundColor: PlatformColor.clear,
        ], range: range)
        storage.removeAttribute(.backgroundColor, range: range)
    }

    /// Fades the parts of `line` that fall outside `focus`.
    private func fade(_ line: NSRange, outside focus: NSRange, in storage: NSTextStorage) {
        let before = NSRange(location: line.location, length: max(0, min(NSMaxRange(line), focus.location) - line.location))
        let afterStart = max(line.location, NSMaxRange(focus))
        let after = NSRange(location: afterStart, length: max(0, NSMaxRange(line) - afterStart))
        for range in [before, after] where range.length > 0 {
            storage.addAttribute(.minoteFaded, value: true, range: range)
            storage.enumerateAttribute(.foregroundColor, in: range) { value, run, _ in
                // Hidden markup stays hidden.
                if (value as? PlatformColor) != PlatformColor.clear {
                    storage.addAttribute(.foregroundColor, value: EditorTheme.faded, range: run)
                }
            }
        }
    }

    private func colorPartsOfSpeech(chars: [UInt16], flags: [Flags], from start: Int, at lineStart: Int, in storage: NSTextStorage) {
        guard start < chars.count else { return }
        let text = String(decoding: chars, as: UTF16.self)
        tagger.string = text
        let utf16 = text.utf16
        let startIndex = String.Index(utf16Offset: start, in: text)
        tagger.enumerateTags(in: startIndex..<text.endIndex, unit: .word, scheme: .lexicalClass,
                             options: [.omitWhitespace, .omitPunctuation, .omitOther]) { tag, range in
            guard let tag, let color = Self.color(for: tag) else { return true }
            let offset = utf16.distance(from: utf16.startIndex, to: range.lowerBound)
            let length = utf16.distance(from: range.lowerBound, to: range.upperBound)
            let excluded: Flags = [.syntax, .url, .code, .hidden, .destination]
            guard offset + length <= flags.count, flags[offset].isDisjoint(with: excluded) else { return true }
            storage.addAttribute(.foregroundColor, value: color, range: NSRange(location: lineStart + offset, length: length))
            return true
        }
    }

    private static func color(for tag: NLTag) -> PlatformColor? {
        switch tag {
        case .adjective: EditorTheme.adjective
        case .noun: EditorTheme.noun
        case .adverb: EditorTheme.adverb
        case .verb: EditorTheme.verb
        case .conjunction: EditorTheme.conjunction
        default: nil
        }
    }

    private func width(of text: String, in font: PlatformFont) -> CGFloat {
        (text.replacingOccurrences(of: "\t", with: "    ") as NSString).size(withAttributes: [.font: font]).width
    }

    private static func italic(_ font: PlatformFont) -> PlatformFont {
        #if os(macOS)
        let descriptor = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(.italic))
        return NSFont(descriptor: descriptor, size: font.pointSize) ?? font
        #else
        guard let descriptor = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(.traitItalic)) else { return font }
        return UIFont(descriptor: descriptor, size: font.pointSize)
        #endif
    }
}
