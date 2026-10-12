#if os(macOS)
import AppKit
public typealias TextStorageEditActions = NSTextStorageEditActions
#else
import UIKit
public typealias TextStorageEditActions = NSTextStorage.EditActions
#endif
import MinoteKit

/// The platform-neutral part of the editor, shared by the AppKit and UIKit text
/// views: incremental Markdown styling, code-fence tracking and Focus mode.
/// Install it as the text storage's delegate.
@MainActor
public final class EditorTextEngine: NSObject, @preconcurrency NSTextStorageDelegate {
    public let styler: MarkdownStyler
    public private(set) var configuration: EditorConfiguration
    /// Whether heading markers hang into the margin (off on narrow screens).
    public private(set) var hangsMarkers: Bool
    /// True while the input method is composing (marked text): restyling then
    /// would wipe the composition underline.
    public var isComposing: () -> Bool = { false }

    private weak var storage: NSTextStorage?
    private weak var layoutManager: NSTextLayoutManager?
    private let layoutDelegate: MarkdownLayoutDelegate
    private var fences = FenceIndex()
    /// Set when a whole new text arrives, so the next edit restyles everything.
    private var needsFullRestyle = true
    private var focusedRange: NSRange?
    /// Lines whose markup is shown (the caret's), as last styled.
    private var revealedLines: NSRange?

    public var styleSheet: EditorStyleSheet { styler.styleSheet }

    public init(storage: NSTextStorage, configuration: EditorConfiguration, hangsMarkers: Bool = true) {
        self.storage = storage
        self.configuration = configuration
        self.hangsMarkers = hangsMarkers
        styler = MarkdownStyler(styleSheet: EditorStyleSheet(family: configuration.family, size: CGFloat(configuration.size), hangsMarkers: hangsMarkers))
        styler.highlightsPartsOfSpeech = configuration.partsOfSpeech
        styler.showsSyntax = !configuration.rendersMarkdown
        layoutDelegate = MarkdownLayoutDelegate(styleSheet: styler.styleSheet)
        super.init()
        storage.delegate = self
    }

    /// Draws bullets, task boxes, quote bars, rules and code boxes in the text
    /// view's layout (TextKit 2).
    public func attach(to layoutManager: NSTextLayoutManager?) {
        self.layoutManager = layoutManager
        layoutManager?.delegate = layoutDelegate
    }

    // MARK: Configuration

    public struct Change: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let styleSheet = Change(rawValue: 1 << 0)
        public static let focus = Change(rawValue: 1 << 1)
        public static let typewriter = Change(rawValue: 1 << 2)
        public static let preview = Change(rawValue: 1 << 3)
    }

    /// Applies new settings, restyling as needed. Returns what changed so the
    /// view can update its geometry.
    @discardableResult
    public func apply(_ new: EditorConfiguration, hangsMarkers: Bool? = nil, selection: NSRange) -> Change {
        let old = configuration
        let oldHangs = self.hangsMarkers
        configuration = new
        if let hangsMarkers { self.hangsMarkers = hangsMarkers }
        var change: Change = []

        if new.family != old.family || new.size != old.size || self.hangsMarkers != oldHangs {
            styler.styleSheet = EditorStyleSheet(family: new.family, size: CGFloat(new.size), hangsMarkers: self.hangsMarkers)
            layoutDelegate.styleSheet = styler.styleSheet
            change.insert(.styleSheet)
        }
        if new.typewriter != old.typewriter { change.insert(.typewriter) }
        if new.focus != old.focus { change.insert(.focus) }
        if new.preview != old.preview { change.insert(.preview) }
        styler.highlightsPartsOfSpeech = new.partsOfSpeech
        styler.showsSyntax = !new.rendersMarkdown

        if change.contains(.styleSheet) || change.contains(.preview) || new.partsOfSpeech != old.partsOfSpeech || new.showsSyntax != old.showsSyntax {
            restyleAll(selection: selection)
        } else if change.contains(.focus) {
            selectionDidChange(selection, force: true)
        }
        return change
    }

    // MARK: Text lifecycle

    /// Call right before replacing the whole text (switching notes).
    public func prepareForNewText() {
        needsFullRestyle = true
        focusedRange = nil
        styler.focusRange = nil
        revealedLines = nil
        styler.revealRange = nil
    }

    /// Restyles the whole document (after a font or setting change).
    public func restyleAll(selection: NSRange) {
        guard let storage else { return }
        fences.rebuild(storage.mutableString)
        focusedRange = configuration.focus == .off || storage.length == 0 ? nil : focusTarget(selection: selection, in: storage.mutableString)
        styler.focusRange = focusedRange
        revealedLines = revealTarget(selection: selection, in: storage.mutableString)
        styler.revealRange = revealedLines == nil ? nil : selection
        storage.beginEditing()
        styler.style(storage, range: NSRange(location: 0, length: storage.length), fences: fences)
        storage.endEditing()
    }

    /// A copy for printing or exporting: fully styled, without Focus fading.
    public func printableCopy() -> NSAttributedString {
        guard let storage else { return NSAttributedString() }
        let copy = NSTextStorage(attributedString: storage)
        let focus = styler.focusRange, reveal = styler.revealRange
        styler.focusRange = nil
        styler.revealRange = nil
        styler.style(copy, range: NSRange(location: 0, length: copy.length), fences: fences)
        styler.focusRange = focus
        styler.revealRange = reveal
        Self.replaceDrawnMarkup(in: copy, styleSheet: styler.styleSheet)
        return copy
    }

    /// Printing lays text out without our layout fragments: what they draw
    /// becomes characters (•, ☐, ─) and code lines get a plain background.
    private static func replaceDrawnMarkup(in copy: NSTextStorage, styleSheet: EditorStyleSheet) {
        let all = NSRange(location: 0, length: copy.length)
        copy.beginEditing()
        copy.enumerateAttribute(.minoteBlock, in: all) { value, run, _ in
            guard let raw = value as? String, case .code? = MarkdownBlock(rawValue: raw) else { return }
            copy.addAttribute(.backgroundColor, value: EditorTheme.codeBackground, range: run)
        }
        let visible: [NSAttributedString.Key: Any] = [.font: styleSheet.fonts.regular, .foregroundColor: EditorTheme.listMarker]
        copy.enumerateAttribute(.minoteMark, in: all, options: .reverse) { value, run, _ in
            guard let raw = value as? String, let mark = MarkdownMark(rawValue: raw) else { return }
            let replacement: String
            switch mark {
            case .bullet(let level): replacement = ["•", "◦", "▪"][level % 3]
            case .checkbox(let done): replacement = done ? "☑" : "☐"
            case .rule: replacement = String(repeating: "─", count: 24)
            case .tableRule: replacement = String(repeating: "─", count: run.length)
            case .tablePipe:
                copy.addAttributes(visible, range: run)
                return
            }
            let attributes = copy.attributes(at: run.location, effectiveRange: nil).merging(visible) { $1 }
            copy.replaceCharacters(in: run, with: NSAttributedString(string: replacement, attributes: attributes))
        }
        copy.endEditing()
    }

    // MARK: NSTextStorageDelegate

    /// Restyles the lines an edit touched (plus any region whose code-fence
    /// state changed) before the layout manager sees them.
    public func textStorage(_ textStorage: NSTextStorage, willProcessEditing editedMask: TextStorageEditActions, range editedRange: NSRange, changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters) else { return }
        let text = textStorage.mutableString
        var range = editedRange
        if needsFullRestyle {
            needsFullRestyle = false
            fences.rebuild(text)
            range = NSRange(location: 0, length: text.length)
        } else if let invalidated = fences.update(text, editedRange: editedRange, changeInLength: delta) {
            range = NSUnionRange(range, invalidated)
        }
        // A table header's look depends on the row below it.
        let lineStart = text.lineRange(for: NSRange(location: range.location, length: 0)).location
        if lineStart > 0 {
            let above = text.lineRange(for: NSRange(location: lineStart - 1, length: 0))
            if Self.isTableRow(above, in: text) { range = NSUnionRange(range, above) }
        }
        // The focus range and the revealed lines move, grow and shrink with
        // the typing, so the selection change that follows doesn't restyle
        // what was just styled.
        func shift(_ range: NSRange) -> NSRange {
            var range = range
            let oldEnd = editedRange.location + editedRange.length - delta
            if oldEnd <= range.location, editedRange.location < range.location {
                range.location = max(0, range.location + delta)
            } else if editedRange.location <= NSMaxRange(range) {
                range.length = max(0, range.length + delta)
            }
            return range.clamped(to: text.length)
        }
        focusedRange = focusedRange.map(shift)
        styler.focusRange = focusedRange
        revealedLines = revealedLines.map(shift)
        if var reveal = styler.revealRange {
            // The caret moves with the typing; keep its line revealed.
            if editedRange.location <= reveal.location { reveal.location = max(0, reveal.location + delta) }
            styler.revealRange = reveal.clamped(to: text.length)
        }
        guard !isComposing() else { return }
        styler.style(textStorage, range: range, fences: fences)
    }

    // MARK: Selection: Focus mode and revealed markup

    /// Call whenever the selection changes. Fades everything but the current
    /// sentence or paragraph (Focus mode) and shows the markup of the caret's
    /// lines (rendered view). Only lines whose state changed are restyled.
    public func selectionDidChange(_ selection: NSRange, force: Bool = false) {
        guard let storage else { return }
        let text = storage.mutableString
        let length = text.length
        let newFocus = configuration.focus == .off || length == 0 ? nil : focusTarget(selection: selection, in: text)
        let newReveal = revealTarget(selection: selection, in: text)
        let focusChanged = force || newFocus != focusedRange
        // What shows depends on where the caret is within its line, so any
        // caret move restyles the line(s) it left and entered.
        let revealChanged = force || newReveal != revealedLines || (newReveal != nil && selection != styler.revealRange)
        guard focusChanged || revealChanged else { return }

        let full = NSRange(location: 0, length: length)
        var dirty: NSRange?
        func add(_ range: NSRange?) {
            guard let range else { return }
            let clamped = NSIntersectionRange(range, full)
            dirty = dirty.map { NSUnionRange($0, clamped) } ?? clamped
        }
        if focusChanged {
            switch (focusedRange, newFocus) {
            case let (old?, new?) where !force:
                add(text.paragraphRange(for: old.clamped(to: length)))
                add(text.paragraphRange(for: new))
            case (nil, nil):
                break
            default:
                add(full)
            }
        }
        if revealChanged {
            add(revealedLines.map { text.lineRange(for: $0.clamped(to: length)) })
            add(newReveal)
        }

        focusedRange = newFocus
        styler.focusRange = newFocus
        revealedLines = newReveal
        styler.revealRange = newReveal == nil ? nil : selection

        guard let dirty else { return }
        storage.beginEditing()
        styler.style(storage, range: dirty, fences: fences)
        storage.endEditing()
    }

    /// The lines whose markup shows: the caret's (or the selection's), unless
    /// markup shows everywhere anyway, or nowhere (Preview).
    private func revealTarget(selection: NSRange, in text: NSMutableString) -> NSRange? {
        guard !configuration.showsSyntax, !configuration.preview, text.length > 0 else { return nil }
        return text.lineRange(for: selection.clamped(to: text.length))
    }

    // MARK: Rendered markup: caret, backspace, links, task boxes

    /// Where a selection should really go: a caret never rests inside hidden
    /// block markup (a bullet, task box, heading hashes, quote marker, rule).
    /// `previous` is the selection before a keyboard move; pass nil for clicks
    /// and taps (only the arrow keys step back out of a line).
    public func adjustedSelection(_ selection: NSRange, previous: NSRange?) -> NSRange {
        guard selection.length == 0, configuration.rendersMarkdown, !configuration.preview,
              let storage, storage.length > 0 else { return selection }
        let text = storage.mutableString
        let location = MarkdownEditing.adjustedCaret(selection.location, previous: previous?.length == 0 ? previous?.location : nil,
                                                      in: text, insideFence: isInsideFence(selection.location, in: text))
        return NSRange(location: location, length: 0)
    }

    /// When the caret sits where a line's text starts after hidden markup
    /// (the only place it can be at that end), the start of that line: the
    /// Left arrow then leaves the line instead of entering the markup.
    public func markupLineStart(ifCaretAtHome location: Int) -> Int? {
        guard configuration.rendersMarkdown, !configuration.preview, let storage, storage.length > 0 else { return nil }
        let text = storage.mutableString
        guard let markup = MarkdownEditing.hiddenMarkup(in: text, at: location, insideFence: isInsideFence(location, in: text)),
              markup.home == location, markup.zone.length > 0 else { return nil }
        return markup.line.location
    }

    /// Return continues a list or quote (or ends it on an empty item), but
    /// not inside a code block. Nil means an ordinary line break.
    public func newlineEdit(for selection: NSRange) -> TextEdit? {
        guard let storage else { return nil }
        let text = storage.mutableString
        guard !isInsideFence(selection.location, in: text) else { return nil }
        return MarkdownEditing.newline(in: text, selection: selection)
    }

    /// Tab and Shift-Tab indent and outdent list items, but not inside a code
    /// block. Nil means an ordinary tab.
    public func listShiftEdit(for selection: NSRange, outdent: Bool) -> TextEdit? {
        guard let storage else { return nil }
        let text = storage.mutableString
        guard !isInsideFence(selection.location, in: text) else { return nil }
        return MarkdownEditing.shiftLines(in: text, selection: selection, outdent: outdent, listsOnly: true)
    }

    /// Backspace right after hidden block markup removes it as one unit.
    public func markupDeletion(for selection: NSRange) -> TextEdit? {
        guard configuration.rendersMarkdown, !configuration.preview, let storage, storage.length > 0 else { return nil }
        let text = storage.mutableString
        return MarkdownEditing.deleteMarkup(in: text, selection: selection, insideFence: isInsideFence(selection.location, in: text))
    }

    /// Whether a line starts with a table's `|`.
    private static func isTableRow(_ line: NSRange, in text: NSString) -> Bool {
        var i = line.location
        while i < NSMaxRange(line), text.character(at: i) == 0x20 || text.character(at: i) == 0x09 { i += 1 }
        return i < NSMaxRange(line) && text.character(at: i) == 0x7C
    }

    /// Whether the line at `location` is inside a fenced code block (fence lines included).
    private func isInsideFence(_ location: Int, in text: NSString) -> Bool {
        let lineStart = text.lineRange(for: NSRange(location: min(location, text.length), length: 0)).location
        return fences.contains(lineStart)
    }

    /// The link at a character, and all of its markup.
    public func link(at index: Int) -> (target: MarkdownLinkTarget, range: NSRange)? {
        guard let storage, index >= 0, index < storage.length else { return nil }
        var range = NSRange()
        let line = storage.mutableString.lineRange(for: NSRange(location: index, length: 0))
        guard let target = LinkAttribute.decode(storage.attribute(.minoteLink, at: index, longestEffectiveRange: &range, in: line)) else { return nil }
        return (target, range)
    }

    /// Where a link leads (looking up reference definitions, footnotes, headings).
    public func destination(of target: MarkdownLinkTarget) -> MarkdownLinkDestination? {
        guard let storage else { return nil }
        return MarkdownLinks.resolve(target, in: storage.mutableString)
    }

    /// A short description of a link for the hover hint: its address.
    public func displayAddress(of target: MarkdownLinkTarget) -> String {
        switch destination(of: target) {
        case .external(let url)?:
            return url.scheme == "mailto" ? String(url.absoluteString.dropFirst(7)) : url.absoluteString
        case .file(let path)?:
            return path
        case .anchor(let location)?:
            if case .footnote(let id) = target { return "Footnote \(id)" }
            guard let storage, location < storage.length else { return "Section in this note" }
            let line = storage.mutableString.lineRange(for: NSRange(location: location, length: 0))
            let text = storage.mutableString.substring(with: line).trimmingCharacters(in: .whitespacesAndNewlines)
            let title = MarkdownLinks.headingTitle(String(text.drop { $0 == "#" }))
            return "Section “\(title)”"
        case nil:
            switch target {
            case .url(let url): return url
            case .reference(let label): return "[\(label)] (no definition)"
            case .footnote(let id): return "Footnote \(id) (missing)"
            }
        }
    }

    /// The character under a point in text container coordinates (not the
    /// nearest insertion point: nil between lines or past the end of one).
    public func characterIndex(at point: CGPoint) -> Int? {
        guard let layoutManager, let content = layoutManager.textContentManager,
              let fragment = layoutManager.textLayoutFragment(for: point) else { return nil }
        let frame = fragment.layoutFragmentFrame
        let paragraphStart = content.offset(from: content.documentRange.location, to: fragment.rangeInElement.location)
        let local = CGPoint(x: point.x - frame.minX, y: point.y - frame.minY)
        for line in fragment.textLineFragments {
            let bounds = line.typographicBounds
            guard local.y >= bounds.minY, local.y < bounds.maxY else { continue }
            let x = local.x - bounds.minX
            let index = line.characterIndex(for: CGPoint(x: x, y: local.y - bounds.minY))
            for candidate in [index, index - 1] where candidate >= line.characterRange.location && candidate < NSMaxRange(line.characterRange) {
                let start = line.locationForCharacter(at: candidate).x
                let end = line.locationForCharacter(at: candidate + 1).x
                if x >= min(start, end), x < max(start, end) { return paragraphStart + candidate }
            }
        }
        return nil
    }

    /// The task whose drawn box is at a point (text container coordinates):
    /// the location of its line.
    public func taskBox(at point: CGPoint) -> Int? {
        guard configuration.rendersMarkdown, let layoutManager, let content = layoutManager.textContentManager,
              let fragment = layoutManager.textLayoutFragment(for: point) as? MarkdownLayoutFragment else { return nil }
        let frame = fragment.layoutFragmentFrame
        let local = CGPoint(x: point.x - frame.minX, y: point.y - frame.minY)
        for mark in fragment.marks() {
            guard let box = fragment.checkboxRect(for: mark), box.insetBy(dx: -5, dy: -4).contains(local) else { continue }
            return content.offset(from: content.documentRange.location, to: fragment.rangeInElement.location) + mark.characterOffset
        }
        return nil
    }

    /// Ticks or unticks the task on the line at `location`, leaving the selection where it is.
    public func toggleTaskEdit(at location: Int, keeping selection: NSRange) -> TextEdit? {
        guard let storage, let edit = MarkdownEditing.toggleTaskDone(in: storage.mutableString, selection: NSRange(location: location, length: 0)) else { return nil }
        return TextEdit(edit.replacements, selection: selection)
    }

    // MARK: The library's view of the text

    /// Whether the caret is on (or before) the first non-blank line, which names the note.
    public func isCaretInTitleLine(_ selection: NSRange) -> Bool {
        guard let text = storage?.mutableString else { return true }
        let first = text.rangeOfCharacter(from: CharacterSet.whitespacesAndNewlines.inverted)
        guard first.location != NSNotFound else { return true }
        var contentsEnd = 0
        text.getLineStart(nil, end: nil, contentsEnd: &contentsEnd, for: NSRange(location: first.location, length: 0))
        return selection.location <= contentsEnd
    }

    /// The beginning of the text, enough for the note's title and excerpt,
    /// cut on a character boundary.
    public func titlePrefix() -> String {
        guard let text = storage?.mutableString, text.length > 0 else { return "" }
        let length = min(text.length, NoteNaming.prefixLength)
        return text.substring(with: text.rangeOfComposedCharacterSequences(for: NSRange(location: 0, length: length)))
    }

    private func focusTarget(selection: NSRange, in text: NSMutableString) -> NSRange {
        let caret = min(selection.location, text.length)
        let paragraph = text.paragraphRange(for: NSRange(location: caret, length: 0))
        guard configuration.focus == .sentence, paragraph.length > 0 else { return paragraph }
        var sentence = paragraph
        text.enumerateSubstrings(in: paragraph, options: [.bySentences, .substringNotRequired]) { _, range, enclosing, stop in
            if caret >= enclosing.location, caret <= NSMaxRange(enclosing) {
                sentence = range
                stop.pointee = true
            }
        }
        return sentence
    }
}
