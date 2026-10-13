import MinoteKit
import SwiftUI

/// SwiftUI's `State` property wrapper. In the newest SDKs `@State` is a macro
/// whose compiler plugin ships only with Xcode, so a Command Line Tools build
/// can't expand it; this alias names the property wrapper directly.
public typealias ViewState = SwiftUI.State

/// The View menu's settings, shared by the menus and the page.
public struct EditorPreferences: DynamicProperty {
    @AppStorage(PreferenceKey.fontFamily) public var fontFamily = EditorFontFamily.plexMono
    @AppStorage(PreferenceKey.fontSize) public var fontSize = EditorTheme.defaultFontSize
    @AppStorage(PreferenceKey.focusEnabled) public var focusEnabled = false
    @AppStorage(PreferenceKey.focusUnit) public var focusUnit = FocusMode.sentence
    @AppStorage(PreferenceKey.typewriter) public var typewriter = false
    @AppStorage(PreferenceKey.syntaxHighlight) public var syntaxHighlight = false
    @AppStorage(PreferenceKey.showsSyntax) public var showsSyntax = false

    public init() {}

    public func configuration(preview: Bool, paper: EditorPaper = .standard) -> EditorConfiguration {
        EditorConfiguration(family: fontFamily, size: fontSize, focus: focusEnabled ? focusUnit : .off,
                            typewriter: typewriter, partsOfSpeech: syntaxHighlight, showsSyntax: showsSyntax,
                            preview: preview, paper: paper)
    }
}

/// The Format menu, for the Mac's menu bar and the iPad's.
public struct FormatMenuItems: View {
    let isEnabled: Bool
    let perform: (FormatAction) -> Void

    public init(isEnabled: Bool, perform: @escaping (FormatAction) -> Void) {
        self.isEnabled = isEnabled
        self.perform = perform
    }

    public var body: some View {
        item(.bold)
        item(.italic)
        item(.strikethrough)
        item(.inlineCode)
        item(.link)
        Divider()
        Menu("Heading") {
            ForEach(1...6, id: \.self) { item(.heading($0)) }
            Divider()
            item(.heading(0))
        }
        Divider()
        item(.bulletedList)
        item(.numberedList)
        item(.taskList)
        item(.toggleTaskDone)
        Divider()
        item(.blockquote)
        item(.codeBlock)
        item(.horizontalRule)
        Divider()
        item(.shiftRight)
        item(.shiftLeft)
    }

    private func item(_ action: FormatAction) -> some View {
        Button(action.title) { perform(action) }
            .keyboardShortcut(action.shortcut)
            .disabled(!isEnabled)
    }
}

extension FormatAction {
    var shortcut: KeyboardShortcut? {
        switch self {
        case .bold: KeyboardShortcut("b")
        case .italic: KeyboardShortcut("i")
        case .strikethrough: KeyboardShortcut("x", modifiers: [.command, .shift])
        case .inlineCode: KeyboardShortcut("c", modifiers: [.command, .option])
        case .link: KeyboardShortcut("k")
        case .heading(let level): level == 0 ? nil : KeyboardShortcut(KeyEquivalent(Character("\(level)")))
        case .bulletedList: KeyboardShortcut("l")
        case .numberedList: KeyboardShortcut("l", modifiers: [.command, .option])
        case .taskList: KeyboardShortcut("l", modifiers: [.command, .shift])
        case .toggleTaskDone: KeyboardShortcut(.return)
        case .blockquote: KeyboardShortcut("'")
        case .codeBlock: KeyboardShortcut("b", modifiers: [.command, .option])
        case .horizontalRule: nil
        case .shiftRight: KeyboardShortcut("]")
        case .shiftLeft: KeyboardShortcut("[")
        }
    }
}

extension View {
    /// Shows the library's problems (a failed save, an unreadable file) as alerts.
    @MainActor
    public func libraryErrorAlert(_ library: Library) -> some View {
        alert(
            library.presentedError?.title ?? "",
            isPresented: Binding(
                get: { library.presentedError != nil },
                set: { if !$0 { library.presentedError = nil } }
            ),
            presenting: library.presentedError
        ) { _ in
            Button("OK") {}
        } message: { error in
            Text(error.message)
        }
    }
}
