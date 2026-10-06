import AppKit
import MinoteKit
import MinoteEditor

/// What the text view asks its owner about rendered Markdown: where the
/// caret may go, links, task boxes.
@MainActor
protocol WriterTextViewInteraction: AnyObject {
    /// Where a new selection should really go (never inside hidden markup).
    /// `previous` is the selection before a keyboard move (nil for clicks).
    func adjustedSelection(_ proposed: NSRange, previous: NSRange?) -> NSRange
    /// The start of the caret's line when the caret is right after hidden markup.
    func markupLineStart(ifCaretAtHome location: Int) -> Int?
    /// Backspace that removes hidden block markup as one unit.
    func markupDeletion(for selection: NSRange) -> TextEdit?
    /// The line of the task box at a point in text container coordinates.
    func taskBox(at point: CGPoint) -> Int?
    /// The character of a link at a point in text container coordinates.
    func linkIndex(at point: CGPoint) -> Int?
    func toggleTask(atLine location: Int)
    func openLink(at index: Int)
    /// The pointer moved onto a link (its character) or off it (nil).
    func hoverChanged(linkAt index: Int?)
    /// Preview: a plain click follows links.
    var opensLinksOnClick: Bool { get }
}

/// The writing surface: a plain-text TextKit 2 view with a centered column of
/// fixed width, iA-style line spacing and a custom caret.
final class WriterTextView: NSTextView {
    weak var interaction: WriterTextViewInteraction?
    let caretView = CaretView()

    private(set) var styleSheet = EditorStyleSheet(family: .plexMono, size: CGFloat(EditorTheme.defaultFontSize))

    /// Space above the first line, inside the scrollable area.
    var topPadding: CGFloat = 60 {
        didSet { if oldValue != topPadding { updateInsets() } }
    }

    /// Space below the last line, so it can scroll up to a comfortable
    /// height. It's part of the text view (not a scroll view inset, which
    /// AppKit treats as outside the page: clicks there would be lost or
    /// start a selection running to the end of the note).
    var bottomPadding: CGFloat = 0 {
        didSet { if oldValue != bottomPadding { updateInsets() } }
    }

    /// Called after every user edit.
    var onUserEdit: (() -> Void)?
    /// Called when the editor gains or loses keyboard focus.
    var onFocusChange: ((Bool) -> Void)?

    private var caretUpdateScheduled = false
    private var focusWhenInWindow = false

    // MARK: Setup

    func setUp() {
        isRichText = false
        importsGraphics = false
        allowsImageEditing = false
        usesFontPanel = false
        usesRuler = false
        isRulerVisible = false
        allowsUndo = true
        usesFindBar = true
        isIncrementalSearchingEnabled = true
        isAutomaticLinkDetectionEnabled = false
        isAutomaticDataDetectionEnabled = false
        displaysLinkToolTips = false
        inlinePredictionType = .no

        drawsBackground = true
        backgroundColor = EditorTheme.background
        insertionPointColor = .clear
        selectedTextAttributes = [.backgroundColor: EditorTheme.selection]

        isVerticallyResizable = true
        isHorizontallyResizable = false
        autoresizingMask = [.width]
        minSize = .zero
        maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textContainer?.widthTracksTextView = true
        textContainer?.lineFragmentPadding = 0

        caretView.isHidden = true
        addSubview(caretView)
        apply(styleSheet)
    }

    /// Switches fonts and geometry. The caller restyles the text.
    func apply(_ styleSheet: EditorStyleSheet) {
        self.styleSheet = styleSheet
        typingAttributes = styleSheet.baseAttributes
        defaultParagraphStyle = styleSheet.baseAttributes[.paragraphStyle] as? NSParagraphStyle
        updateInsets()
        needsCaretUpdate()
    }

    // MARK: Layout

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateInsets()
    }

    /// Centers the text column. The container is wider than the column by the
    /// gutter on each side (paragraph indents bring the text back), so heading
    /// markers can hang into the left margin.
    private func updateInsets() {
        let columnLeft = max(EditorTheme.minimumHorizontalMargin, ((bounds.width - styleSheet.columnWidth) / 2).rounded(.down))
        // The inset applies above and below; textContainerOrigin puts the
        // text at the top padding, leaving the rest of both below the text.
        let inset = NSSize(width: max(0, columnLeft - styleSheet.gutter), height: ((topPadding + bottomPadding) / 2).rounded())
        if textContainerInset != inset {
            textContainerInset = inset
            needsCaretUpdate()
        }
    }

    override var textContainerOrigin: NSPoint {
        NSPoint(x: super.textContainerOrigin.x, y: topPadding)
    }

    // MARK: Smart typing

    /// Return continues lists and quotes; Return on an empty item ends them.
    override func insertNewline(_ sender: Any?) {
        guard !hasMarkedText(), let text = textStorage?.mutableString,
              let edit = MarkdownEditing.newline(in: text, selection: selectedRange())
        else {
            super.insertNewline(sender)
            return
        }
        apply(edit, actionName: nil)
    }

    /// Tab and Shift-Tab indent and outdent list items.
    override func insertTab(_ sender: Any?) {
        guard let text = textStorage?.mutableString,
              let edit = MarkdownEditing.shiftLines(in: text, selection: selectedRange(), outdent: false, listsOnly: true)
        else {
            super.insertTab(sender)
            return
        }
        apply(edit, actionName: nil)
    }

    /// Backspace right after a bullet, task box, heading or quote marker
    /// removes that markup, which the rendered view doesn't show as text.
    override func deleteBackward(_ sender: Any?) {
        if !hasMarkedText(), let edit = interaction?.markupDeletion(for: selectedRange()) {
            apply(edit, actionName: nil)
            return
        }
        super.deleteBackward(sender)
    }

    // The Left arrow at the start of a bullet's (heading's, quote's) text goes
    // to the line above, rather than into markup the page doesn't show.
    override func moveLeft(_ sender: Any?) {
        if !stepBackOverHiddenMarkup() { super.moveLeft(sender) }
    }

    override func moveBackward(_ sender: Any?) {
        if !stepBackOverHiddenMarkup() { super.moveBackward(sender) }
    }

    override func moveWordLeft(_ sender: Any?) {
        if !stepBackOverHiddenMarkup() { super.moveWordLeft(sender) }
    }

    override func moveWordBackward(_ sender: Any?) {
        if !stepBackOverHiddenMarkup() { super.moveWordBackward(sender) }
    }

    private func stepBackOverHiddenMarkup() -> Bool {
        let selection = selectedRange()
        guard selection.length == 0, let lineStart = interaction?.markupLineStart(ifCaretAtHome: selection.location) else { return false }
        if lineStart > 0 {
            setSelectedRange(NSRange(location: lineStart - 1, length: 0))
            scrollRangeToVisible(selectedRange())
        }
        return true
    }

    override func insertBacktab(_ sender: Any?) {
        guard let text = textStorage?.mutableString,
              let edit = MarkdownEditing.shiftLines(in: text, selection: selectedRange(), outdent: true, listsOnly: true)
        else {
            super.insertBacktab(sender)
            return
        }
        apply(edit, actionName: nil)
    }

    /// Applies an edit as a single undoable change.
    func apply(_ edit: TextEdit, actionName: String?) {
        guard let storage = textStorage else { return }
        guard !edit.replacements.isEmpty else {
            setSelectedRange(edit.selection)
            return
        }
        let ranges = edit.replacements.map { NSValue(range: $0.range) }
        let strings = edit.replacements.map(\.string)
        guard shouldChangeText(inRanges: ranges, replacementStrings: strings) else { return }
        storage.beginEditing()
        for replacement in edit.replacements.reversed() {
            storage.replaceCharacters(in: replacement.range, with: replacement.string)
        }
        storage.endEditing()
        didChangeText()
        if let actionName { undoManager?.setActionName(actionName) }
        let length = storage.length
        let location = min(edit.selection.location, length)
        setSelectedRange(NSRange(location: location, length: min(edit.selection.length, length - location)))
        scrollRangeToVisible(selectedRange())
    }

    // MARK: Caret

    override var shouldDrawInsertionPoint: Bool { false }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        var ranges = ranges
        if ranges.count == 1, let interaction {
            let proposed = ranges[0].rangeValue
            // Only arrow keys step back out of a line; a click never does.
            let isKeyboard = NSApp.currentEvent?.type == .keyDown
            let adjusted = interaction.adjustedSelection(proposed, previous: isKeyboard ? selectedRange() : nil)
            if adjusted != proposed { ranges = [NSValue(range: adjusted)] }
        }
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        needsCaretUpdate()
    }

    // MARK: Links and task boxes

    private var hoveredLink: Int?
    private var isOverTaskBox = false

    /// A point in the view, in text container coordinates.
    private func containerPoint(_ event: NSEvent) -> CGPoint {
        let point = convert(event.locationInWindow, from: nil)
        return CGPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
    }

    /// A click on a task box ticks it; ⌘-click (or a click in Preview) follows a link.
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 1, let interaction, !event.modifierFlags.contains(.shift) {
            let point = containerPoint(event)
            if let line = interaction.taskBox(at: point) {
                interaction.toggleTask(atLine: line)
                return
            }
            if event.modifierFlags.contains(.command) || interaction.opensLinksOnClick,
               let index = interaction.linkIndex(at: point) {
                interaction.openLink(at: index)
                return
            }
        }
        super.mouseDown(with: event)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self && area.userInfo?["minote"] != nil {
            removeTrackingArea(area)
        }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                       owner: self, userInfo: ["minote": true]))
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        updateHover(event)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        setHoveredLink(nil)
        isOverTaskBox = false
    }

    override func flagsChanged(with event: NSEvent) {
        super.flagsChanged(with: event)
        updateCursor(event.modifierFlags)
    }

    override func cursorUpdate(with event: NSEvent) {
        if wantsPointingHand(event.modifierFlags) {
            NSCursor.pointingHand.set()
        } else {
            super.cursorUpdate(with: event)
        }
    }

    func updateHover(_ event: NSEvent) {
        let point = containerPoint(event)
        isOverTaskBox = interaction?.taskBox(at: point) != nil
        setHoveredLink(isOverTaskBox ? nil : interaction?.linkIndex(at: point))
        updateCursor(event.modifierFlags)
    }

    /// Forgets what's under the pointer (after switching to or from Preview).
    func resetHover() {
        hoveredLink = nil
        isOverTaskBox = false
    }

    private func setHoveredLink(_ index: Int?) {
        guard index != hoveredLink else { return }
        hoveredLink = index
        interaction?.hoverChanged(linkAt: index)
    }

    private func wantsPointingHand(_ flags: NSEvent.ModifierFlags) -> Bool {
        isOverTaskBox || (hoveredLink != nil && (flags.contains(.command) || interaction?.opensLinksOnClick == true))
    }

    private func updateCursor(_ flags: NSEvent.ModifierFlags) {
        if wantsPointingHand(flags) {
            NSCursor.pointingHand.set()
        } else if hoveredLink != nil || NSCursor.current == NSCursor.pointingHand {
            NSCursor.iBeam.set()
        }
    }

    override func didChangeText() {
        super.didChangeText()
        needsCaretUpdate()
        onUserEdit?()
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        needsCaretUpdate()
        if accepted { onFocusChange?(true) }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        needsCaretUpdate()
        if accepted { onFocusChange?(false) }
        return accepted
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: nil)
        guard let window else { return }
        NotificationCenter.default.addObserver(self, selector: #selector(windowKeyStateChanged), name: NSWindow.didBecomeKeyNotification, object: window)
        NotificationCenter.default.addObserver(self, selector: #selector(windowKeyStateChanged), name: NSWindow.didResignKeyNotification, object: window)
        if focusWhenInWindow {
            focusWhenInWindow = false
            window.makeFirstResponder(self)
        }
        needsCaretUpdate()
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        needsCaretUpdate()
    }

    @objc private func windowKeyStateChanged() {
        needsCaretUpdate()
    }

    /// Coalesces caret updates to once per run loop turn, after layout settles.
    func needsCaretUpdate() {
        guard !caretUpdateScheduled else { return }
        caretUpdateScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.caretUpdateScheduled = false
            self.updateCaret()
        }
    }

    #if DEBUG
    /// Interaction tests run while another app (or the lock screen) is in front.
    static var assumesKeyWindow = false
    private var isKey: Bool { (window?.isKeyWindow ?? false) || Self.assumesKeyWindow }
    #else
    private var isKey: Bool { window?.isKeyWindow ?? false }
    #endif

    private func updateCaret() {
        guard let window, isKey, window.firstResponder === self, isEditable,
              selectedRange().length == 0, let rect = caretRect()
        else {
            caretView.isHidden = true
            return
        }
        caretView.frame = rect
        caretView.isHidden = false
        caretView.restartBlink()
    }

    /// The caret: a fixed-width bar centered vertically in the insertion line,
    /// snapped to device pixels.
    private func caretRect() -> NSRect? {
        guard let line = insertionLineRect() else { return nil }
        let scale = window?.backingScaleFactor ?? 2
        func snap(_ value: CGFloat) -> CGFloat { (value * scale).rounded() / scale }
        let size = styleSheet.fonts.regular.pointSize
        let width = max(2, snap(size * EditorTheme.caretWidthRatio))
        // Body lines get iA's caret; taller heading lines get a taller one.
        let height = min(line.height, snap(max(size * EditorTheme.caretHeightRatio, line.height * EditorTheme.caretHeightRatio / EditorTheme.lineHeightMultiple)))
        let x = snap(line.minX - width / 2)
        let y = snap(line.minY + (line.height - height) / 2)
        return NSRect(x: x, y: y, width: width, height: height)
    }

    /// Rect of the line the insertion point is on, at the caret's x position,
    /// in view coordinates.
    func insertionLineRect() -> NSRect? {
        let lineHeight = styleSheet.lineHeight
        let location = selectedRange().location
        let origin = textContainerOrigin
        let lineStartX = origin.x + styleSheet.gutter

        // On the empty line after a trailing newline there is no glyph to ask
        // about. Lines have a fixed height, so it's one line below the previous one.
        if location > 0, location == textStorage?.length, endsWithLineBreak,
           let previous = segmentRect(at: location - 1) {
            return NSRect(x: lineStartX, y: previous.minY + lineHeight, width: 0, height: lineHeight)
        }
        if let rect = segmentRect(at: location) {
            return rect
        }
        return NSRect(x: lineStartX, y: origin.y, width: 0, height: lineHeight)
    }

    /// TextKit 2's caret segment at a UTF-16 offset, in view coordinates.
    private func segmentRect(at offset: Int) -> NSRect? {
        guard let layoutManager = textLayoutManager,
              let contentManager = layoutManager.textContentManager,
              let location = contentManager.location(contentManager.documentRange.location, offsetBy: offset)
        else { return nil }
        let range = NSTextRange(location: location)
        layoutManager.ensureLayout(for: range)
        var segment: NSRect?
        layoutManager.enumerateTextSegments(in: range, type: .selection, options: [.rangeNotRequired]) { _, frame, _, _ in
            segment = frame
            return false
        }
        guard var rect = segment, rect.height > 0 else { return nil }
        rect.origin.x += textContainerOrigin.x
        rect.origin.y += textContainerOrigin.y
        return rect
    }

    private var endsWithLineBreak: Bool {
        guard let storage = textStorage, storage.length > 0 else { return false }
        let last = storage.mutableString.character(at: storage.length - 1)
        return last == 0x0A || last == 0x0D || last == 0x2028 || last == 0x2029
    }

    // MARK: Focus and text queries

    func focus() {
        if let window {
            window.makeFirstResponder(self)
        } else {
            focusWhenInWindow = true
        }
    }

    /// The first characters of the text, cut on a character boundary.
    func textPrefix() -> String {
        guard let storage = textStorage else { return "" }
        let string = storage.mutableString
        let length = min(string.length, NoteNaming.prefixLength)
        guard length > 0 else { return "" }
        let range = string.rangeOfComposedCharacterSequences(for: NSRange(location: 0, length: length))
        return string.substring(with: range)
    }

    /// Whether the caret is on (or before) the first non-blank line.
    var isCaretInTitleLine: Bool {
        guard let storage = textStorage else { return true }
        let string = storage.mutableString
        let first = string.rangeOfCharacter(from: CharacterSet.whitespacesAndNewlines.inverted)
        guard first.location != NSNotFound else { return true }
        var contentsEnd = 0
        string.getLineStart(nil, end: nil, contentsEnd: &contentsEnd, for: NSRange(location: first.location, length: 0))
        return selectedRange().location <= contentsEnd
    }
}
