import AppKit
import MinoteEditor
import MinoteKit
import SwiftUI

/// SwiftUI host for the AppKit editor. Text never flows through SwiftUI state:
/// the library drives which note is shown through the `NoteEditor` protocol.
struct EditorView: NSViewRepresentable {
    let library: Library
    let windowState: WindowState
    let configuration: EditorConfiguration
    /// Height of the toolbar area the editor scrolls under.
    let topInset: CGFloat
    /// Full height of the editor, including the toolbar area.
    let viewportHeight: CGFloat
    let onUserEdit: () -> Void

    func makeCoordinator() -> EditorCoordinator {
        EditorCoordinator(configuration: configuration)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let coordinator = context.coordinator
        coordinator.library = library
        coordinator.windowState = windowState
        windowState.editor = coordinator
        coordinator.textView.onUserEdit = onUserEdit
        coordinator.updateLayout(topInset: topInset, viewportHeight: viewportHeight)
        library.attach(coordinator)
        return coordinator.scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.textView.onUserEdit = onUserEdit
        coordinator.apply(configuration)
        coordinator.updateLayout(topInset: topInset, viewportHeight: viewportHeight)
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: EditorCoordinator) {
        coordinator.library?.detach(coordinator)
    }
}

/// Owns the text view and implements the library's view of the editor:
/// switching notes, per-note caret/scroll position and undo, Typewriter mode
/// and the word counter. Styling and Focus mode live in the shared engine.
final class EditorCoordinator: NSObject, NSTextViewDelegate, NoteEditor {
    weak var library: Library?
    weak var windowState: WindowState?
    let textView: WriterTextView
    let scrollView: NSScrollView
    private let engine: EditorTextEngine

    private(set) var displayedNoteID: Note.ID?
    private var undoManagers: [Note.ID: UndoManager] = [:]
    private var viewStates: [Note.ID: (selection: NSRange, scroll: NSPoint)] = [:]
    /// True while we replace the text ourselves (not a user edit).
    private var isReplacingText = false
    private var statisticsTask: Task<Void, Never>?
    /// Bumped whenever the text changes, so the counter can tell a caret move
    /// over the same text (nothing to recount) from an edit.
    private var textRevision = 0
    /// What the counter shows: the text revision and the selection it counted
    /// (empty for the whole note).
    private var counted: (revision: Int, selection: NSRange)?
    private var layoutInputs: (topInset: CGFloat, viewportHeight: CGFloat) = (0, 0)

    private let linkHint = LinkHintView()

    var configuration: EditorConfiguration { engine.configuration }

    #if DEBUG
    /// What the link hint says (for interaction tests).
    var hoverDescription: String { linkHint.text }
    var linkHintFrame: String { "\(linkHint.frame) hidden \(linkHint.isHidden) alpha \(linkHint.alphaValue) super \(linkHint.superview.map { String(describing: type(of: $0)) } ?? "-")" }
    #endif

    init(configuration: EditorConfiguration) {
        textView = WriterTextView(usingTextLayoutManager: true)
        scrollView = EditorScrollView()
        textView.setUp()
        engine = EditorTextEngine(storage: textView.textStorage!, configuration: configuration)
        super.init()

        engine.attach(to: textView.textLayoutManager)
        textView.apply(engine.styleSheet)
        textView.delegate = self
        textView.interaction = self
        engine.isComposing = { [weak textView] in textView?.hasMarkedText() ?? false }
        textView.onFocusChange = { [weak self] focused in
            self?.windowState?.isEditorFocused = focused
        }

        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = EditorTheme.background
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.findBarPosition = .aboveContent
        scrollView.documentView = textView

        (scrollView as? EditorScrollView)?.overlay = linkHint
    }

    // MARK: Configuration and layout

    func apply(_ new: EditorConfiguration) {
        guard new != engine.configuration else { return }
        let change = engine.apply(new, selection: textView.selectedRange())
        if change.contains(.preview) {
            textView.isEditable = displayedNoteID != nil && !new.preview
            linkHint.show(address: nil, action: "")
            textView.resetHover()
            textView.needsCaretUpdate()
        }
        if change.contains(.styleSheet) {
            textView.apply(engine.styleSheet)
            relayoutViewport()
        }
        if change.contains(.styleSheet) || change.contains(.typewriter) {
            updateLayout(topInset: layoutInputs.topInset, viewportHeight: layoutInputs.viewportHeight, force: true)
            centerCaretIfNeeded()
        }
    }

    /// Keeps the text clear of the toolbar and lets the user scroll past the
    /// end. In Typewriter mode, the first and last lines can reach the middle.
    func updateLayout(topInset: CGFloat, viewportHeight: CGFloat, force: Bool = false) {
        guard force || layoutInputs != (topInset, viewportHeight) else { return }
        layoutInputs = (topInset, viewportHeight)
        let visible = max(0, viewportHeight - topInset)
        let lineHeight = textView.styleSheet.lineHeight
        let overscroll: CGFloat
        if configuration.typewriter {
            overscroll = (visible / 2).rounded()
            textView.topPadding = max(40, (visible / 2 - lineHeight / 2).rounded())
        } else {
            overscroll = (visible * 0.4).rounded()
            textView.topPadding = min(140, max(40, (viewportHeight * 0.12).rounded()))
        }
        textView.bottomPadding = overscroll
        let current = scrollView.contentInsets
        if current.top != topInset || current.bottom != 0 {
            scrollView.contentInsets = NSEdgeInsets(top: topInset, left: 0, bottom: 0, right: 0)
        }
    }

    // MARK: NoteEditor

    var isCaretInTitleLine: Bool { textView.isCaretInTitleLine }

    func display(_ note: Note?) {
        if let current = displayedNoteID {
            viewStates[current] = (textView.selectedRange(), scrollView.contentView.bounds.origin)
        }
        pruneState()
        displayedNoteID = note?.id
        replaceText(with: note?.text ?? "")
        textView.isEditable = note != nil && !configuration.preview

        if let note, let state = viewStates[note.id] {
            textView.setSelectedRange(clamped(state.selection))
            scroll(to: state.scroll)
        } else {
            textView.setSelectedRange(NSRange(location: 0, length: 0))
            scroll(to: NSPoint(x: 0, y: -scrollView.contentInsets.top))
        }
        relayoutViewport()
        textView.needsCaretUpdate()
        afterTextChange()
    }

    func currentText() -> String {
        textView.string
    }

    func reloadText(_ text: String) {
        let selection = textView.selectedRange()
        let origin = scrollView.contentView.bounds.origin
        replaceText(with: text)
        if let id = displayedNoteID { undoManagers[id]?.removeAllActions() }
        textView.setSelectedRange(clamped(selection))
        scroll(to: origin)
        relayoutViewport()
        afterTextChange()
    }

    /// Called for a new note: start typing (leaving Preview).
    func focus() {
        if configuration.preview, library?.selectedNote?.isDraft == true {
            windowState?.isPreviewing = false
        }
        textView.focus()
    }

    // MARK: Commands

    func perform(_ action: FormatAction) {
        textView.perform(action)
    }

    /// Prints the note as it looks on screen, in light colors.
    func printNote(title: String) {
        guard let window = textView.window else { return }
        let info = (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo()
        let gutter = textView.styleSheet.gutter
        info.leftMargin = max(18, 72 - gutter)
        info.rightMargin = max(18, 72 - gutter)
        info.topMargin = 72
        info.bottomMargin = 72
        info.horizontalPagination = .fit
        info.isVerticallyCentered = false
        let width = info.paperSize.width - info.leftMargin - info.rightMargin

        // A TextKit 1 view paginates reliably when printing.
        let printStorage = NSTextStorage(attributedString: engine.printableCopy())
        let layoutManager = NSLayoutManager()
        printStorage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)
        let printView = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 100), textContainer: container)
        printView.appearance = NSAppearance(named: .aqua)
        printView.drawsBackground = false
        printView.isVerticallyResizable = true
        layoutManager.ensureLayout(for: container)
        printView.sizeToFit()

        let operation = NSPrintOperation(view: printView, printInfo: info)
        operation.jobTitle = title
        operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    }

    // MARK: NSTextViewDelegate

    func textDidChange(_ notification: Notification) {
        guard !isReplacingText, let id = displayedNoteID else { return }
        textRevision += 1
        library?.editorDidChange(noteID: id, prefix: textView.textPrefix())
        afterTextChange()
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        guard !isReplacingText else { return }
        engine.selectionDidChange(textView.selectedRange())
        if NSApp.currentEvent?.type != .leftMouseDragged { centerCaretIfNeeded() }
        scheduleStatistics()
    }

    /// Each note keeps its own undo history for the session.
    func undoManager(for view: NSTextView) -> UndoManager? {
        guard let id = displayedNoteID else { return nil }
        if let manager = undoManagers[id] { return manager }
        let manager = UndoManager()
        undoManagers[id] = manager
        return manager
    }

    // MARK: Typewriter mode

    /// Keeps the caret's line in the middle of the window.
    private func centerCaretIfNeeded() {
        guard configuration.typewriter, textView.selectedRange().length == 0,
              let line = textView.insertionLineRect() else { return }
        let clip = scrollView.contentView
        let top = scrollView.contentInsets.top
        var origin = clip.bounds.origin
        origin.y = (line.midY - top - (clip.bounds.height - top) / 2).rounded()
        let target = clip.constrainBoundsRect(NSRect(origin: origin, size: clip.bounds.size)).origin
        guard abs(target.y - clip.bounds.origin.y) >= 0.5 else { return }
        clip.scroll(to: target)
        scrollView.reflectScrolledClipView(clip)
    }

    // MARK: Statistics

    private func afterTextChange() {
        engine.selectionDidChange(textView.selectedRange())
        centerCaretIfNeeded()
        scheduleStatistics()
    }

    /// Recounts after typing pauses: the selection if there is one, else the
    /// note. Moving the caret over unchanged text counts nothing again, and
    /// the counting itself happens off the main thread.
    private func scheduleStatistics() {
        guard windowState?.showsCounter == true else { return }
        let target = Self.countedSelection(textView.selectedRange())
        if let counted, counted.revision == textRevision, counted.selection == target { return }
        statisticsTask?.cancel()
        statisticsTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard let self, !Task.isCancelled, let storage = self.textView.textStorage else { return }
            let selection = Self.countedSelection(self.textView.selectedRange())
            let revision = self.textRevision
            let text = selection.length > 0 ? storage.mutableString.substring(with: selection) : self.textView.string
            let statistics = await Task.detached(priority: .utility) { TextStatistics(text) }.value
            guard !Task.isCancelled else { return }
            self.windowState?.statistics = statistics
            self.windowState?.statisticsAreForSelection = selection.length > 0
            self.counted = (revision, selection)
        }
    }

    /// A caret counts the whole note, whichever line it's on.
    private static func countedSelection(_ selection: NSRange) -> NSRange {
        selection.length > 0 ? selection : NSRange(location: 0, length: 0)
    }

    func refreshStatistics() {
        counted = nil
        scheduleStatistics()
    }

    // MARK: Helpers

    /// TextKit 2 lays out only the viewport. After the whole text is replaced
    /// the view grows, but the viewport isn't redone until the next scroll;
    /// do it now (and once more after AppKit settles the new frame).
    private func relayoutViewport() {
        textView.textLayoutManager?.textViewportLayoutController.layoutViewport()
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.textView.textLayoutManager?.textViewportLayoutController.layoutViewport()
            self.textView.needsDisplay = true
        }
    }

    private func replaceText(with text: String) {
        isReplacingText = true
        defer { isReplacingText = false }
        engine.prepareForNewText()
        textRevision += 1
        textView.string = text
        textView.typingAttributes = textView.styleSheet.baseAttributes
    }

    private func clamped(_ range: NSRange) -> NSRange {
        let length = textView.textStorage?.length ?? 0
        let location = min(range.location, length)
        return NSRange(location: location, length: min(range.length, length - location))
    }

    private func scroll(to point: NSPoint) {
        let clip = scrollView.contentView
        clip.scroll(to: clip.constrainBoundsRect(NSRect(origin: point, size: clip.bounds.size)).origin)
        scrollView.reflectScrolledClipView(clip)
    }

    /// Forgets per-note state for notes no longer in the library.
    private func pruneState() {
        guard let library else { return }
        let live = Set(library.notes.map(\.id))
        undoManagers = undoManagers.filter { live.contains($0.key) }
        viewStates = viewStates.filter { live.contains($0.key) }
    }
}

// MARK: - Rendered Markdown: caret, links, task boxes

extension EditorCoordinator: WriterTextViewInteraction {
    var opensLinksOnClick: Bool { configuration.preview }

    func adjustedSelection(_ proposed: NSRange, previous: NSRange?) -> NSRange {
        guard !isReplacingText else { return proposed }
        return engine.adjustedSelection(proposed, previous: previous)
    }

    #if DEBUG
    func characterIndexForProbe(_ point: CGPoint) -> Int? { engine.characterIndex(at: point) }
    #endif

    func markupLineStart(ifCaretAtHome location: Int) -> Int? {
        engine.markupLineStart(ifCaretAtHome: location)
    }

    func markupDeletion(for selection: NSRange) -> TextEdit? {
        engine.markupDeletion(for: selection)
    }

    func newlineEdit(for selection: NSRange) -> TextEdit? {
        engine.newlineEdit(for: selection)
    }

    func listShiftEdit(for selection: NSRange, outdent: Bool) -> TextEdit? {
        engine.listShiftEdit(for: selection, outdent: outdent)
    }

    func taskBox(at point: CGPoint) -> Int? {
        engine.taskBox(at: point)
    }

    func linkIndex(at point: CGPoint) -> Int? {
        guard let index = engine.characterIndex(at: point), engine.link(at: index) != nil else { return nil }
        return index
    }

    /// Ticks a task without moving the caret, also in Preview.
    func toggleTask(atLine location: Int) {
        guard displayedNoteID != nil, let edit = engine.toggleTaskEdit(at: location) else { return }
        let selection = textView.selectedRange()
        let wasEditable = textView.isEditable
        textView.isEditable = true
        textView.apply(TextEdit(edit.replacements, selection: selection), actionName: "Mark Task")
        textView.isEditable = wasEditable
        textView.needsCaretUpdate()
    }

    func openLink(at index: Int) {
        guard let link = engine.link(at: index), let destination = engine.destination(of: link.target) else {
            NSSound.beep()
            return
        }
        switch destination {
        case .external(let url):
            NSWorkspace.shared.open(url)
        case .file(let path):
            if let note = library?.note(linkedAs: path) {
                library?.selectedID = note.id
            } else if let directory = library?.selectedNote?.fileURL?.deletingLastPathComponent() {
                NSWorkspace.shared.open(URL(fileURLWithPath: path, relativeTo: directory))
            } else {
                NSSound.beep()
            }
        case .anchor(let location):
            let target = NSRange(location: location, length: 0)
            if !configuration.preview { textView.setSelectedRange(target) }
            textView.scrollRangeToVisible(target)
        }
    }

    func hoverChanged(linkAt index: Int?) {
        guard let index, let link = engine.link(at: index) else {
            linkHint.show(address: nil, action: "")
            return
        }
        linkHint.show(address: engine.displayAddress(of: link.target),
                      action: configuration.preview ? "Click to open" : "⌘-click to open")
    }
}
