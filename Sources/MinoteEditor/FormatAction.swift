import Foundation
import MinoteKit

/// Everything in the Format menu, on every platform. Each action is plain
/// Markdown typed for the user and applied as one undoable change.
public enum FormatAction: Sendable {
    case bold, italic, strikethrough, inlineCode, link
    case heading(Int)
    case bulletedList, numberedList, taskList, toggleTaskDone, blockquote
    case codeBlock, horizontalRule
    case shiftRight, shiftLeft

    public var title: String {
        switch self {
        case .bold: "Bold"
        case .italic: "Italic"
        case .strikethrough: "Strikethrough"
        case .inlineCode: "Code"
        case .link: "Link"
        case .heading(let level): level == 0 ? "Body Text" : "Heading \(level)"
        case .bulletedList: "Bulleted List"
        case .numberedList: "Numbered List"
        case .taskList: "Task List"
        case .toggleTaskDone: "Mark Task as Done"
        case .blockquote: "Quote"
        case .codeBlock: "Code Block"
        case .horizontalRule: "Horizontal Rule"
        case .shiftRight: "Shift Right"
        case .shiftLeft: "Shift Left"
        }
    }

    /// The edit this action makes, or nil when it doesn't apply (e.g. marking a
    /// task done on a line that isn't a task).
    public func edit(in text: NSString, selection: NSRange, clipboard: String?) -> TextEdit? {
        switch self {
        case .bold: MarkdownEditing.toggleInline("**", in: text, selection: selection)
        case .italic: MarkdownEditing.toggleInline("_", in: text, selection: selection)
        case .strikethrough: MarkdownEditing.toggleInline("~~", in: text, selection: selection)
        case .inlineCode: MarkdownEditing.toggleInline("`", in: text, selection: selection)
        case .link: MarkdownEditing.insertLink(in: text, selection: selection, url: Self.url(from: clipboard))
        case .heading(let level): MarkdownEditing.toggleHeading(level: level, in: text, selection: selection)
        case .bulletedList: MarkdownEditing.toggle(.bullet, in: text, selection: selection)
        case .numberedList: MarkdownEditing.toggle(.numbered, in: text, selection: selection)
        case .taskList: MarkdownEditing.toggle(.task, in: text, selection: selection)
        case .toggleTaskDone: MarkdownEditing.toggleTaskDone(in: text, selection: selection)
        case .blockquote: MarkdownEditing.toggle(.quote, in: text, selection: selection)
        case .codeBlock: MarkdownEditing.toggleCodeBlock(in: text, selection: selection)
        case .horizontalRule: MarkdownEditing.insertHorizontalRule(in: text, selection: selection)
        case .shiftRight: MarkdownEditing.shiftLines(in: text, selection: selection, outdent: false, listsOnly: false)
        case .shiftLeft: MarkdownEditing.shiftLines(in: text, selection: selection, outdent: true, listsOnly: false)
        }
    }

    /// A URL on the clipboard becomes the link destination.
    static func url(from clipboard: String?) -> String? {
        guard let string = clipboard?.trimmingCharacters(in: .whitespacesAndNewlines),
              !string.contains(where: \.isWhitespace),
              let url = URL(string: string), let scheme = url.scheme?.lowercased(),
              ["http", "https", "mailto"].contains(scheme)
        else { return nil }
        return string
    }
}
