import Foundation

extension NSString {
    /// Calls `body` for each line touching `range` (UTF-16 offsets): where it
    /// starts, where its contents end and where it ends after its terminator.
    /// An empty range at the end of the text still visits its (empty) line.
    public func forEachLine(in range: NSRange, _ body: (_ start: Int, _ contentsEnd: Int, _ end: Int, _ stop: inout Bool) -> Void) {
        let block = lineRange(for: range)
        var location = block.location
        var stop = false
        repeat {
            var end = 0, contentsEnd = 0
            getLineStart(nil, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: location, length: 0))
            body(location, contentsEnd, end, &stop)
            if stop || end <= location { return }
            location = end
        } while location < NSMaxRange(block)
    }

    /// The UTF-16 code units in `range`.
    public func characters(in range: Range<Int>) -> [UInt16] {
        var buffer = [UInt16](repeating: 0, count: range.count)
        getCharacters(&buffer, range: NSRange(location: range.lowerBound, length: range.count))
        return buffer
    }
}

extension NSRange {
    /// The part of the range inside a text of `length` UTF-16 units.
    public func clamped(to length: Int) -> NSRange {
        let start = Swift.min(location, length)
        return NSRange(location: start, length: Swift.min(self.length, length - start))
    }
}
