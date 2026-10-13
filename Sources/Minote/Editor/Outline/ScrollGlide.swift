import AppKit
import MinoteEditor
import QuartzCore

/// Glides the page until a line sits where headings land (where the first
/// line rests, or the middle in Typewriter mode). What it animates is the
/// line's distance from the top of the page, measured again on every frame:
/// TextKit 2 replaces estimated heights as it lays out, so a fixed scroll
/// target would miss, and correcting it at the end would jump.
final class ScrollGlide: NSObject {
    private weak var textView: WriterTextView?
    private weak var scrollView: NSScrollView?
    private let location: Int
    private let typewriter: Bool
    private let completion: (_ finished: Bool) -> Void

    private var displayLink: CADisplayLink?
    private var eventMonitor: Any?
    private var startTime: CFTimeInterval = 0
    private var duration: Double = 0
    private var startDistance: CGFloat = 0
    private(set) var isRunning = false

    /// Farther than this many screens, the page first jumps close.
    private static let maxGlideScreens: CGFloat = 2.5
    /// How far off a long jump lands before gliding the rest.
    private static let approachScreens: CGFloat = 0.6

    init(textView: WriterTextView, scrollView: NSScrollView, location: Int, typewriter: Bool,
         completion: @escaping (_ finished: Bool) -> Void) {
        self.textView = textView
        self.scrollView = scrollView
        self.location = location
        self.typewriter = typewriter
        self.completion = completion
    }

    func start(animated: Bool) {
        guard let scrollView, let line = lineRect() else {
            completion(false)
            return
        }
        let visible = visibleHeight(scrollView)
        guard animated else {
            place(distance: landing(line, scrollView))
            completion(true)
            return
        }
        var distance = currentDistance(line, scrollView)
        let landing = landing(line, scrollView)
        if abs(distance - landing) > Self.maxGlideScreens * visible {
            // Don't scroll through everything in between: come in from
            // just short of the heading, in the direction of travel. Both
            // placements happen before anything is drawn.
            let approach = landing + (distance > landing ? 1 : -1) * Self.approachScreens * visible
            place(distance: approach)
            textView?.textLayoutManager?.textViewportLayoutController.layoutViewport()
            place(distance: approach)
            guard let settled = lineRect() else {
                completion(false)
                return
            }
            distance = currentDistance(settled, scrollView)
        }
        startDistance = distance
        duration = OutlineScrolling.glideDuration(distance: distance - landing, visibleHeight: visible)
        startTime = CACurrentMediaTime()
        isRunning = true

        let link = scrollView.displayLink(target: self, selector: #selector(step(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
        // The reader takes over: scrolling, clicking or typing stops the glide.
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]) { [weak self] event in
            MainActor.assumeIsolated { self?.cancel() }
            return event
        }
    }

    func cancel() {
        guard isRunning else { return }
        finish(false)
    }

    @objc private func step(_ link: CADisplayLink) {
        guard isRunning, let scrollView, let line = lineRect() else {
            finish(false)
            return
        }
        let t = duration > 0 ? (CACurrentMediaTime() - startTime) / duration : 1
        let target = landing(line, scrollView)
        let distance = startDistance + (target - startDistance) * CGFloat(OutlineScrolling.easeOut(t))
        place(distance: distance)
        if t >= 1 { finish(true) }
    }

    private func finish(_ finished: Bool) {
        isRunning = false
        displayLink?.invalidate()
        displayLink = nil
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
        completion(finished)
    }

    // MARK: Geometry

    /// The line's top in text view coordinates (its first line, below any
    /// spacing before a heading).
    private func lineRect() -> CGRect? {
        guard let textView, let layoutManager = textView.textLayoutManager,
              let content = layoutManager.textContentManager,
              let start = content.location(content.documentRange.location, offsetBy: location) else { return nil }
        layoutManager.ensureLayout(for: NSTextRange(location: start))
        guard let fragment = layoutManager.textLayoutFragment(for: start) else { return nil }
        let frame = fragment.layoutFragmentFrame
        let line = fragment.textLineFragments.first?.typographicBounds ?? CGRect(x: 0, y: 0, width: frame.width, height: frame.height)
        let origin = textView.textContainerOrigin
        return CGRect(x: frame.minX + origin.x, y: frame.minY + line.minY + origin.y, width: frame.width, height: line.height)
    }

    private func visibleHeight(_ scrollView: NSScrollView) -> CGFloat {
        scrollView.contentView.bounds.height - scrollView.contentInsets.top
    }

    /// How far below the top of the visible page the line is now.
    private func currentDistance(_ line: CGRect, _ scrollView: NSScrollView) -> CGFloat {
        line.minY - (scrollView.contentView.bounds.minY + scrollView.contentInsets.top)
    }

    /// Where the line should end up, as close to the landing place as the
    /// page can scroll (a heading near the end can't reach the top).
    private func landing(_ line: CGRect, _ scrollView: NSScrollView) -> CGFloat {
        guard let textView else { return 0 }
        let clip = scrollView.contentView
        let inset = scrollView.contentInsets.top
        let wanted = OutlineScrolling.landing(typewriter: typewriter, topPadding: textView.topPadding,
                                              visibleHeight: visibleHeight(scrollView), lineHeight: line.height)
        let minOrigin = -inset
        let maxOrigin = max(minOrigin, textView.frame.height - clip.bounds.height)
        let nearest = line.minY - inset - maxOrigin
        let farthest = line.minY - inset - minOrigin
        return min(max(wanted, nearest), farthest)
    }

    /// Scrolls so the line sits `distance` below the top of the visible page.
    private func place(distance: CGFloat) {
        guard let scrollView, let line = lineRect() else { return }
        let clip = scrollView.contentView
        let scale = scrollView.window?.backingScaleFactor ?? 2
        var origin = clip.bounds.origin
        origin.y = ((line.minY - scrollView.contentInsets.top - distance) * scale).rounded() / scale
        let constrained = clip.constrainBoundsRect(NSRect(origin: origin, size: clip.bounds.size)).origin
        guard abs(constrained.y - clip.bounds.minY) >= 0.25 else { return }
        clip.scroll(to: constrained)
        scrollView.reflectScrolledClipView(clip)
    }
}
