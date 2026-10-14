import Foundation

/// Where a note or file being opened goes, given the tab in front. A tab
/// nobody has typed in is a passing look: the next note replaces it. Typing
/// keeps it. A file opened from Finder is a document of its own: it is never
/// replaced and never replaces.
public enum TabPlacement: Equatable, Sendable {
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
    public static func of(isOpen: Bool, front: FrontTab?, forceNewTab: Bool = false) -> TabPlacement {
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

        public init(notes: [String], front: Int) {
            self.notes = notes
            self.front = front
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
            return Window(notes: kept, front: min(before, kept.count - 1))
        })
    }
}
