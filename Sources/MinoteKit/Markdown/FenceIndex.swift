import Foundation

/// Knows which parts of a document are fenced code blocks. Typing usually
/// only shifts the known blocks; the document is rescanned only when an edit
/// touches a fence line.
public struct FenceIndex: Sendable {
    /// Fenced blocks, from the start of the opening fence line to the end of the
    /// closing fence line (or the end of the document when unclosed). Sorted.
    public private(set) var blocks: [NSRange] = []
    /// The opening and closing fence lines themselves, including terminators.
    private var fenceLines: [NSRange] = []

    public init() {}

    public init(text: NSString) {
        rebuild(text)
    }

    /// Whether the character at `location` is inside a fenced block.
    public func contains(_ location: Int) -> Bool {
        block(containing: location) != nil
    }

    /// The fenced block containing `location`, from its opening fence line.
    public func block(containing location: Int) -> NSRange? {
        var low = 0, high = blocks.count - 1
        while low <= high {
            let mid = (low + high) / 2
            let block = blocks[mid]
            if location < block.location {
                high = mid - 1
            } else if location >= NSMaxRange(block) {
                low = mid + 1
            } else {
                return block
            }
        }
        return nil
    }

    public mutating func rebuild(_ text: NSString) {
        blocks.removeAll(keepingCapacity: true)
        fenceLines.removeAll(keepingCapacity: true)
        var open: (start: Int, char: UInt16, length: Int)?
        text.forEachLine(in: NSRange(location: 0, length: text.length)) { start, contentsEnd, end, _ in
            guard let fence = Self.fence(text, from: start, to: contentsEnd) else { return }
            let line = NSRange(location: start, length: end - start)
            if let current = open {
                guard fence.char == current.char, fence.length >= current.length, fence.isBare else { return }
                blocks.append(NSRange(location: current.start, length: end - current.start))
                fenceLines.append(line)
                open = nil
            } else {
                open = (start, fence.char, fence.length)
                fenceLines.append(line)
            }
        }
        if let current = open {
            blocks.append(NSRange(location: current.start, length: text.length - current.start))
        }
    }

    /// Updates the index after `editedRange` (new coordinates) replaced text,
    /// changing the length by `delta`. Returns the range whose fence state
    /// changed and needs restyling, beyond the edited lines themselves.
    public mutating func update(_ text: NSString, editedRange: NSRange, changeInLength delta: Int) -> NSRange? {
        let start = editedRange.location
        let oldEnd = start + editedRange.length - delta

        let touchesFenceLine = fenceLines.contains { $0.location <= oldEnd && NSMaxRange($0) >= start }
        let editedLines = text.lineRange(for: editedRange)
        let createsFenceLine = Self.containsFenceLine(text, in: editedLines)

        guard touchesFenceLine || createsFenceLine else {
            shift(from: start, oldEnd: oldEnd, by: delta)
            return nil
        }

        var previous = self
        previous.shift(from: start, oldEnd: oldEnd, by: delta)
        rebuild(text)

        let changed = Set(previous.blocks).symmetricDifference(blocks)
        guard var union = changed.first else { return nil }
        for range in changed.dropFirst() { union = NSUnionRange(union, range) }
        let clampedEnd = min(NSMaxRange(union), text.length)
        return NSRange(location: min(union.location, clampedEnd), length: max(0, clampedEnd - union.location))
    }

    /// Moves ranges after an edit that didn't touch any fence line.
    private mutating func shift(from start: Int, oldEnd: Int, by delta: Int) {
        guard delta != 0 else { return }
        func adjust(_ range: NSRange) -> NSRange {
            if range.location >= oldEnd {
                return NSRange(location: range.location + delta, length: range.length)
            }
            if NSMaxRange(range) >= start {
                return NSRange(location: range.location, length: max(0, range.length + delta))
            }
            return range
        }
        blocks = blocks.map(adjust)
        fenceLines = fenceLines.map(adjust)
    }

    private static func containsFenceLine(_ text: NSString, in range: NSRange) -> Bool {
        var found = false
        text.forEachLine(in: range) { start, contentsEnd, _, stop in
            found = fence(text, from: start, to: contentsEnd) != nil
            stop = found
        }
        return found
    }

    /// The fence on a line, after a cheap pre-check (up to three spaces, then ``` or ~~~).
    private static func fence(_ text: NSString, from start: Int, to end: Int) -> (char: UInt16, length: Int, isBare: Bool)? {
        var i = start
        while i < end, i - start < 3, text.character(at: i) == .space { i += 1 }
        guard i + 2 < end else { return nil }
        let c = text.character(at: i)
        guard (c == .backtick || c == .tilde) && text.character(at: i + 1) == c && text.character(at: i + 2) == c else { return nil }
        return MarkdownLexer.fence(in: text.characters(in: start..<end))
    }
}
