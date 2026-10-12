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

    private var preferences = EditorPreferences()
    @AppStorage(PreferenceKey.showCounter) private var showCounter = false

    init(library: Library, windowState: WindowState, onUserEdit: @escaping () -> Void = {}) {
        self.library = library
        self.windowState = windowState
        self.onUserEdit = onUserEdit
    }

    var body: some View {
        GeometryReader { proxy in
            EditorView(
                library: library,
                windowState: windowState,
                configuration: preferences.configuration(preview: windowState.isPreviewing),
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
}
