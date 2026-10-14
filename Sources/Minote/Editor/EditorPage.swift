import MinoteEditor
import MinoteKit
import SwiftUI

/// The page: the editor set up from the View menu, with the word counter and
/// the text settings button. Every tab shows it beside the sidebar.
struct EditorPage: View {
    let editor: EditorCoordinator
    let windowState: WindowState
    var onUserEdit: () -> Void = {}

    private var preferences = EditorPreferences()
    @AppStorage(PreferenceKey.showCounter) private var showCounter = false
    @AppStorage(PreferenceKey.appearance) private var theme = PageTheme.system

    init(editor: EditorCoordinator, windowState: WindowState, onUserEdit: @escaping () -> Void = {}) {
        self.editor = editor
        self.windowState = windowState
        self.onUserEdit = onUserEdit
    }

    var body: some View {
        GeometryReader { proxy in
            EditorView(
                editor: editor,
                configuration: preferences.configuration(preview: windowState.isPreviewing, paper: theme.paper),
                topInset: proxy.safeAreaInsets.top,
                viewportHeight: proxy.size.height + proxy.safeAreaInsets.top,
                onUserEdit: onUserEdit
            )
            .ignoresSafeArea()
        }
        .background(Color(nsColor: theme.palette.background))
        .background(WindowBackground(color: theme.palette.background))
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .toolbar {
            // macOS 26 packs a column's items to its leading edge: push this one to the trailing edge.
            if #available(macOS 26, *) {
                ToolbarSpacer(.flexible)
            }
            ToolbarItem {
                TextSettingsButton(windowState: windowState)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if showCounter {
                WordCounter(windowState: windowState)
                    .padding(8)
            }
        }
        .onChange(of: showCounter, initial: true) { _, shows in
            windowState.showsCounter = shows
            if shows { windowState.editor?.refreshStatistics() }
            // The outline keeps clear of the counter.
            windowState.editor?.outline.setNeedsUpdate()
        }
    }
}
