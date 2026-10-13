import SwiftUI

/// Draws the outline beside the page at one point of its morph: the rail of
/// dashes (`progress` 0), the card of titles (1), or anything in between.
/// Purely a picture: where everything goes comes from `OutlineMotion`, and
/// the host handles the pointer with the same `OutlineLayout`.
public struct OutlineRailView: View, Animatable {
    public var layout: OutlineLayout
    public var titles: [String]
    public var ids: [String]
    /// The heading being read.
    public var active: Int?
    /// The row whose plate shows (under the pointer), and how strongly
    /// (1 hovered, more while pressed, 0 none).
    public var plate: Int?
    public var plateStrength: CGFloat
    public var progress: CGFloat
    /// The row the card opened from.
    public var origin: Int
    public var listOffset: CGFloat
    public var reduceMotion: Bool
    public var palette: EditorPalette

    public init(layout: OutlineLayout, titles: [String], ids: [String], active: Int?, plate: Int?, plateStrength: CGFloat,
                progress: CGFloat, origin: Int, listOffset: CGFloat, reduceMotion: Bool, palette: EditorPalette) {
        self.layout = layout
        self.titles = titles
        self.ids = ids
        self.active = active
        self.plate = plate
        self.plateStrength = plateStrength
        self.progress = progress
        self.origin = origin
        self.listOffset = listOffset
        self.reduceMotion = reduceMotion
        self.palette = palette
    }

    nonisolated public var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    private struct Item: Identifiable {
        let id: String
        let index: Int
    }

    public var body: some View {
        let card = OutlineMotion.card(layout, progress: progress, reduceMotion: reduceMotion)
        let visibleRows = progress > 0 ? layout.visibleRows(listOffset: listOffset) : 0..<0
        let drawn = Set(layout.dashRange).union(visibleRows).sorted()
        let items = drawn.filter { $0 < ids.count }.map { Item(id: ids[$0], index: $0) }

        ZStack(alignment: .topLeading) {
            cardBackground(card)
            ZStack(alignment: .topLeading) {
                plateView(visibleRows: visibleRows)
                ForEach(items) { item in
                    row(item.index, showsText: visibleRows.contains(item.index))
                }
                if let active, active < layout.count {
                    marker(active)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .mask(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: card.cornerRadius, style: .continuous)
                    .frame(width: card.rect.width, height: card.rect.height)
                    .offset(x: card.rect.minX, y: card.rect.minY)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: Parts

    private func cardBackground(_ card: OutlineMotion.Element) -> some View {
        let shape = RoundedRectangle(cornerRadius: card.cornerRadius, style: .continuous)
        return shape
            .fill(Color(platform: OutlineColors.card(palette)))
            .overlay(shape.strokeBorder(Color(platform: OutlineColors.separator), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.16), radius: 18, y: 6)
            .frame(width: card.rect.width, height: card.rect.height)
            .opacity(card.opacity)
            .offset(x: card.rect.minX, y: card.rect.minY)
    }

    @ViewBuilder
    private func plateView(visibleRows: Range<Int>) -> some View {
        if let plate, visibleRows.contains(plate) {
            let rect = layout.rowRect(plate, listOffset: listOffset)
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color(platform: palette.text).opacity(0.07 * plateStrength))
                .frame(width: rect.width, height: rect.height)
                .opacity(OutlineMotion.plateVisibility(progress: progress))
                .offset(x: rect.minX, y: rect.minY)
        }
    }

    private func row(_ index: Int, showsText: Bool) -> some View {
        let state = OutlineMotion.row(index, in: layout, progress: progress, origin: origin,
                                      listOffset: listOffset, reduceMotion: reduceMotion)
        let isActive = index == active
        return ZStack(alignment: .topLeading) {
            Capsule()
                .fill(Color(platform: palette.faded))
                .frame(width: state.dash.rect.width, height: state.dash.rect.height)
                .opacity(state.dash.opacity)
                .offset(x: state.dash.rect.minX, y: state.dash.rect.minY)
            if showsText {
                Text(titles[index])
                    .font(.system(size: 13, weight: isActive ? .medium : .regular))
                    .foregroundStyle(Color(platform: isActive ? palette.text : palette.quote))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: state.text.rect.width, height: state.text.rect.height, alignment: .leading)
                    .blur(radius: state.text.blur)
                    .opacity(state.text.opacity)
                    .offset(x: state.text.rect.minX, y: state.text.rect.minY)
            }
        }
    }

    private func marker(_ index: Int) -> some View {
        let marker = OutlineMotion.marker(index, in: layout, progress: progress, origin: origin,
                                          listOffset: listOffset, reduceMotion: reduceMotion)
        let rect = marker.shape.rect
        return ZStack {
            Capsule().fill(Color(platform: palette.text)).opacity(1 - marker.accent)
            Capsule().fill(Color(platform: EditorTheme.caret)).opacity(marker.accent)
        }
        .frame(width: rect.width, height: rect.height)
        .opacity(marker.shape.opacity)
        .offset(x: rect.minX, y: rect.minY)
    }
}

/// The outline card's own colors, derived from the page's.
public enum OutlineColors {
    /// The page's paper, a shade toward the ink (like the link hint's plate).
    public static func card(_ palette: EditorPalette) -> PlatformColor {
        palette.paper == .sepia ? sepiaCard : standardCard
    }

    private static let standardCard = tinted(EditorPalette.standard.background, name: "MinoteOutlineCard")
    private static let sepiaCard = tinted(EditorPalette.sepia.background, name: "MinoteOutlineCardSepia")

    private static func tinted(_ paper: PlatformColor, name: String) -> PlatformColor {
        #if os(macOS)
        return NSColor(name: name) { appearance in
            var color = paper
            appearance.performAsCurrentDrawingAppearance {
                color = paper.blended(withFraction: 0.06, of: .labelColor) ?? paper
            }
            return color
        }
        #else
        return UIColor { traits in
            let resolvedPaper = paper.resolvedColor(with: traits)
            let ink = UIColor.label.resolvedColor(with: traits)
            var (r1, g1, b1, a1): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
            var (r2, g2, b2, a2): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
            resolvedPaper.getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
            ink.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
            let f: CGFloat = 0.06
            return UIColor(red: r1 + (r2 - r1) * f, green: g1 + (g2 - g1) * f, blue: b1 + (b2 - b1) * f, alpha: 1)
        }
        #endif
    }

    public static var separator: PlatformColor {
        #if os(macOS)
        .separatorColor
        #else
        .separator
        #endif
    }
}

extension Color {
    init(platform color: PlatformColor) {
        #if os(macOS)
        self.init(nsColor: color)
        #else
        self.init(uiColor: color)
        #endif
    }
}
