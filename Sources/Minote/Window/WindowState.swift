import AppKit
import MinoteEditor
import MinoteKit
import SwiftUI

/// One window's state, shared by its tab bar, sidebar, page and the menus.
@Observable
final class WindowState {
    /// The tabs, in the order the tab bar shows them.
    var tabs: [PageTab] = []
    /// The tab in front; its page fills the window.
    var selectedTab: PageTab?

    var isSidebarVisible = true
    var isSidebarFocused = false
    /// Bumped by Edit ▸ Search All Notes to focus the search field.
    var searchFocusRequest = 0
    /// Bumped to give the sidebar's list the keyboard (browsing with ↑/↓
    /// went on into another window).
    var sidebarFocusRequest = 0
    /// The note being renamed (File ▸ Rename…), if any.
    var renaming: Note?
    /// The text settings popover (font, size, theme) is open.
    var isShowingTextSettings = false
    /// The tab under the pointer: it shows its close button (and a middle
    /// click closes it).
    var hoveredTab: ObjectIdentifier?

    /// Where the tabs are in the bar, for a tab dropped from another window.
    @ObservationIgnored var strip: TabStripGeometry?

    /// Room the window buttons take at the top left, or nil in full screen,
    /// where they aren't in the window.
    var windowButtonsWidth: CGFloat? = TitlebarLayout.defaultButtonsWidth
}

/// The tabs' part of the bar, in window coordinates (from the top left).
struct TabStripGeometry: Equatable {
    var frame: CGRect
    var tabWidth: CGFloat
    var scrollOffset: CGFloat
}
