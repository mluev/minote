import AppKit

/// The editor's scroll view. NSScrollView hit-tests its content insets as its
/// own area, so the space left for scrolling past the end of the note (a large
/// bottom inset) would swallow clicks meant for the text there: clicks
/// anywhere over the page go to the text view.
final class EditorScrollView: NSScrollView {
    /// Pinned to the bottom-left corner, above the text (the link hint).
    var overlay: NSView? {
        didSet {
            oldValue?.removeFromSuperview()
            if let overlay { addSubview(overlay) }
            tile()
        }
    }

    /// The outline beside the page, below the link hint. It takes events only
    /// over its own shape (its `hitTest` says nil elsewhere).
    var outlineOverlay: NSView? {
        didSet {
            oldValue?.removeFromSuperview()
            if let outlineOverlay {
                if let overlay, overlay.superview === self {
                    addSubview(outlineOverlay, positioned: .below, relativeTo: overlay)
                } else {
                    addSubview(outlineOverlay)
                }
            }
            tile()
        }
    }

    /// Called when the area the outline may use changes (resizing, the find
    /// bar, full screen).
    var onOutlineFrameChange: (() -> Void)?
    private var lastOutlineFrame: NSRect?

    /// Width of the strip at the page's right edge the outline may use.
    private static let outlineWidth: CGFloat = 320
    /// Room left for overlay scrollers, which appear over the page's edge.
    private static let overlayScrollerReserve: CGFloat = 12

    /// The outline's area: the right edge of the visible page, below the
    /// toolbar (and the find bar), clear of the scroller.
    var outlineFrame: NSRect {
        let clip = contentView.frame
        // A scroll view isn't flipped: the top is at maxY.
        var top = clip.maxY - contentInsets.top
        if isFindBarVisible, let bar = findBarView, !bar.isHidden {
            top = min(top, bar.frame.minY)
        }
        let reserve = scrollerStyle == .overlay && hasVerticalScroller ? Self.overlayScrollerReserve : 0
        let right = clip.maxX - reserve
        let width = max(0, min(Self.outlineWidth, right - clip.minX))
        return NSRect(x: right - width, y: clip.minY, width: width, height: max(0, top - clip.minY))
    }

    /// Scroll views place their own subviews here (not with constraints).
    override func tile() {
        super.tile()
        if let overlay {
            let size = overlay.fittingSize
            let width = min(size.width, max(0, bounds.width - 140))
            let y = isFlipped ? bounds.height - size.height - 8 : 8
            overlay.frame = NSRect(x: 8, y: y, width: width, height: size.height)
        }
        let outline = outlineFrame
        if let outlineOverlay, outlineOverlay.frame != outline {
            outlineOverlay.frame = outline
        }
        if outline != lastOutlineFrame {
            lastOutlineFrame = outline
            onOutlineFrameChange?()
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        guard hit === self, let documentView, frame.contains(point) else { return hit }
        let local = convert(point, from: superview)
        // The scrollers keep their own clicks.
        for scroller in [verticalScroller, horizontalScroller].compactMap({ $0 }) where !scroller.isHidden {
            if scroller.frame.contains(local) { return hit }
        }
        return documentView
    }
}
