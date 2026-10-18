import MinoteEditor
import MinoteKit
import SwiftUI

/// The page of the tab in front: its editor set up from the View menu, with
/// the word counter. The page sits below the tab bar, never under it.
struct EditorPage: View {
    let tab: PageTab
    let windowState: WindowState

    private var preferences = EditorPreferences()
    @AppStorage(PreferenceKey.showCounter) private var showCounter = false
    @AppStorage(PreferenceKey.appearance) private var theme = PageTheme.system

    init(tab: PageTab, windowState: WindowState) {
        self.tab = tab
        self.windowState = windowState
    }

    var body: some View {
        GeometryReader { proxy in
            EditorView(
                editor: tab.editor,
                configuration: preferences.configuration(preview: tab.isPreviewing, paper: theme.paper),
                viewportHeight: proxy.size.height
            )
        }
        .background(Color(nsColor: theme.palette.background))
        .overlay(alignment: .bottomTrailing) {
            if showCounter {
                WordCounter(tab: tab)
                    .padding(8)
            }
        }
        .onChange(of: showCounter, initial: true) { _, shows in
            tab.showsCounter = shows
            if shows { tab.editor.refreshStatistics() }
            // The outline keeps clear of the counter.
            tab.editor.outline.setNeedsUpdate()
        }
        // A file opened from elsewhere reports its own problems; the
        // library's show in one window (`PageView`).
        .libraryErrorAlert(tab.library, isEnabled: tab.file != nil)
    }
}
