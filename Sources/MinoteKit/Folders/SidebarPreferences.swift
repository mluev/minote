import Foundation
import Observation

/// The sidebar's view settings and the folders closed in it, on this device,
/// shared by every window. Saved as they change.
@MainActor
@Observable
public final class SidebarPreferences {
    public var view: LibraryView {
        didSet { if view != oldValue { view.save(to: defaults) } }
    }

    /// Folders the writer closed, by path.
    public var collapsed: Set<FolderPath> {
        didSet { if collapsed != oldValue { saveCollapsed() } }
    }

    @ObservationIgnored private let defaults: UserDefaults
    static let collapsedKey = "CollapsedFolders"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        view = LibraryView.load(from: defaults)
        collapsed = Set((defaults.stringArray(forKey: Self.collapsedKey) ?? []).map(FolderPath.init(string:)))
    }

    public func isOpen(_ folder: FolderPath) -> Bool { !collapsed.contains(folder) }

    public func toggle(_ folder: FolderPath) {
        if collapsed.contains(folder) { collapsed.remove(folder) } else { collapsed.insert(folder) }
    }

    /// Opens a folder and every folder above it, so it can be seen.
    public func reveal(_ folder: FolderPath) {
        var current: FolderPath? = folder
        var next = collapsed
        while let path = current, !path.isRoot {
            next.remove(path)
            current = path.parent
        }
        collapsed = next
    }

    /// Folders renamed, moved or trashed keep (or drop) their closed state.
    public func follow(_ change: OrganisationChange) {
        switch change {
        case .folderMoved(let from, let to):
            collapsed = Set(collapsed.map { from.rebasing($0, onto: to) })
        case .folderRemoved(let folder):
            collapsed = collapsed.filter { !folder.contains($0) }
        case .noteMoved:
            break
        }
    }

    private func saveCollapsed() {
        defaults.set(collapsed.map(\.string).sorted(), forKey: Self.collapsedKey)
    }
}
