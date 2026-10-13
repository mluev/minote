import AppKit
import MinoteEditor
import MinoteKit
import SwiftUI

/// The outline beside the page in Preview: which headings there are and
/// which one is being read, hovering the rail open into the card, and going
/// to a heading. Nothing runs outside Preview, and while the pointer is still
/// and the page isn't scrolling nothing runs at all.
final class OutlineController {
    let model = OutlineModel()

    /// Puts the (hidden) caret at a heading, so leaving Preview continues there.
    var moveCaret: ((Int) -> Void)?
    var isTypewriter: () -> Bool = { false }
    /// Room kept free at the bottom of the page (the word counter's).
    var bottomReserve: () -> CGFloat = { 12 }
    var hasNote: () -> Bool = { false }
    /// The pointer left the outline for the page.
    var onPointerLeft: (() -> Void)?

    private weak var textView: WriterTextView?
    private weak var scrollView: EditorScrollView?
    private let engine: EditorTextEngine
    private var overlay: OutlineOverlayView?

    private var isPreviewing = false
    private var headingsAreStale = true
    private var updateScheduled = false
    private var activeUpdateScheduled = false
    private var observers: [NSObjectProtocol] = []
    private var reduceMotionObserver: NSObjectProtocol?

    // The card.
    private var isExpanded = false
    /// The last collapse has finished: the next opening may start from another row.
    private var isSettledClosed = true
    private var animationGeneration = 0
    private var expandTask: Task<Void, Never>?
    private var collapseTask: Task<Void, Never>?
    private var pointer: CGPoint?
    private var isPointerInside = false
    private var pressedRow: Int?

    // Going to a heading.
    private var glide: ScrollGlide?
    /// The heading just gone to stays current while the page stays where the glide left it.
    private var pin: (index: Int, originY: CGFloat)?

    private static let expandDelay: Duration = .milliseconds(80)
    private static let collapseDelay: Duration = .milliseconds(200)
    /// How far around the card the pointer may stray before it closes.
    private static let cardTolerance: CGFloat = 6

    init(textView: WriterTextView, scrollView: EditorScrollView, engine: EditorTextEngine) {
        self.textView = textView
        self.scrollView = scrollView
        self.engine = engine
        model.paper = engine.styleSheet.palette.paper
        model.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        reduceMotionObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                if self?.model.reduceMotion != reduce { self?.model.reduceMotion = reduce }
            }
        }
        scrollView.onOutlineFrameChange = { [weak self] in self?.setNeedsUpdate() }
    }

    isolated deinit {
        // A glide's display link and event monitor would outlive the window.
        glide?.cancel()
        expandTask?.cancel()
        collapseTask?.cancel()
        if let reduceMotionObserver { NSWorkspace.shared.notificationCenter.removeObserver(reduceMotionObserver) }
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    // MARK: Editor events

    func setPreviewing(_ previewing: Bool) {
        guard previewing != isPreviewing else { return }
        isPreviewing = previewing
        if previewing {
            headingsAreStale = true
            pin = nil
        } else {
            glide?.cancel()
            collapse(animated: false)
        }
        setNeedsUpdate()
    }

    /// Another note is shown (or the text was replaced from disk).
    func noteDidChange() {
        headingsAreStale = true
        pin = nil
        glide?.cancel()
        collapse(animated: false)
        if isPreviewing { setNeedsUpdate() }
    }

    /// The text changed in Preview (a task ticked, an undo).
    func textDidChange() {
        headingsAreStale = true
        if isPreviewing { setNeedsUpdate() }
    }

    func styleDidChange(paper: EditorPaper) {
        if model.paper != paper { model.paper = paper }
        if isPreviewing { setNeedsUpdate() }
    }

    func containsPointer(windowPoint: NSPoint) -> Bool {
        model.isShown && overlay?.contains(windowPoint: windowPoint) == true
    }

    // MARK: Update

    /// Refreshes the outline once the current run loop turn is done.
    func setNeedsUpdate() {
        guard !updateScheduled else { return }
        updateScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.updateScheduled = false
            self.update()
        }
    }

    private func update() {
        guard isPreviewing, hasNote() else {
            hide()
            return
        }
        if headingsAreStale {
            headingsAreStale = false
            let headings = engine.outline()
            if headings != model.headings {
                collapse(animated: false)
                pin = nil
                model.setHeadings(headings)
                if model.active.map({ $0 >= headings.count }) == true { model.active = nil }
                overlay?.updateAccessibility(titles: model.titles, levels: headings.map(\.level))
            }
        }
        relayout(animated: false)
    }

    private func relayout(animated: Bool) {
        guard let scrollView, let textView else { return }
        let frame = scrollView.outlineFrame
        let columnRight = textView.bounds.width - textView.textContainerInset.width - textView.styleSheet.gutter
        let textMaxX = scrollView.convert(NSPoint(x: columnRight, y: 0), from: textView).x - frame.minX
        let layout = OutlineLayout(levels: model.headings.map(\.level), bounds: CGRect(origin: .zero, size: frame.size),
                                   textMaxX: textMaxX, bottomReserve: bottomReserve(), anchor: model.active ?? model.origin)
        if layout != model.layout {
            if animated {
                withAnimation(.easeOut(duration: 0.2)) { model.layout = layout }
            } else {
                model.layout = layout
            }
        }
        let offset = layout.clampedListOffset(model.listOffset)
        if offset != model.listOffset { model.listOffset = offset }

        let shown = !layout.isHidden
        if shown { ensureOverlay() }
        if shown != model.isShown {
            if !shown { collapse(animated: false) }
            withAnimation(.easeOut(duration: shown ? 0.2 : 0.15)) { model.isShown = shown }
        }
        if shown {
            installObservers()
            scheduleActiveUpdate()
        } else {
            removeObservers()
        }
        updateInteractiveRect()
    }

    private func hide() {
        glide?.cancel()
        collapse(animated: false)
        removeObservers()
        if model.isShown {
            withAnimation(.easeOut(duration: 0.15)) { model.isShown = false }
        }
        updateInteractiveRect()
    }

    /// The overlay is made the first time there is an outline to show, so a
    /// note opened only to write never builds it.
    private func ensureOverlay() {
        guard overlay == nil, let scrollView else { return }
        let overlay = OutlineOverlayView(model: model)
        overlay.controller = self
        overlay.updateAccessibility(titles: model.titles, levels: model.headings.map(\.level))
        self.overlay = overlay
        scrollView.outlineOverlay = overlay
    }

    private func updateInteractiveRect() {
        guard let overlay else { return }
        guard model.isShown, let layout = model.layout else {
            overlay.interactiveRect = .zero
            return
        }
        overlay.interactiveRect = isExpanded
            ? layout.cardRect.insetBy(dx: -Self.cardTolerance, dy: -Self.cardTolerance).union(layout.railHitRect)
            : layout.railHitRect
    }

    // MARK: Observing the page

    private func installObservers() {
        guard observers.isEmpty, let scrollView else { return }
        let center = NotificationCenter.default
        let clip = scrollView.contentView
        clip.postsBoundsChangedNotifications = true
        observers.append(center.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleActiveUpdate() }
        })
        let closeCard: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.collapse(animated: true) }
        }
        if let window = scrollView.window {
            observers.append(center.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main, using: closeCard))
        }
        observers.append(center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main, using: closeCard))
    }

    private func removeObservers() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
    }

    // MARK: The heading being read

    private func scheduleActiveUpdate() {
        guard !activeUpdateScheduled else { return }
        activeUpdateScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.activeUpdateScheduled = false
            self.updateActive()
        }
    }

    private func updateActive() {
        guard model.isShown, glide?.isRunning != true, let scrollView, let textView, !model.headings.isEmpty else { return }
        if let pin {
            if abs(scrollView.contentView.bounds.minY - pin.originY) <= textView.styleSheet.lineHeight { return }
            self.pin = nil
        }
        guard let offset = readingOffset(scrollView, textView) else { return }
        setActive(MarkdownOutline.section(at: offset, in: model.headings))
    }

    private func setActive(_ index: Int?) {
        guard index != model.active else { return }
        withAnimation(.easeOut(duration: 0.2)) { model.active = index }
        // A rail too long for the page shows the dashes around the heading being read.
        if let layout = model.layout, layout.dashRange.count < layout.count {
            relayout(animated: true)
        }
    }

    /// The character at the reading line.
    private func readingOffset(_ scrollView: NSScrollView, _ textView: WriterTextView) -> Int? {
        guard let layoutManager = textView.textLayoutManager, let content = layoutManager.textContentManager else { return nil }
        let clip = scrollView.contentView
        let inset = scrollView.contentInsets.top
        let visibleHeight = clip.bounds.height - inset
        let lineHeight = textView.styleSheet.lineHeight
        let minOrigin = -inset
        let maxOrigin = max(minOrigin, textView.frame.height - clip.bounds.height)
        let landing = OutlineScrolling.landing(typewriter: isTypewriter(), topPadding: textView.topPadding,
                                               visibleHeight: visibleHeight, lineHeight: lineHeight)
        let y = OutlineScrolling.readingLineY(visibleTop: clip.bounds.minY + inset, visibleHeight: visibleHeight,
                                              landing: landing, lineHeight: lineHeight,
                                              remainingScroll: maxOrigin - clip.bounds.minY, scrollRange: maxOrigin - minOrigin)
        let containerY = y - textView.textContainerOrigin.y
        // Walk the laid-out fragments from the top of the viewport: the
        // reading line is always inside it.
        let start = layoutManager.textViewportLayoutController.viewportRange?.location ?? content.documentRange.location
        var found: Int?
        layoutManager.enumerateTextLayoutFragments(from: start, options: []) { fragment in
            guard fragment.layoutFragmentFrame.maxY > containerY else { return true }
            found = content.offset(from: content.documentRange.location, to: fragment.rangeInElement.location)
            return false
        }
        return found ?? textView.textStorage?.length
    }

    // MARK: Pointer

    func pointerMoved(to point: CGPoint) {
        pointer = point
        guard model.isShown, let layout = model.layout else { return }
        let inRail = layout.railHitRect.contains(point)
        let inCard = isExpanded && layout.cardRect.insetBy(dx: -Self.cardTolerance, dy: -Self.cardTolerance).contains(point)
        let inside = inRail || inCard
        if inside { NSCursor.arrow.set() }
        if inside != isPointerInside {
            isPointerInside = inside
            if !inside { onPointerLeft?() }
        }
        if isExpanded {
            if inside {
                collapseTask?.cancel()
                collapseTask = nil
                if pressedRow == nil { setPlate(layout.rowIndex(at: point, listOffset: model.listOffset)) }
            } else {
                setPlate(nil)
                scheduleCollapse()
            }
        } else if inRail {
            scheduleExpand()
        } else {
            expandTask?.cancel()
            expandTask = nil
        }
    }

    func pointerExited() {
        pointer = nil
        expandTask?.cancel()
        expandTask = nil
        if isPointerInside {
            isPointerInside = false
            onPointerLeft?()
        }
        if isExpanded {
            setPlate(nil)
            scheduleCollapse()
        }
    }

    func mouseDown(at point: CGPoint) {
        guard model.isShown, let layout = model.layout else { return }
        if !isExpanded {
            // A click on the rail opens the card at once.
            expand(origin: layout.dashIndex(near: point.y) ?? 0)
            return
        }
        pressedRow = layout.rowIndex(at: point, listOffset: model.listOffset)
        if let pressedRow { setPlate(pressedRow, strength: 1.7) }
    }

    func mouseDragged(to point: CGPoint) {
        guard let pressedRow, let layout = model.layout else { return }
        let over = layout.rowIndex(at: point, listOffset: model.listOffset) == pressedRow
        setPlate(pressedRow, strength: over ? 1.7 : 1)
    }

    func mouseUp(at point: CGPoint) {
        defer { pressedRow = nil }
        guard let pressedRow, let layout = model.layout else { return }
        let row = layout.rowIndex(at: point, listOffset: model.listOffset)
        setPlate(row)
        if row == pressedRow { select(pressedRow) }
    }

    /// Scrolls an open card's list when it has more rows than fit. False
    /// when the page should scroll instead.
    func scrollList(with event: NSEvent, at point: CGPoint) -> Bool {
        guard isExpanded, let layout = model.layout, layout.maxListOffset > 0, layout.cardRect.contains(point) else { return false }
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 10
        let offset = layout.clampedListOffset(model.listOffset - delta)
        if offset != model.listOffset { model.listOffset = offset }
        setPlate(layout.rowIndex(at: point, listOffset: offset))
        return true
    }

    private func setPlate(_ row: Int?, strength: CGFloat = 1) {
        let newStrength: CGFloat = row == nil ? 0 : strength
        guard row != model.plate || newStrength != model.plateStrength else { return }
        withAnimation(.easeOut(duration: 0.12)) {
            // Fading out stays on the last row; moving slides between rows.
            if let row { model.plate = row }
            model.plateStrength = newStrength
        }
    }

    // MARK: Opening and closing

    private var expandAnimation: Animation {
        model.reduceMotion ? .easeInOut(duration: 0.15) : .spring(duration: 0.45, bounce: 0)
    }

    private var collapseAnimation: Animation {
        model.reduceMotion ? .easeInOut(duration: 0.15) : .spring(duration: 0.35, bounce: 0)
    }

    private func scheduleExpand() {
        guard expandTask == nil else { return }
        expandTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.expandDelay)
            guard let self, !Task.isCancelled else { return }
            self.expandTask = nil
            guard let pointer = self.pointer, let layout = self.model.layout, layout.railHitRect.contains(pointer) else { return }
            self.expand(origin: layout.dashIndex(near: pointer.y) ?? 0)
        }
    }

    private func scheduleCollapse() {
        guard collapseTask == nil else { return }
        collapseTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.collapseDelay)
            guard let self, !Task.isCancelled else { return }
            self.collapseTask = nil
            self.collapse(animated: true)
        }
    }

    private func expand(origin: Int) {
        expandTask?.cancel()
        expandTask = nil
        collapseTask?.cancel()
        collapseTask = nil
        guard !isExpanded, model.isShown, let layout = model.layout else { return }
        isExpanded = true
        if isSettledClosed {
            // A fresh opening starts from the dash under the pointer; one
            // that interrupts a closing card goes back the way it came.
            if model.origin != origin { model.origin = origin }
            let offset = layout.listOffset(placing: origin)
            if offset != model.listOffset { model.listOffset = offset }
        }
        isSettledClosed = false
        animationGeneration += 1
        withAnimation(expandAnimation) { model.progress = 1 }
        updateInteractiveRect()
    }

    func collapse(animated: Bool) {
        expandTask?.cancel()
        expandTask = nil
        collapseTask?.cancel()
        collapseTask = nil
        pressedRow = nil
        guard isExpanded || !isSettledClosed else { return }
        isExpanded = false
        setPlate(nil)
        animationGeneration += 1
        let generation = animationGeneration
        if animated {
            withAnimation(collapseAnimation, completionCriteria: .logicallyComplete) {
                model.progress = 0
            } completion: { [weak self] in
                MainActor.assumeIsolated {
                    if self?.animationGeneration == generation { self?.isSettledClosed = true }
                }
            }
        } else {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { model.progress = 0 }
            isSettledClosed = true
        }
        updateInteractiveRect()
    }

    // MARK: Going to a heading

    func select(_ index: Int) {
        guard index < model.headings.count, let textView, let scrollView else { return }
        let heading = model.headings[index]
        pin = nil
        if model.active != index {
            withAnimation(.easeOut(duration: 0.2)) { model.active = index }
        }
        moveCaret?(heading.contentLocation)
        glide?.cancel()
        let glide = ScrollGlide(textView: textView, scrollView: scrollView, location: heading.location,
                                typewriter: isTypewriter()) { [weak self] finished in
            guard let self else { return }
            self.glide = nil
            if finished {
                self.pin = (index, scrollView.contentView.bounds.minY)
            } else {
                self.scheduleActiveUpdate()
            }
        }
        self.glide = glide
        glide.start(animated: !model.reduceMotion)
    }

    /// Where a heading is drawn now (a row when the card is open, else its dash).
    func itemRect(_ index: Int) -> CGRect? {
        guard let layout = model.layout, index < layout.count else { return nil }
        return isExpanded ? layout.rowRect(index, listOffset: model.listOffset) : layout.dashRect(index).insetBy(dx: -2, dy: -3)
    }

    #if DEBUG
    var isGliding: Bool { glide?.isRunning == true }
    var isCardOpen: Bool { isExpanded }
    var overlayView: OutlineOverlayView? { overlay }
    var pinnedIndex: Int? { pin?.index }
    #endif
}
