import MinoteEditor
import MinoteKit
import SwiftUI

/// The page of the tab in front: its editor set up from the View menu, with
/// the word counter. The page sits below the tab bar, never under it.
struct EditorPage: View {
    let tab: PageTab
    let windowState: WindowState
    let workspace: Workspace

    private var preferences = EditorPreferences()
    @AppStorage(PreferenceKey.showCounter) private var showCounter = false
    @AppStorage(PreferenceKey.appearance) private var theme = PageTheme.system

    init(tab: PageTab, windowState: WindowState, workspace: Workspace) {
        self.tab = tab
        self.windowState = windowState
        self.workspace = workspace
    }

    /// A locked note whose text isn't in memory: its panel, not its page.
    private var isSealed: Bool { tab.note?.isSealed == true }

    var body: some View {
        Group {
            if isSealed {
                LockedNotePanel(tab: tab, workspace: workspace, palette: theme.palette)
            } else {
                GeometryReader { proxy in
                    EditorView(
                        editor: tab.editor,
                        configuration: preferences.configuration(preview: tab.isPreviewing, paper: theme.paper),
                        viewportHeight: proxy.size.height
                    )
                }
            }
        }
        .background(Color(nsColor: theme.palette.background))
        .overlay(alignment: .bottomTrailing) {
            if showCounter && !isSealed {
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
