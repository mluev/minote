import Foundation

/// Where a note or file being opened goes, given the tab in front. A tab
/// nobody has typed in is a passing look: the next note replaces it. Typing
/// keeps it. A file opened from Finder is a document of its own: it is never
/// replaced and never replaces.
public enum OpenPlacement: Equatable, Sendable {
    /// Already open in a tab: that tab comes forward.
    case focusExisting
    /// The front tab shows it instead.
    case replaceFront
    /// A new tab beside the front one.
    case newTab
    /// There's no window to put it in.
    case newWindow

    /// What the tab in front shows.
    public enum FrontTab: Equatable, Sendable {
        case libraryNote(edited: Bool)
        case outsideFile
    }

    /// - Parameters:
    ///   - isOpen: the note or file is already shown in some tab.
    ///   - front: the tab in front, nil when no window is open.
    ///   - forceNewTab: the user asked for a new tab (⌘-click, Open in New Tab).
    public static func of(isOpen: Bool, front: FrontTab?, forceNewTab: Bool = false) -> OpenPlacement {
        if isOpen { return .focusExisting }
        guard let front else { return .newWindow }
        if forceNewTab { return .newTab }
        switch front {
        case .libraryNote(edited: false): return .replaceFront
        case .libraryNote(edited: true), .outsideFile: return .newTab
        }
    }
}

/// The library notes open in tabs, per window, kept across launches by file
/// name. Files opened from Finder aren't kept (their windows never come back).
public struct SavedTabs: Codable, Equatable, Sendable {
    public struct Window: Codable, Equatable, Sendable {
        /// File names, in tab order.
        public var notes: [String]
        /// The tab in front.
        public var front: Int
        /// Notes whose tab nobody typed in (the next note opened replaces
        /// it). Missing in tabs saved before it was kept: none.
        public var untouched: [String]?

        public init(notes: [String], front: Int, untouched: [String]? = nil) {
            self.notes = notes
            self.front = front
            self.untouched = untouched
        }

        public func isUntouched(_ note: String) -> Bool {
            untouched?.contains(note) ?? false
        }
    }

    /// The window in front first.
    public var windows: [Window]

    public init(windows: [Window]) {
        self.windows = windows
    }

    static let key = "OpenTabs"

    public static func load(from defaults: UserDefaults = .standard) -> SavedTabs? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(SavedTabs.self, from: data)
    }

    public func save(to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.key)
    }

    /// The tabs whose notes are still in the library. A window keeps its
    /// order; if its front note is gone, the tab after it comes to the front.
    /// Windows left without tabs are dropped.
    public func restored(existing: Set<String>) -> SavedTabs {
        SavedTabs(windows: windows.compactMap { window in
            let kept = window.notes.filter(existing.contains)
            guard !kept.isEmpty else { return nil }
            let before = window.notes.prefix(max(0, window.front)).filter(existing.contains).count
            let untouched = window.untouched?.filter(existing.contains)
            return Window(notes: kept, front: min(before, kept.count - 1), untouched: untouched?.isEmpty == false ? untouched : nil)
        })
    }
}

/// How a tab bar lays its tabs out: all one width, as wide as fits up to a
/// maximum and never narrower than a minimum; past that the bar scrolls.
public struct TabStripLayout: Equatable, Sendable {
    public static let maxTabWidth = 224.0
    public static let minTabWidth = 112.0

    public let count: Int
    public let tabWidth: Double
    /// Every tab side by side.
    public let contentWidth: Double
    /// The part of the bar the tabs take; the rest is free (and moves the window).
    public let visibleWidth: Double

    public var scrolls: Bool { contentWidth > visibleWidth }

    public init(count: Int, available: Double, minTabWidth: Double = Self.minTabWidth, maxTabWidth: Double = Self.maxTabWidth) {
        let available = max(0, available)
        let fitted = count > 0 ? (available / Double(count)).rounded(.down) : maxTabWidth
        self.count = count
        tabWidth = min(maxTabWidth, max(minTabWidth, fitted))
        contentWidth = tabWidth * Double(count)
        visibleWidth = min(contentWidth, available)
    }

    /// Where a tab dragged sideways by `translation` from `index` lands:
    /// past the middle of a neighbor, it takes its place.
    public func dropIndex(from index: Int, translation: Double) -> Int {
        guard count > 0 else { return 0 }
        let moved = Int((translation / tabWidth).rounded())
        return min(max(index + moved, 0), count - 1)
    }

    /// How far the tab at `index` steps aside while the one at `from` is
    /// dragged over `to`.
    public func shift(of index: Int, dragging from: Int, over to: Int) -> Double {
        if from < to, index > from, index <= to { return -tabWidth }
        if to < from, index >= to, index < from { return tabWidth }
        return 0
    }

    /// The dragged tab follows the pointer, but not past either end.
    public func clampedTranslation(_ translation: Double, from index: Int) -> Double {
        let lower = -Double(index) * tabWidth
        let upper = Double(max(0, count - 1 - index)) * tabWidth
        return min(max(translation, lower), upper)
    }
}
