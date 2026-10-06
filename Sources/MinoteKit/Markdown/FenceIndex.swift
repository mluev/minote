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
        let length = text.length
        var open: (start: Int, char: UInt16, length: Int)?
        var location = 0
        while location < length {
            var lineEnd = 0, contentsEnd = 0
            text.getLineStart(nil, end: &lineEnd, contentsEnd: &contentsEnd, for: NSRange(location: location, length: 0))
            if Self.mayBeFence(text, from: location, to: contentsEnd),
               let fence = MarkdownLexer.fence(in: Self.characters(text, location..<contentsEnd)) {
                let line = NSRange(location: location, length: lineEnd - location)
                if let current = open {
                    if fence.char == current.char, fence.length >= current.length, fence.isBare {
                        blocks.append(NSRange(location: current.start, length: lineEnd - current.start))
                        fenceLines.append(line)
                        open = nil
                    }
                } else {
                    open = (location, fence.char, fence.length)
                    fenceLines.append(line)
                }
            }
            location = lineEnd
        }
        if let current = open {
            blocks.append(NSRange(location: current.start, length: length - current.start))
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

        let old = Set(previous.blocks.map { HashableRange($0) })
        let new = Set(blocks.map { HashableRange($0) })
        let changed = old.symmetricDifference(new).map(\.range)
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
        var location = range.location
        let end = NSMaxRange(range)
        while location < end {
            var lineEnd = 0, contentsEnd = 0
            text.getLineStart(nil, end: &lineEnd, contentsEnd: &contentsEnd, for: NSRange(location: location, length: 0))
            if mayBeFence(text, from: location, to: contentsEnd),
               MarkdownLexer.fence(in: characters(text, location..<contentsEnd)) != nil {
                return true
            }
            if lineEnd <= location { break }
            location = lineEnd
        }
        return false
    }

    /// Cheap pre-check: up to three spaces, then ``` or ~~~.
    private static func mayBeFence(_ text: NSString, from start: Int, to end: Int) -> Bool {
        var i = start
        while i < end, i - start < 3, text.character(at: i) == 0x20 { i += 1 }
        guard i + 2 < end else { return false }
        let c = text.character(at: i)
        return (c == 0x60 || c == 0x7E) && text.character(at: i + 1) == c && text.character(at: i + 2) == c
    }

    static func characters(_ text: NSString, _ range: Range<Int>) -> [UInt16] {
        var buffer = [UInt16](repeating: 0, count: range.count)
        text.getCharacters(&buffer, range: NSRange(location: range.lowerBound, length: range.count))
        return buffer
    }
}

private struct HashableRange: Hashable {
    let location: Int
    let length: Int

    init(_ range: NSRange) {
        location = range.location
        length = range.length
    }

    var range: NSRange { NSRange(location: location, length: length) }
}
