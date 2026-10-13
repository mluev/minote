import CoreGraphics
import Foundation

/// Which section the reader is in, and where a heading lands when the outline
/// takes the page to it.
public enum OutlineScrolling {
    /// The line that decides the current section: a heading at or above it
    /// is the one being read. It rests where a jumped-to heading lands (plus
    /// a line, so that heading counts). Over the last screen of scrolling it
    /// drifts to the bottom of the page, so headings too close to the end to
    /// ever reach the top can become current too.
    /// - Parameters:
    ///   - visibleTop: the top of the visible page (below the toolbar).
    ///   - landing: how far below `visibleTop` a jumped-to heading lands.
    ///   - remainingScroll: how much further the page can scroll down.
    ///   - scrollRange: how far the page scrolls in all.
    public static func readingLineY(visibleTop: CGFloat, visibleHeight: CGFloat, landing: CGFloat, lineHeight: CGFloat,
                                    remainingScroll: CGFloat, scrollRange: CGFloat) -> CGFloat {
        let resting = visibleTop + landing + lineHeight
        let bottom = visibleTop + visibleHeight - lineHeight
        let window = min(scrollRange, visibleHeight)
        guard window > 0, bottom > resting else { return resting }
        let drift = OutlineMotion.clamp(1 - max(0, remainingScroll) / window)
        return OutlineMotion.lerp(resting, bottom, drift)
    }

    /// How far below the top of the visible page a heading lands: where the
    /// note's first line rests, or in Typewriter mode where the caret's line
    /// is kept, the middle.
    public static func landing(typewriter: Bool, topPadding: CGFloat, visibleHeight: CGFloat, lineHeight: CGFloat) -> CGFloat {
        typewriter ? ((visibleHeight - lineHeight) / 2).rounded() : topPadding
    }

    /// How long a glide takes, by how far it goes: short hops are quick.
    public static func glideDuration(distance: CGFloat, visibleHeight: CGFloat) -> Double {
        let screens = abs(distance) / max(1, visibleHeight)
        return 0.3 + 0.2 * Double(min(1, screens))
    }

    /// Fast at first, settling gently.
    public static func easeOut(_ t: Double) -> Double {
        let clamped = min(1, max(0, t))
        return 1 - pow(1 - clamped, 3)
    }
}
