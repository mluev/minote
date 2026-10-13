import CoreGraphics
import Foundation

/// Where the outline beside the page puts things, collapsed (a rail of dashes,
/// one per heading) and expanded (a card listing them). Coordinates are the
/// overlay's, flipped (y grows down). The same values place the drawing and
/// answer hit tests, so what is clicked is always what is shown.
public struct OutlineLayout: Equatable, Sendable {
    // MARK: Metrics

    public static let dashThickness: CGFloat = 2
    /// Dash widths by level, relative to the outline's highest level.
    public static let dashWidths: [CGFloat] = [18, 13, 9, 6]
    public static let maxDashSpacing: CGFloat = 10
    public static let minDashSpacing: CGFloat = 4
    /// The rail takes at most this share of the page's height.
    static let railHeightShare: CGFloat = 0.7
    /// Room kept between the text column and the rail.
    static let textGap: CGFloat = 10
    static let maxRailInset: CGFloat = 10
    static let minRailInset: CGFloat = 2
    /// Below this much room the rail is hidden rather than squeezed.
    static let minDashRoom: CGFloat = 8

    public static let cardMaxWidth: CGFloat = 264
    public static let rowHeight: CGFloat = 28
    public static let cardPadding: CGFloat = 8
    public static let cardCornerRadius: CGFloat = 12
    /// The card reaches this far past the rail's right edge.
    static let cardOverhang: CGFloat = 8
    /// The hover plate's inset from the card's sides.
    static let plateInset: CGFloat = 6
    /// Room left of every row's text for the current heading's dot.
    static let dotGutter: CGFloat = 18
    public static let dotSize: CGFloat = 6
    static let indentStep: CGFloat = 14
    static let maxIndentSteps = 3
    static let textTrailingPadding: CGFloat = 10

    // MARK: Layout

    /// The heading count.
    public let count: Int
    /// Nothing to show: fewer than two headings, or no room beside the text.
    public let isHidden: Bool
    /// Headings that have a dash. All of them, unless the outline is too long
    /// for the rail: then a window around the current heading.
    public let dashRange: Range<Int>
    public let dashSpacing: CGFloat
    /// 1, or less where the margin is narrow.
    public let dashScale: CGFloat
    /// Right edge of the dashes.
    public let railRight: CGFloat
    public let railCenterY: CGFloat
    public let cardRect: CGRect
    /// The rows and the card's padding: taller than the card when the list scrolls.
    public let contentHeight: CGFloat
    /// Levels relative to the highest, capped at the deepest indent.
    let depths: [Int]

    /// - Parameters:
    ///   - levels: each heading's level, in order.
    ///   - bounds: the area the outline may use (the visible page beside the
    ///     scroller, below the toolbar).
    ///   - textMaxX: the text column's right edge.
    ///   - anchor: the heading a too-long rail centers its window on.
    public init(levels: [Int], bounds: CGRect, textMaxX: CGFloat,
                topReserve: CGFloat = 12, bottomReserve: CGFloat = 12, anchor: Int? = nil) {
        count = levels.count
        let top = bounds.minY + topReserve
        let bottom = bounds.maxY - bottomReserve
        let available = bottom - top

        let highest = levels.min() ?? 1
        depths = levels.map { min(max(0, $0 - highest), Self.maxIndentSteps) }

        // Horizontal: as far right as possible, leaving the scroller its strip,
        // and never over the text.
        let free = bounds.maxX - (textMaxX + Self.textGap)
        let inset = min(Self.maxRailInset, max(Self.minRailInset, (free - Self.dashWidths[0]) / 2))
        railRight = bounds.maxX - inset
        let room = railRight - (textMaxX + Self.textGap)
        dashScale = min(1, max(0, room / Self.dashWidths[0]))
        isHidden = count < 2 || room < Self.minDashRoom || available < 4 * Self.maxDashSpacing

        // Vertical: centered on the page; a long outline packs its dashes
        // closer, and past the minimum spacing shows a window of them.
        railCenterY = ((top + bottom) / 2).rounded()
        let railHeight = max(0, available * Self.railHeightShare)
        if count < 2 {
            dashSpacing = Self.maxDashSpacing
            dashRange = 0..<count
        } else if railHeight / CGFloat(count - 1) >= Self.minDashSpacing {
            dashSpacing = min(Self.maxDashSpacing, (railHeight / CGFloat(count - 1) * 2).rounded(.down) / 2)
            dashRange = 0..<count
        } else {
            dashSpacing = Self.minDashSpacing
            let shown = max(2, Int(railHeight / Self.minDashSpacing) + 1)
            let start = min(max(0, (anchor ?? 0) - shown / 2), count - shown)
            dashRange = start..<(start + shown)
        }

        // The card: centered on the rail, inside the page.
        contentHeight = CGFloat(count) * Self.rowHeight + 2 * Self.cardPadding
        let height = max(0, min(contentHeight, available))
        let cardTop = min(max(top, (railCenterY - height / 2).rounded()), bottom - height)
        let cardRight = min(bounds.maxX, railRight + Self.cardOverhang)
        let cardLeft = max(bounds.minX + Self.cardOverhang, cardRight - Self.cardMaxWidth)
        cardRect = CGRect(x: cardLeft, y: cardTop, width: max(0, cardRight - cardLeft), height: height)
    }

    // MARK: Rail

    /// The middle of a heading's dash. Headings outside the window sit at its ends.
    public func dashY(_ index: Int) -> CGFloat {
        guard !dashRange.isEmpty else { return railCenterY }
        let first = railCenterY - CGFloat(dashRange.count - 1) * dashSpacing / 2
        let clamped = min(max(index, dashRange.lowerBound), dashRange.upperBound - 1)
        return (first + CGFloat(clamped - dashRange.lowerBound) * dashSpacing).rounded()
    }

    public func dashWidth(_ index: Int) -> CGFloat {
        (Self.dashWidths[depths[index]] * dashScale).rounded()
    }

    public func dashRect(_ index: Int) -> CGRect {
        let width = dashWidth(index)
        return CGRect(x: railRight - width, y: dashY(index) - Self.dashThickness / 2, width: width, height: Self.dashThickness)
    }

    /// 1 for a dash in the window, fading toward the window's ends when the
    /// outline goes on beyond them, 0 outside it.
    public func dashOpacity(_ index: Int) -> CGFloat {
        guard dashRange.contains(index) else { return 0 }
        var opacity: CGFloat = 1
        let fadeLength = 3
        if dashRange.lowerBound > 0 {
            opacity = min(opacity, CGFloat(index - dashRange.lowerBound + 1) / CGFloat(fadeLength + 1))
        }
        if dashRange.upperBound < count {
            opacity = min(opacity, CGFloat(dashRange.upperBound - index) / CGFloat(fadeLength + 1))
        }
        return opacity
    }

    /// The dashes' bounds.
    public var railRect: CGRect {
        guard !dashRange.isEmpty else { return CGRect(x: railRight, y: railCenterY, width: 0, height: 0) }
        let widest = dashRange.map(dashWidth).max() ?? 0
        let top = dashY(dashRange.lowerBound) - Self.dashThickness / 2
        let bottom = dashY(dashRange.upperBound - 1) + Self.dashThickness / 2
        return CGRect(x: railRight - widest, y: top, width: widest, height: bottom - top)
    }

    /// Where hovering the rail opens the card: the dashes, with some room to
    /// spare, but never over the text.
    public var railHitRect: CGRect {
        let rail = railRect
        let left = max(rail.minX - 12, railRight - Self.dashWidths[0] - 12)
        let right = railRight + Self.minRailInset
        return CGRect(x: left, y: rail.minY - 10, width: right - left, height: rail.height + 20)
    }

    // MARK: Card

    public var maxListOffset: CGFloat { max(0, contentHeight - cardRect.height) }

    public func clampedListOffset(_ offset: CGFloat) -> CGFloat {
        min(max(0, offset), maxListOffset)
    }

    /// The list offset that puts a heading's row where its dash is (when the
    /// list scrolls), so opening the card moves it as little as possible.
    public func listOffset(placing index: Int?) -> CGFloat {
        guard let index, maxListOffset > 0 else { return 0 }
        let rowMid = cardRect.minY + Self.cardPadding + (CGFloat(index) + 0.5) * Self.rowHeight
        return clampedListOffset((rowMid - dashY(index)).rounded())
    }

    /// A row's hover plate.
    public func rowRect(_ index: Int, listOffset: CGFloat) -> CGRect {
        CGRect(x: cardRect.minX + Self.plateInset,
               y: cardRect.minY + Self.cardPadding + CGFloat(index) * Self.rowHeight - listOffset,
               width: max(0, cardRect.width - 2 * Self.plateInset), height: Self.rowHeight)
    }

    /// Where a row's title is set.
    public func textRect(_ index: Int, listOffset: CGFloat) -> CGRect {
        let row = rowRect(index, listOffset: listOffset)
        let left = row.minX + Self.dotGutter + CGFloat(depths[index]) * Self.indentStep
        return CGRect(x: left, y: row.minY, width: max(0, row.maxX - Self.textTrailingPadding - left), height: row.height)
    }

    /// The current heading's dot, left of its title.
    public func dotRect(_ index: Int, listOffset: CGFloat) -> CGRect {
        let text = textRect(index, listOffset: listOffset)
        let size = Self.dotSize
        return CGRect(x: text.minX - 9 - size / 2, y: text.midY - size / 2, width: size, height: size)
    }

    /// Rows at least partly inside the card.
    public func visibleRows(listOffset: CGFloat) -> Range<Int> {
        guard count > 0, cardRect.height > 0 else { return 0..<0 }
        let start = Int(((listOffset - Self.cardPadding) / Self.rowHeight).rounded(.down))
        let end = Int(((listOffset + cardRect.height - Self.cardPadding) / Self.rowHeight).rounded(.up))
        return max(0, start)..<min(count, max(0, end))
    }

    /// The row under a point inside the card.
    public func rowIndex(at point: CGPoint, listOffset: CGFloat) -> Int? {
        guard cardRect.contains(point) else { return nil }
        let y = point.y - cardRect.minY - Self.cardPadding + listOffset
        guard y >= 0 else { return nil }
        let index = Int(y / Self.rowHeight)
        return index < count ? index : nil
    }

    /// The dash nearest a point on the rail (where the card opens from).
    public func dashIndex(near y: CGFloat) -> Int? {
        guard !dashRange.isEmpty else { return nil }
        let first = dashY(dashRange.lowerBound)
        let offset = Int(((y - first) / dashSpacing).rounded())
        return min(max(dashRange.lowerBound + offset, dashRange.lowerBound), dashRange.upperBound - 1)
    }
}
