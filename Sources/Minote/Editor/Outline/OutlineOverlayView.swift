import AppKit
import MinoteEditor
import SwiftUI

/// The outline's place above the page. An AppKit view owns every event (so
/// what is clicked is decided by the same layout that draws), and a SwiftUI
/// view inside it only draws. Outside the outline's own shape it isn't there
/// at all: clicks, the cursor and scrolling belong to the text.
final class OutlineOverlayView: NSView {
    weak var controller: OutlineController?
    private let host: PassiveHostingView<OutlineRailHost>
    private var trackingArea: NSTrackingArea?
    private var accessibilityItems: [OutlineAccessibilityItem] = []

    /// Where the outline takes the pointer: the rail, or the open card.
    var interactiveRect: CGRect = .zero {
        didSet {
            guard oldValue != interactiveRect else { return }
            window?.invalidateCursorRects(for: self)
        }
    }

    init(model: OutlineModel) {
        host = PassiveHostingView(rootView: OutlineRailHost(model: model))
        super.init(frame: .zero)
        // The host never sizes anything (every animation frame would lay the
        // window out again) and never bridges a toolbar or safe area.
        host.sizingOptions = []
        host.safeAreaRegions = []
        host.sceneBridgingOptions = []
        host.autoresizingMask = [.width, .height]
        host.frame = bounds
        addSubview(host)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Outline")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, interactiveRect.contains(convert(point, from: superview)) else { return nil }
        return self
    }

    /// Whether a point in window coordinates is over the outline.
    func contains(windowPoint: NSPoint) -> Bool {
        !isHidden && window != nil && interactiveRect.contains(convert(windowPoint, from: nil))
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { false }

    // MARK: Pointer

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    private func location(_ event: NSEvent) -> CGPoint {
        convert(event.locationInWindow, from: nil)
    }

    override func mouseEntered(with event: NSEvent) {
        controller?.pointerMoved(to: location(event))
    }

    override func mouseMoved(with event: NSEvent) {
        controller?.pointerMoved(to: location(event))
    }

    override func mouseExited(with event: NSEvent) {
        controller?.pointerExited()
    }

    override func mouseDown(with event: NSEvent) {
        controller?.mouseDown(at: location(event))
    }

    override func mouseDragged(with event: NSEvent) {
        controller?.mouseDragged(to: location(event))
    }

    override func mouseUp(with event: NSEvent) {
        controller?.mouseUp(at: location(event))
    }

    /// An open card with more rows than fit scrolls its list; otherwise the page scrolls.
    override func scrollWheel(with event: NSEvent) {
        if controller?.scrollList(with: event, at: location(event)) != true {
            super.scrollWheel(with: event)
        }
    }

    override func resetCursorRects() {
        addCursorRect(interactiveRect, cursor: .arrow)
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.arrow.set()
    }

    // MARK: Accessibility

    /// One button per heading; pressing it goes there.
    func updateAccessibility(titles: [String], levels: [Int]) {
        accessibilityItems = zip(titles, levels).enumerated().map { index, heading in
            OutlineAccessibilityItem(overlay: self, index: index, title: heading.0, level: heading.1)
        }
        NSAccessibility.post(element: self, notification: .layoutChanged)
    }

    override func isAccessibilityElement() -> Bool {
        controller?.model.isShown ?? false
    }

    override func accessibilityChildren() -> [Any]? {
        isAccessibilityElement() ? accessibilityItems : []
    }

    /// Where a heading's dash or row is, on screen.
    fileprivate func screenFrame(ofItem index: Int) -> NSRect {
        guard let window, let rect = controller?.itemRect(index) else { return .zero }
        return window.convertToScreen(convert(rect, to: nil))
    }

    fileprivate func pressItem(_ index: Int) {
        controller?.select(index)
    }
}

/// A heading in the accessibility tree. AppKit's elements aren't tied to the
/// main actor, but accessibility asks on the main thread.
nonisolated private final class OutlineAccessibilityItem: NSAccessibilityElement {
    private weak var overlay: OutlineOverlayView?
    private let index: Int

    init(overlay: OutlineOverlayView, index: Int, title: String, level: Int) {
        self.overlay = overlay
        self.index = index
        super.init()
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
        setAccessibilityHelp("Heading level \(level). Goes to this heading.")
        setAccessibilityParent(overlay)
    }

    override func accessibilityFrame() -> NSRect {
        let overlay = overlay, index = index
        return MainActor.assumeIsolated { overlay?.screenFrame(ofItem: index) ?? .zero }
    }

    override func accessibilityPerformPress() -> Bool {
        let overlay = overlay, index = index
        return MainActor.assumeIsolated {
            overlay?.pressItem(index)
            return overlay != nil
        }
    }
}

/// Hosts SwiftUI that only draws: it takes no events and isn't in the
/// accessibility tree (its container speaks for it).
final class PassiveHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }
    override func accessibilityChildren() -> [Any]? { [] }
}
