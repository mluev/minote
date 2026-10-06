import MinoteEditor
import MinoteKit
import SwiftUI
import UIKit

/// SwiftUI host for the UIKit editor. As on the Mac, text never flows through
/// SwiftUI state: the library drives the editor through `NoteEditor`.
struct MobileEditorView: UIViewRepresentable {
    let library: Library
    let state: MobileState
    let configuration: EditorConfiguration
    /// iPad-width layout: a centered column with heading markers in the margin.
    let isWide: Bool

    func makeCoordinator() -> MobileEditorCoordinator {
        MobileEditorCoordinator(configuration: configuration, isWide: isWide)
    }

    func makeUIView(context: Context) -> MobileTextView {
        let coordinator = context.coordinator
        coordinator.library = library
        coordinator.state = state
        state.editor = coordinator
        library.attach(coordinator)
        return coordinator.textView
    }

    func updateUIView(_ textView: MobileTextView, context: Context) {
        context.coordinator.apply(configuration, isWide: isWide)
    }

    static func dismantleUIView(_ textView: MobileTextView, coordinator: MobileEditorCoordinator) {
        coordinator.library?.detach(coordinator)
    }
}

/// Owns the text view: switching notes, smart typing, Format actions, Focus and
/// Typewriter modes, statistics.
final class MobileEditorCoordinator: NSObject, UITextViewDelegate, NoteEditor {
    weak var library: Library?
    weak var state: MobileState?
    let textView: MobileTextView
    private let engine: EditorTextEngine

    private(set) var displayedNoteID: Note.ID?
    private var isReplacingText = false
    private var isAdjustingSelection = false
    private var statisticsTask: Task<Void, Never>?
    private var selections: [Note.ID: NSRange] = [:]
    /// The selection as of the last change, to tell an arrow-key step from a jump.
    private var lastSelection = NSRange(location: 0, length: 0)
    /// When the finger last touched the text: selection changes right after
    /// come from taps, not the keyboard.
    private var lastTouch = Date.distantPast
    /// A touch went down on a link or task box: don't start editing for it.
    private var pendingTapTarget = false

    init(configuration: EditorConfiguration, isWide: Bool) {
        textView = MobileTextView(usingTextLayoutManager: true)
        engine = EditorTextEngine(storage: textView.textStorage, configuration: configuration, hangsMarkers: isWide)
        super.init()
        textView.setUp(styleSheet: engine.styleSheet)
        engine.attach(to: textView.textLayoutManager)
        textView.delegate = self
        textView.onFormat = { [weak self] action in self?.perform(action) }
        textView.onOutdent = { [weak self] in self?.shift(outdent: true) }
        engine.isComposing = { [weak textView] in textView?.markedTextRange != nil }

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.delegate = self
        textView.addGestureRecognizer(tap)
    }

    func apply(_ configuration: EditorConfiguration, isWide: Bool) {
        guard configuration != engine.configuration || isWide != engine.hangsMarkers else { return }
        let change = engine.apply(configuration, hangsMarkers: isWide, selection: textView.selectedRange)
        if change.contains(.preview) {
            if configuration.preview { textView.resignFirstResponder() }
            textView.isEditable = displayedNoteID != nil && !configuration.preview
        }
        if change.contains(.styleSheet) {
            textView.apply(engine.styleSheet)
        }
        textView.typewriter = configuration.typewriter
        textView.setNeedsLayout()
        centerCaretIfNeeded()
    }

    // MARK: NoteEditor

    var isCaretInTitleLine: Bool {
        let string = textView.textStorage.mutableString
        let first = string.rangeOfCharacter(from: CharacterSet.whitespacesAndNewlines.inverted)
        guard first.location != NSNotFound else { return true }
        var contentsEnd = 0
        string.getLineStart(nil, end: nil, contentsEnd: &contentsEnd, for: NSRange(location: first.location, length: 0))
        return textView.selectedRange.location <= contentsEnd
    }

    func display(_ note: Note?) {
        if let current = displayedNoteID { selections[current] = textView.selectedRange }
        displayedNoteID = note?.id
        replaceText(with: note?.text ?? "")
        textView.isEditable = note != nil && !engine.configuration.preview
        textView.undoManager?.removeAllActions()
        if let note, let selection = selections[note.id] {
            textView.selectedRange = clamped(selection)
            textView.scrollRangeToVisible(textView.selectedRange)
        } else {
            textView.selectedRange = NSRange(location: 0, length: 0)
            textView.setContentOffset(CGPoint(x: 0, y: -textView.adjustedContentInset.top), animated: false)
        }
        afterChange()
    }

    func currentText() -> String {
        textView.text
    }

    func reloadText(_ text: String) {
        let selection = textView.selectedRange
        let offset = textView.contentOffset
        replaceText(with: text)
        textView.undoManager?.removeAllActions()
        textView.selectedRange = clamped(selection)
        textView.setContentOffset(offset, animated: false)
        afterChange()
    }

    /// Called for a new note (and Return in the iPad list): start typing,
    /// leaving Preview.
    func focus() {
        pendingTapTarget = false
        if engine.configuration.preview {
            state?.isPreviewing = false
            textView.isEditable = displayedNoteID != nil
        }
        textView.becomeFirstResponder()
    }

    // MARK: Format

    func perform(_ action: FormatAction) {
        guard textView.isEditable else { return }
        let text = textView.textStorage.mutableString
        guard let edit = action.edit(in: text, selection: textView.selectedRange, clipboard: UIPasteboard.general.string) else { return }
        apply(edit)
    }

    private func shift(outdent: Bool) {
        let text = textView.textStorage.mutableString
        if let edit = MarkdownEditing.shiftLines(in: text, selection: textView.selectedRange, outdent: outdent, listsOnly: true) {
            apply(edit)
        }
    }

    /// Applies an edit through UITextInput so it's undoable as one step.
    private func apply(_ edit: TextEdit) {
        let undoManager = textView.undoManager
        undoManager?.beginUndoGrouping()
        for replacement in edit.replacements.reversed() {
            guard let start = textView.position(from: textView.beginningOfDocument, offset: replacement.range.location),
                  let end = textView.position(from: start, offset: replacement.range.length),
                  let range = textView.textRange(from: start, to: end) else { continue }
            textView.replace(range, withText: replacement.string)
        }
        undoManager?.endUndoGrouping()
        textView.selectedRange = clamped(edit.selection)
        textViewDidChange(textView)
    }

    // MARK: UITextViewDelegate

    func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        guard textView.markedTextRange == nil else { return true }
        let string = textView.textStorage.mutableString
        // Backspace right after a bullet, task box, heading or quote marker
        // removes that markup, which the page doesn't show as text.
        let selection = textView.selectedRange
        if text.isEmpty, range.length == 1, selection.length == 0, NSMaxRange(range) == selection.location,
           let edit = engine.markupDeletion(for: selection) {
            apply(edit)
            return false
        }
        if text == "\n", let edit = MarkdownEditing.newline(in: string, selection: range) {
            apply(edit)
            return false
        }
        if text == "\t", let edit = MarkdownEditing.shiftLines(in: string, selection: range, outdent: false, listsOnly: true) {
            apply(edit)
            return false
        }
        return true
    }

    func textViewDidChange(_ textView: UITextView) {
        guard !isReplacingText, let id = displayedNoteID else { return }
        library?.editorDidChange(noteID: id, prefix: prefix())
        afterChange()
    }

    func textViewDidChangeSelection(_ textView: UITextView) {
        guard !isReplacingText, !isAdjustingSelection else { return }
        // The caret never rests inside hidden markup. Only an arrow-key step
        // (no recent touch) may leave the line backwards.
        let fromKeyboard = Date().timeIntervalSince(lastTouch) > 0.6
        let adjusted = engine.adjustedSelection(textView.selectedRange, previous: fromKeyboard ? lastSelection : nil)
        if adjusted != textView.selectedRange {
            isAdjustingSelection = true
            textView.selectedRange = adjusted
            isAdjustingSelection = false
        }
        lastSelection = textView.selectedRange
        engine.selectionDidChange(textView.selectedRange)
        centerCaretIfNeeded()
    }

    /// A tap on a link (or a task box) shouldn't also bring up the keyboard.
    func textViewShouldBeginEditing(_ textView: UITextView) -> Bool {
        !pendingTapTarget
    }

    func textViewDidBeginEditing(_ textView: UITextView) {
        state?.isEditorFocused = true
    }

    func textViewDidEndEditing(_ textView: UITextView) {
        state?.isEditorFocused = false
    }

    /// The selection menu gets a Format submenu: formatting stays out of sight
    /// until it's asked for.
    func textView(_ textView: UITextView, editMenuForTextIn range: NSRange, suggestedActions: [UIMenuElement]) -> UIMenu? {
        guard textView.isEditable else { return nil }
        return UIMenu(children: suggestedActions + [MobileTextView.formatMenu { [weak self] action in self?.perform(action) }])
    }

    // MARK: Links and task boxes

    /// A point in the text view, in text container coordinates.
    private func containerPoint(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x - textView.textContainerInset.left, y: point.y - textView.textContainerInset.top)
    }

    /// Links open on a tap while reading (not typing) and in Preview; task
    /// boxes tick on a tap any time.
    private func tapTarget(at point: CGPoint) -> (task: Int?, link: Int?) {
        let container = containerPoint(point)
        if let line = engine.taskBox(at: container) { return (line, nil) }
        guard engine.configuration.preview || !textView.isFirstResponder,
              let index = engine.characterIndex(at: container), engine.link(at: index) != nil else { return (nil, nil) }
        return (nil, index)
    }

    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
        defer { pendingTapTarget = false }
        guard recognizer.state == .ended else { return }
        let target = tapTarget(at: recognizer.location(in: textView))
        if let line = target.task {
            toggleTask(atLine: line)
        } else if let index = target.link {
            openLink(at: index)
        }
    }

    private func toggleTask(atLine location: Int) {
        guard displayedNoteID != nil, let edit = engine.toggleTaskEdit(at: location) else { return }
        let selection = textView.selectedRange
        let wasEditable = textView.isEditable
        textView.isEditable = true
        apply(TextEdit(edit.replacements, selection: selection))
        textView.isEditable = wasEditable
        UISelectionFeedbackGenerator().selectionChanged()
    }

    private func openLink(at index: Int) {
        guard let link = engine.link(at: index), let destination = engine.destination(of: link.target) else { return }
        switch destination {
        case .external(let url):
            UIApplication.shared.open(url)
        case .file(let path):
            if let note = library?.note(linkedAs: path) {
                library?.selectedID = note.id
            } else if let directory = library?.selectedNote?.fileURL?.deletingLastPathComponent() {
                UIApplication.shared.open(URL(fileURLWithPath: path, relativeTo: directory))
            }
        case .anchor(let location):
            textView.scrollRangeToVisible(NSRange(location: location, length: 0))
        }
    }

    // MARK: Typewriter, statistics

    private func centerCaretIfNeeded() {
        guard engine.configuration.typewriter, let end = textView.selectedTextRange?.end else { return }
        let caret = textView.caretRect(for: end)
        guard !caret.isNull, !caret.isInfinite else { return }
        let insets = textView.adjustedContentInset
        let visible = textView.bounds.height - insets.top - insets.bottom
        var y = caret.midY - insets.top - visible / 2
        y = min(max(y, -insets.top), max(-insets.top, textView.contentSize.height - textView.bounds.height + insets.bottom))
        if abs(y - textView.contentOffset.y) >= 0.5 {
            textView.setContentOffset(CGPoint(x: textView.contentOffset.x, y: y), animated: false)
        }
    }

    private func afterChange() {
        engine.selectionDidChange(textView.selectedRange)
        centerCaretIfNeeded()
        statisticsTask?.cancel()
        statisticsTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let self, !Task.isCancelled else { return }
            self.state?.statistics = TextStatistics(self.textView.text)
        }
    }

    // MARK: Helpers

    private func replaceText(with text: String) {
        isReplacingText = true
        defer { isReplacingText = false }
        engine.prepareForNewText()
        textView.text = text
        textView.typingAttributes = engine.styleSheet.baseAttributes
    }

    private func prefix() -> String {
        let string = textView.textStorage.mutableString
        let length = min(string.length, NoteNaming.prefixLength)
        guard length > 0 else { return "" }
        return string.substring(with: string.rangeOfComposedCharacterSequences(for: NSRange(location: 0, length: length)))
    }

    private func clamped(_ range: NSRange) -> NSRange {
        let length = textView.textStorage.length
        let location = min(range.location, length)
        return NSRange(location: location, length: min(range.length, length - location))
    }
}

extension MobileEditorCoordinator: UIGestureRecognizerDelegate {
    /// Runs alongside the text view's own gestures; notes where touches land.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        lastTouch = Date()
        let target = tapTarget(at: touch.location(in: textView))
        pendingTapTarget = target.task != nil || target.link != nil
        if pendingTapTarget {
            // The touch may become a scroll instead of a tap: don't keep blocking editing.
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(600))
                self?.pendingTapTarget = false
            }
        }
        return true
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }
}

/// The writing surface on iPhone and iPad.
final class MobileTextView: UITextView {
    private(set) var styleSheet = EditorStyleSheet(family: .plexMono, size: 17, hangsMarkers: false)
    var typewriter = false
    var onFormat: ((FormatAction) -> Void)?
    var onOutdent: (() -> Void)?

    func setUp(styleSheet: EditorStyleSheet) {
        backgroundColor = EditorTheme.background
        tintColor = EditorTheme.caret
        textContainer.lineFragmentPadding = 0
        alwaysBounceVertical = true
        keyboardDismissMode = .interactive
        allowsEditingTextAttributes = false
        dataDetectorTypes = []
        smartQuotesType = .no
        smartDashesType = .no
        inlinePredictionType = .no
        isFindInteractionEnabled = true
        contentInsetAdjustmentBehavior = .automatic
        inputAccessoryView = makeAccessoryBar()
        apply(styleSheet)
    }

    func apply(_ styleSheet: EditorStyleSheet) {
        self.styleSheet = styleSheet
        typingAttributes = styleSheet.baseAttributes
        setNeedsLayout()
    }

    // MARK: Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = bounds.width
        let margin: CGFloat = traitCollection.horizontalSizeClass == .regular ? EditorTheme.minimumHorizontalMargin : 20
        let columnLeft = max(margin, ((width - styleSheet.columnWidth) / 2).rounded(.down))
        let horizontal = max(0, columnLeft - styleSheet.gutter)
        let visible = bounds.height - safeAreaInsets.top
        let top = typewriter ? max(24, visible / 2 - styleSheet.lineHeight / 2) : (traitCollection.horizontalSizeClass == .regular ? 48 : 16)
        let bottom = typewriter ? visible / 2 : visible * 0.4
        let insets = UIEdgeInsets(top: top.rounded(), left: horizontal, bottom: bottom.rounded(), right: horizontal)
        if textContainerInset != insets { textContainerInset = insets }
    }

    // MARK: Caret

    /// iA's caret: a thicker bar, centered in the line.
    override func caretRect(for position: UITextPosition) -> CGRect {
        var rect = super.caretRect(for: position)
        guard !rect.isNull, !rect.isInfinite else { return rect }
        let scale = traitCollection.displayScale > 0 ? traitCollection.displayScale : 2
        func snap(_ value: CGFloat) -> CGFloat { (value * scale).rounded() / scale }
        let size = styleSheet.fonts.regular.pointSize
        // Body lines get iA's caret; taller heading lines get a taller one.
        let height = max(rect.height, snap(size * EditorTheme.caretHeightRatio))
        rect.origin.y = snap(rect.midY - height / 2)
        rect.size.height = height
        rect.size.width = max(2, snap(size * EditorTheme.caretWidthRatio))
        return rect
    }

    // MARK: Keyboard

    override var keyCommands: [UIKeyCommand]? {
        let outdent = UIKeyCommand(input: "\t", modifierFlags: .shift, action: #selector(outdentLine))
        outdent.wantsPriorityOverSystemBehavior = true
        return [outdent]
    }

    @objc private func outdentLine() {
        onOutdent?()
    }

    /// A slim row above the keyboard: the Format menu, undo/redo, hide keyboard.
    private func makeAccessoryBar() -> UIView {
        let bar = UIInputView(frame: CGRect(x: 0, y: 0, width: 0, height: 44), inputViewStyle: .keyboard)
        bar.allowsSelfSizing = true

        func button(_ symbol: String, _ label: String, action: UIAction? = nil, menu: UIMenu? = nil) -> UIButton {
            var configuration = UIButton.Configuration.plain()
            configuration.image = UIImage(systemName: symbol)
            configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 17, weight: .regular)
            let button = UIButton(configuration: configuration, primaryAction: action)
            button.accessibilityLabel = label
            if let menu {
                button.menu = menu
                button.showsMenuAsPrimaryAction = true
            }
            return button
        }

        let format = button("textformat", "Format", menu: Self.formatMenu { [weak self] in self?.onFormat?($0) })
        let undo = button("arrow.uturn.backward", "Undo", action: UIAction { [weak self] _ in self?.undoManager?.undo() })
        let redo = button("arrow.uturn.forward", "Redo", action: UIAction { [weak self] _ in self?.undoManager?.redo() })
        let dismiss = button("keyboard.chevron.compact.down", "Hide Keyboard", action: UIAction { [weak self] _ in self?.resignFirstResponder() })

        let stack = UIStackView(arrangedSubviews: [format, UIView(), undo, redo, dismiss])
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: bar.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: bar.layoutMarginsGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: bar.topAnchor),
            stack.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
            bar.heightAnchor.constraint(equalToConstant: 44),
        ])
        return bar
    }

    /// The Format menu, shared by the selection menu and the keyboard row.
    static func formatMenu(_ perform: @escaping (FormatAction) -> Void) -> UIMenu {
        func item(_ action: FormatAction, _ symbol: String) -> UIAction {
            UIAction(title: action.title, image: UIImage(systemName: symbol)) { _ in perform(action) }
        }
        let inline = UIMenu(options: .displayInline, children: [
            item(.bold, "bold"), item(.italic, "italic"), item(.strikethrough, "strikethrough"),
            item(.inlineCode, "chevron.left.forwardslash.chevron.right"), item(.link, "link"),
        ])
        let headings = UIMenu(title: "Heading", image: UIImage(systemName: "number"), children:
            (1...6).map { item(.heading($0), "\($0).square") } + [item(.heading(0), "text.alignleft")])
        let blocks = UIMenu(options: .displayInline, children: [
            headings,
            item(.bulletedList, "list.bullet"), item(.numberedList, "list.number"),
            item(.taskList, "checklist"), item(.toggleTaskDone, "checkmark.square"),
            item(.blockquote, "text.quote"), item(.codeBlock, "curlybraces"), item(.horizontalRule, "minus"),
        ])
        return UIMenu(title: "Format", image: UIImage(systemName: "textformat"), children: [inline, blocks])
    }
}
