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
    /// Bumped to give the sidebar's list the keyboard (browsing with ↑/↓
    /// went on into another window).
    var sidebarFocusRequest = 0
    /// The note being renamed (File ▸ Rename…), if any.
    var renaming: Note?
    /// The password sheet: setting one, changing it, or unlocking for a command.
    var passwordRequest: PasswordRequest?
    /// What's showing above the content: a menu, a panel or the search palette.
    var overlay: ChromeOverlay?
    /// Where the "Aa" button is, for its panel.
    @ObservationIgnored var textSettingsAnchor: CGRect = .zero
    /// The text settings panel (font, size, theme) is open.
    var isShowingTextSettings: Bool {
        get { if case .textSettings = overlay { true } else { false } }
        set {
            if newValue { present(.textSettings(anchor: textSettingsAnchor)) } else if isShowingTextSettings { dismissOverlay() }
        }
    }
    /// The tab under the pointer: it shows its close button (and a middle
    /// click closes it).
    var hoveredTab: ObjectIdentifier?
    /// The folder the sidebar looks into ("Show Only This Folder"); the
    /// root shows the whole library.
    var scope: FolderPath = .root
    /// The folder whose name is being edited in its row.
    var renamingFolder: FolderPath?
    /// The sidebar row the keyboard is on (a folder; on a note, the note is
    /// open, except while Shift extends a selection).
    var sidebarCursor: String?
    /// Rows picked with Shift, for acting on several at once.
    var sidebarSelection: Set<String> = []
    /// Where a Shift selection started.
    @ObservationIgnored var selectionAnchor: String?
    /// Bumped by File ▸ Move to Trash (⌘⌫) while the sidebar has the keyboard:
    /// the sidebar trashes what's picked, the folder it's on, or the note.
    var sidebarDeleteRequest = 0
    /// Views offering our own menu on a right-click: given the point (window
    /// coordinates, from the top left), the items, or nil when it isn't theirs.
    @ObservationIgnored var secondaryClickHandlers: [String: (CGPoint) -> [ChromeMenuItem]?] = [:]

    /// A right-click (or Control-click) in the window: our menu for what's
    /// under it, or, with an overlay open and nothing to offer, closing it.
    /// Returns whether the click was taken.
    func secondaryClick(at point: CGPoint) -> Bool {
        for handler in secondaryClickHandlers.values {
            guard let items = handler(point), !items.isEmpty else { continue }
            present(.menu(ChromeMenu(items: items), at: point))
            return true
        }
        if overlay != nil {
            dismissOverlay()
            return true
        }
        return false
    }

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
