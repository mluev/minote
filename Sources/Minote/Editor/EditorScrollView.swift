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

    /// Scroll views place their own subviews here (not with constraints).
    override func tile() {
        super.tile()
        guard let overlay else { return }
        let size = overlay.fittingSize
        let width = min(size.width, max(0, bounds.width - 140))
        let y = isFlipped ? bounds.height - size.height - 8 : 8
        overlay.frame = NSRect(x: 8, y: y, width: width, height: size.height)
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
