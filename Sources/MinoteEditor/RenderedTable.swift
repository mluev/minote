#if os(macOS)
import AppKit
#else
import UIKit
#endif
import CoreText
import MinoteKit

/// A table drawn in place of its source rows, which the styler hides: each
/// cell's text as styled, wrapped inside columns fitted to the page, over a
/// grid with a shaded header. Each source line carries its part of the table
/// (a `Line`, under `.minoteTable`) and is exactly as tall as that part, so a
/// click on a row lands on that row's source.
public final class RenderedTable: NSObject {
    public struct Row {
        /// One per column, laid out by `Self.textHeight` and `Self.drawText`.
        public let cells: [NSAttributedString]
        /// Each cell's text height at its column's width.
        public let textHeights: [CGFloat]
        /// The tallest cell, with the padding above and below it.
        public let height: CGFloat
    }

    /// The header first, then the body rows.
    public let rows: [Row]
    /// Each column's width, its padding included.
    public let columnWidths: [CGFloat]
    /// Room between a cell's edges and its text.
    public let padding: CGSize
    /// Room above and below the table.
    public let margin: CGFloat

    public var width: CGFloat { columnWidths.reduce(0, +) }

    /// `header` and `body` hold each row's cells as styled on the page (the
    /// markup it hides already gone). The header sets the number of columns:
    /// a shorter row gets empty cells, a longer one loses the extra cells
    /// (as on GitHub).
    public init(header: [NSAttributedString], body: [[NSAttributedString]], alignments: [MarkdownTableAlignment],
                availableWidth: CGFloat, styleSheet sheet: EditorStyleSheet) {
        let columns = max(1, header.count)
        let padding = CGSize(width: sheet.characterWidth.rounded(), height: (sheet.lineHeight * 0.2).rounded())

        let styles = (0..<columns).map { Self.cellStyle($0 < alignments.count ? alignments[$0] : .left, sheet: sheet) }
        let texts: [[NSAttributedString]] = ([header] + body).map { row in
            (0..<columns).map { column in
                let text = NSMutableAttributedString(attributedString: column < row.count ? row[column] : NSAttributedString())
                let all = NSRange(location: 0, length: text.length)
                text.addAttribute(.paragraphStyle, value: styles[column], range: all)
                // String drawing (TextKit 1) lowers text set in a fixed line
                // height; a positive offset lifts it where TextKit 2 puts the
                // page's (whose offset is negative): centered in the line.
                text.addAttribute(.baselineOffset, value: -sheet.baselineOffset, range: all)
                return text
            }
        }

        // Fit the columns to the page: their widest cell on one line if they
        // all fit, or wrapped, never narrower than their longest word unless
        // the page is narrower still. A point of slack keeps text measured
        // one way from wrapping when laid out the other.
        let extra = 2 * padding.width + 1
        var natural = [Double](repeating: extra, count: columns)
        var minimum = [Double](repeating: extra, count: columns)
        for row in texts {
            for (column, text) in row.enumerated() {
                let widths = Self.widths(of: text)
                natural[column] = max(natural[column], widths.line.rounded(.up) + extra)
                minimum[column] = max(minimum[column], widths.longestWord.rounded(.up) + extra)
            }
        }
        let widths = MarkdownTable.fitColumns(natural: natural, minimum: minimum, available: Double(availableWidth))
            .map { CGFloat($0).rounded(.down) }

        rows = texts.map { cells in
            let heights = zip(cells, widths).map { text, width in Self.textHeight(text, width: max(1, width - 2 * padding.width)) }
            return Row(cells: cells, textHeights: heights, height: max(sheet.lineHeight, heights.max() ?? 0) + 2 * padding.height)
        }
        columnWidths = widths
        self.padding = padding
        margin = (sheet.lineHeight * 0.4).rounded()
        super.init()
    }

    /// The source lines' parts, in order: the header, the line under it (the
    /// delimiter row), then the body rows.
    public func lines() -> [Line] {
        [Line(table: self, part: .row(0)), Line(table: self, part: .rule)] + rows.indices.dropFirst().map { Line(table: self, part: .row($0)) }
    }

    /// One source line's part of a drawn table: the value of `.minoteTable`.
    public final class Line: NSObject {
        public enum Part: Equatable, Sendable {
            /// A row of cells: 0 is the header.
            case row(Int)
            /// The line under the header, in place of the delimiter row.
            case rule
        }

        public let table: RenderedTable
        public let part: Part

        init(table: RenderedTable, part: Part) {
            self.table = table
            self.part = part
        }

        private var isFirst: Bool { part == .row(0) }
        private var isLast: Bool {
            switch part {
            case .row(let index): index > 0 && index == table.rows.count - 1
            case .rule: table.rows.count == 1
            }
        }

        /// The source line's height: its part of the table, and the margin
        /// above or below the table when it opens or closes it.
        public var height: CGFloat {
            let own: CGFloat
            switch part {
            case .row(let index): own = table.rows[index].height
            case .rule: own = 1
            }
            return own + (isFirst ? table.margin : 0) + (isLast ? table.margin : 0)
        }

        /// Draws this part with its top left at `origin` (the column's left
        /// edge, the top of the source line) in a flipped context.
        public func draw(at origin: CGPoint, in context: CGContext, grid: CGColor, headerFill: CGColor) {
            let table = table
            let top = origin.y + (isFirst ? table.margin : 0)
            context.setFillColor(grid)
            guard case .row(let index) = part else {
                context.fill(CGRect(x: origin.x, y: top, width: table.width, height: 1))
                return
            }
            let row = table.rows[index]
            let rect = CGRect(x: origin.x, y: top, width: table.width, height: row.height)
            if index == 0 {
                context.setFillColor(headerFill)
                context.fill(rect)
                context.setFillColor(grid)
                context.fill(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: 1))
            } else {
                context.fill(CGRect(x: rect.minX, y: rect.maxY - 1, width: rect.width, height: 1))
            }
            var x = rect.minX
            for (column, width) in table.columnWidths.enumerated() {
                context.fill(CGRect(x: x, y: rect.minY, width: 1, height: rect.height))
                let height = row.textHeights[column]
                let text = CGRect(x: x + table.padding.width, y: rect.minY + ((rect.height - height) / 2).rounded(),
                                  width: max(1, width - 2 * table.padding.width), height: height)
                RenderedTable.drawText(row.cells[column], in: text, context: context)
                x += width
            }
            context.fill(CGRect(x: rect.maxX - 1, y: rect.minY, width: 1, height: rect.height))
        }
    }

    // MARK: Cell text

    // Cell text is laid out the same way (`.usesLineFragmentOrigin`, the
    // column's width) when it is measured and when it is drawn, so it fills
    // exactly the height it was measured to need. (The options' type is named
    // differently in AppKit and UIKit.)

    static func textHeight(_ text: NSAttributedString, width: CGFloat) -> CGFloat {
        guard text.length > 0 else { return 0 }
        return text.boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin], context: nil)
            .height.rounded(.up)
    }

    static func drawText(_ text: NSAttributedString, in rect: CGRect, context: CGContext) {
        guard text.length > 0 else { return }
        #if os(macOS)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        text.draw(with: rect, options: [.usesLineFragmentOrigin], context: nil)
        NSGraphicsContext.restoreGraphicsState()
        #else
        UIGraphicsPushContext(context)
        text.draw(with: rect, options: [.usesLineFragmentOrigin], context: nil)
        UIGraphicsPopContext()
        #endif
    }

    /// The page's line height, aligned like its column.
    private static func cellStyle(_ alignment: MarkdownTableAlignment, sheet: EditorStyleSheet) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = sheet.lineHeight
        style.maximumLineHeight = sheet.lineHeight
        style.lineBreakMode = .byWordWrapping
        switch alignment {
        case .left: style.alignment = .left
        case .center: style.alignment = .center
        case .right: style.alignment = .right
        }
        return style
    }

    /// A cell's width on one line, and its longest word's.
    private static func widths(of text: NSAttributedString) -> (line: CGFloat, longestWord: CGFloat) {
        guard text.length > 0 else { return (0, 0) }
        let line = CTLineCreateWithAttributedString(text)
        let full = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        let string = text.string as NSString
        var longest: CGFloat = 0
        var start: Int?
        for index in 0...string.length {
            let isSpace = index == string.length || string.character(at: index) == 0x20 || string.character(at: index) == 0x09
            if isSpace, let wordStart = start {
                let width = CTLineGetOffsetForStringIndex(line, index, nil) - CTLineGetOffsetForStringIndex(line, wordStart, nil)
                longest = max(longest, width)
                start = nil
            } else if !isSpace, start == nil {
                start = index
            }
        }
        return (full, longest)
    }
}
