import CoreGraphics
import Foundation

/// How the outline turns from its rail of dashes into the card and back. One
/// number, `progress` (0 = rail, 1 = card), places everything: the card
/// grows out of the rail, each dash travels to its row and stretches into the
/// line its title will take while the title fades in, and the current dash
/// becomes the dot beside its row. Rows set off one after another, rippling
/// out from the dash under the pointer.
public enum OutlineMotion {
    /// Progress units between neighboring rows setting off.
    static let staggerStep: CGFloat = 0.03
    /// The last row sets off this late.
    static let maxStagger: CGFloat = 0.18
    /// A dash fades out over this part of its row's progress.
    static let dashFade: ClosedRange<CGFloat> = 0.1...0.6
    /// A title fades in (and sharpens) over this part.
    static let textFade: ClosedRange<CGFloat> = 0.35...1
    public static let maxBlur: CGFloat = 4
    /// A title slides in from the rail's side by this much.
    static let textSlide: CGFloat = 10
    /// The card's paper fades in over this part of the progress.
    static let cardFade: ClosedRange<CGFloat> = 0...0.5
    /// How far the card's starting shape reaches around the dashes.
    static let railOutset: CGFloat = 6
    static let railCornerRadius: CGFloat = 4

    /// A drawn element: where, how opaque, how blurred.
    public struct Element: Equatable, Sendable {
        public var rect: CGRect
        public var opacity: CGFloat
        public var blur: CGFloat = 0
        public var cornerRadius: CGFloat = 0
    }

    /// One heading's dash and title.
    public struct Row: Equatable, Sendable {
        public var dash: Element
        public var text: Element
    }

    /// The current heading's mark: a bright dash on the rail, the dot in the card.
    public struct Marker: Equatable, Sendable {
        public var shape: Element
        /// 0 = the rail's ink, 1 = the accent.
        public var accent: CGFloat
    }

    // MARK: Card

    public static func card(_ layout: OutlineLayout, progress: CGFloat, reduceMotion: Bool = false) -> Element {
        let p = clamp(progress)
        let opacity = smoothstep(cardFade, p)
        guard !reduceMotion else {
            return Element(rect: layout.cardRect, opacity: p, cornerRadius: OutlineLayout.cardCornerRadius)
        }
        let start = layout.railRect.insetBy(dx: -railOutset, dy: -railOutset)
        let end = layout.cardRect
        // The card widens ahead of the rows, so titles never appear cut off
        // by its edge; it grows taller with them.
        let wide = 1 - pow(1 - p, 3)
        let rect = CGRect(x: lerp(start.minX, end.minX, wide), y: lerp(start.minY, end.minY, p),
                          width: lerp(start.width, end.width, wide), height: lerp(start.height, end.height, p))
        return Element(rect: rect, opacity: opacity,
                       cornerRadius: lerp(railCornerRadius, OutlineLayout.cardCornerRadius, p))
    }

    /// How far a row is along, given the whole morph's progress: rows further
    /// from `origin` (the row the card opens from) set off later. Every row is
    /// at 0 when progress is 0 and at 1 when it is 1.
    public static func rowProgress(_ index: Int, origin: Int, progress: CGFloat) -> CGFloat {
        let delay = min(maxStagger, staggerStep * CGFloat(abs(index - origin)))
        return clamp((clamp(progress) - delay) / (1 - maxStagger))
    }

    // MARK: Rows

    public static func row(_ index: Int, in layout: OutlineLayout, progress: CGFloat, origin: Int,
                           listOffset: CGFloat, reduceMotion: Bool = false) -> Row {
        let finalText = layout.textRect(index, listOffset: listOffset)
        let collapsedDash = layout.dashRect(index)
        let dashOpacity = layout.dashOpacity(index)
        guard !reduceMotion else {
            let p = clamp(progress)
            return Row(dash: Element(rect: collapsedDash, opacity: dashOpacity * (1 - p), cornerRadius: collapsedDash.height / 2),
                       text: Element(rect: finalText, opacity: p))
        }
        let t = rowProgress(index, origin: origin, progress: progress)
        let midY = lerp(layout.dashY(index), finalText.midY, t)

        // The dash keeps its right end and stretches left over the width the
        // title will take, fading as the title appears.
        let left = lerp(collapsedDash.minX, finalText.minX, t)
        let dashRect = CGRect(x: left, y: midY - collapsedDash.height / 2,
                              width: max(0, collapsedDash.maxX - left), height: collapsedDash.height)
        let dash = Element(rect: dashRect, opacity: dashOpacity * (1 - smoothstep(dashFade, t)),
                           cornerRadius: collapsedDash.height / 2)

        let shown = smoothstep(textFade, t)
        let textRect = CGRect(x: finalText.minX + (1 - t) * textSlide, y: midY - finalText.height / 2,
                              width: finalText.width, height: finalText.height)
        return Row(dash: dash, text: Element(rect: textRect, opacity: shown, blur: (1 - shown) * maxBlur))
    }

    // MARK: Current heading

    public static func marker(_ index: Int, in layout: OutlineLayout, progress: CGFloat, origin: Int,
                              listOffset: CGFloat, reduceMotion: Bool = false) -> Marker {
        let dash = layout.dashRect(index)
        let dot = layout.dotRect(index, listOffset: listOffset)
        let inWindow = layout.dashRange.contains(index)
        guard !reduceMotion else {
            // Out on the rail, then in on the card.
            let p = clamp(progress)
            if p < 0.5 {
                return Marker(shape: Element(rect: dash, opacity: inWindow ? 1 - 2 * p : 0, cornerRadius: dash.height / 2), accent: 0)
            }
            return Marker(shape: Element(rect: dot, opacity: 2 * p - 1, cornerRadius: dot.height / 2), accent: 1)
        }
        let t = rowProgress(index, origin: origin, progress: progress)
        // Sideways the dot leads, reaching its place left of the title
        // before the title appears, so it never crosses the text.
        let across = 1 - pow(1 - t, 4)
        let rect = CGRect(x: lerp(dash.minX, dot.minX, across), y: lerp(dash.minY, dot.minY, t),
                          width: lerp(dash.width, dot.width, across), height: lerp(dash.height, dot.height, t))
        return Marker(shape: Element(rect: rect, opacity: inWindow ? 1 : t, cornerRadius: min(rect.width, rect.height) / 2),
                      accent: smoothstep(0.2...0.9, t))
    }

    /// How much of a row's hover plate shows: only once the card has settled.
    public static func plateVisibility(progress: CGFloat) -> CGFloat {
        smoothstep(0.85...1, clamp(progress))
    }

    // MARK: Math

    static func clamp(_ value: CGFloat) -> CGFloat { min(1, max(0, value)) }

    /// Exactly `a` at 0 and `b` at 1, so the morph ends where the layout says.
    static func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat {
        if t <= 0 { return a }
        if t >= 1 { return b }
        return a + (b - a) * t
    }

    static func lerp(_ a: CGRect, _ b: CGRect, _ t: CGFloat) -> CGRect {
        CGRect(x: lerp(a.minX, b.minX, t), y: lerp(a.minY, b.minY, t),
               width: lerp(a.width, b.width, t), height: lerp(a.height, b.height, t))
    }

    /// 0 below the range, 1 above, a smooth S-curve in between.
    static func smoothstep(_ range: ClosedRange<CGFloat>, _ value: CGFloat) -> CGFloat {
        let t = clamp((value - range.lowerBound) / (range.upperBound - range.lowerBound))
        return t * t * (3 - 2 * t)
    }
}
