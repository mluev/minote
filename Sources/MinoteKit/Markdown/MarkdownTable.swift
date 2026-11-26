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

    /// Column widths for a table drawn in `available` room: each column's
    /// `natural` width (its widest cell on one line) when they all fit.
    /// Otherwise the way browsers fit a table, with one refinement: a column
    /// no wider than an even share of the room keeps its natural width (a
    /// short column never wraps). The others get their `minimum` (their
    /// longest word, capped at an even share so one long word can't starve
    /// the rest) plus the room left, shared by how much each still lacks.
    /// The widths never add up to more than `available`.
    public static func fitColumns(natural: [Double], minimum: [Double], available: Double) -> [Double] {
        let natural = natural.map { max(0, $0) }
        let room = max(0, available)
        guard natural.reduce(0, +) > room else { return natural }
        let share = room / Double(natural.count)
        let lower = natural.indices.map { min(natural[$0], max(0, $0 < minimum.count ? minimum[$0] : 0), share) }

        // Keeping a short column leaves the others at least an even share
        // each, so their capped minimums always fit in what's left.
        var kept = Set<Int>()
        var left = room
        while true {
            let others = natural.indices.filter { !kept.contains($0) }
            let short = others.filter { natural[$0] <= left / Double(others.count) }
            guard !short.isEmpty, short.count < others.count else { break }
            kept.formUnion(short)
            left -= short.reduce(0) { $0 + natural[$1] }
        }
        let others = natural.indices.filter { !kept.contains($0) }
        let floor = others.reduce(0) { $0 + lower[$1] }
        let lacking = others.reduce(0) { $0 + natural[$1] - lower[$1] }
        let fraction = lacking > 0 ? max(0, left - floor) / lacking : 0
        return natural.indices.map { column in
            kept.contains(column) ? natural[column] : lower[column] + (natural[column] - lower[column]) * fraction
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
