import Foundation

/// How a table column lines up, from its delimiter row: `:--`, `:-:`, `--:`.
public enum MarkdownTableAlignment: Equatable, Sendable {
    case left, center, right
}

/// The geometry of a GFM table: its rows' cells and how much room each needs
/// so that the columns line up.
public enum MarkdownTable {
    /// Room added on either side of a cell's text.
    public struct CellPadding: Equatable, Sendable {
        public var leading: Double
        public var trailing: Double

        public init(leading: Double, trailing: Double) {
            self.leading = leading
            self.trailing = trailing
        }
    }

    /// A row's cells, spaces included: what lies between consecutive pipes,
    /// and after the last one when the row doesn't close with a pipe.
    public static func cells(of line: MarkdownLine, in chars: [UInt16]) -> [Range<Int>] {
        let pipes = line.tablePipes
        var cells = zip(pipes, pipes.dropFirst()).map { $0 + 1..<$1 }
        if let last = pipes.last, chars[(last + 1)...].contains(where: { $0 != .space && $0 != .tab }) {
            cells.append(last + 1..<chars.count)
        }
        return cells
    }

    /// Each column's alignment, from the delimiter row under a table's header.
    public static func alignments(delimiterRow line: MarkdownLine, in chars: [UInt16]) -> [MarkdownTableAlignment] {
        cells(of: line, in: chars).map { cell in
            let marks = chars[cell].filter { $0 != .space && $0 != .tab }
            switch (marks.first == .colon, marks.count > 1 && marks.last == .colon) {
            case (true, true): return .center
            case (false, true): return .right
            default: return .left
            }
        }
    }

    /// The padding that makes every column as wide as its widest cell.
    /// `widths[row][column]` are the cells' widths as drawn; a row with fewer
    /// cells pads the ones it has.
    public static func padding(widths: [[Double]], alignments: [MarkdownTableAlignment]) -> [[CellPadding]] {
        var columns: [Double] = []
        for row in widths {
            for (column, width) in row.enumerated() {
                if column < columns.count {
                    columns[column] = max(columns[column], width)
                } else {
                    columns.append(width)
                }
            }
        }
        return widths.map { row in
            row.enumerated().map { column, width in
                let extra = columns[column] - width
                switch column < alignments.count ? alignments[column] : .left {
                case .left: return CellPadding(leading: 0, trailing: extra)
                case .right: return CellPadding(leading: extra, trailing: 0)
                case .center: return CellPadding(leading: extra / 2, trailing: extra - extra / 2)
                }
            }
        }
    }
}
