import MinoteEditor
import MinoteKit
import SwiftUI

/// The page: the editor set up from the View menu, with the word counter.
/// The library window shows it beside the sidebar; an opened file's window
/// shows only this.
struct EditorPage: View {
    let library: Library
    let windowState: WindowState
    var onUserEdit: () -> Void = {}

    @AppStorage(PreferenceKey.fontFamily) private var fontFamily = EditorFontFamily.plexMono
    @AppStorage(PreferenceKey.fontSize) private var fontSize = EditorTheme.defaultFontSize
    @AppStorage(PreferenceKey.focusEnabled) private var focusEnabled = false
    @AppStorage(PreferenceKey.focusUnit) private var focusUnit = FocusMode.sentence
    @AppStorage(PreferenceKey.typewriter) private var typewriter = false
    @AppStorage(PreferenceKey.syntaxHighlight) private var syntaxHighlight = false
    @AppStorage(PreferenceKey.showCounter) private var showCounter = false
    @AppStorage(PreferenceKey.showsSyntax) private var showsSyntax = false

    var body: some View {
        GeometryReader { proxy in
            EditorView(
                library: library,
                windowState: windowState,
                configuration: configuration,
                topInset: proxy.safeAreaInsets.top,
                viewportHeight: proxy.size.height + proxy.safeAreaInsets.top,
                onUserEdit: onUserEdit
            )
            .ignoresSafeArea()
        }
        .background(Color(nsColor: EditorTheme.background))
        .overlay(alignment: .bottomTrailing) {
            if showCounter {
                WordCounter(windowState: windowState)
                    .padding(8)
            }
        }
        .onChange(of: showCounter, initial: true) { _, shows in
            windowState.showsCounter = shows
            if shows { windowState.editor?.refreshStatistics() }
        }
    }

    private var configuration: EditorConfiguration {
        EditorConfiguration(
            family: fontFamily,
            size: fontSize,
            focus: focusEnabled ? focusUnit : .off,
            typewriter: typewriter,
            partsOfSpeech: syntaxHighlight,
            showsSyntax: showsSyntax,
            preview: windowState.isPreviewing
        )
    }
}

extension View {
    /// Shows the library's problems (a failed save, an unreadable file) as alerts.
    func libraryErrorAlert(_ library: Library) -> some View {
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
