import AppKit
import MinoteEditor

extension WriterTextView {
    /// Runs a Format menu action on the selection.
    func perform(_ action: FormatAction) {
        guard isEditable, let text = textStorage?.mutableString else { return }
        let clipboard = NSPasteboard.general.string(forType: .string)
        guard let edit = action.edit(in: text, selection: selectedRange(), clipboard: clipboard) else {
            NSSound.beep()
            return
        }
        apply(edit, actionName: action.title)
    }
}
