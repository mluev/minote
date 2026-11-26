import AppKit
import MinoteEditor
import MinoteKit
import SwiftUI

enum SidebarMetrics {
    static let defaultWidth = 260.0
    static let widths = 200.0...400.0
    /// The rounding of a note row, and of a tab in the bar: one shape for
    /// everything that can be selected in the chrome.
    static let rowCornerRadius: CGFloat = 8
    /// How far each folder level steps in.
    static let indent: CGFloat = 16
    /// Every row of the list, folder or note: one line.
    static let rowHeight: CGFloat = 28
    /// The column folder and note icons share.
    static let iconWidth: CGFloat = 16
}

/// The left column: a header level with the tab bar (the window buttons, the
/// sidebar toggle, Search and "New Note"), the library bar, and the notes. It
/// runs the window's full height, on the same paper as the tab bar.
struct SidebarColumn: View {
    @Bindable var library: Library
    @Bindable var state: WindowState
    let workspace: Workspace
    let palette: EditorPalette

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                WindowButtonsSpace(width: state.windowButtonsWidth)
                SidebarToggle(state: state, palette: palette)
                Spacer(minLength: 0)
                Button {
                    state.toggle(.search)
                } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 13.5, weight: .regular))
                }
                .buttonStyle(ChromeButtonStyle(palette: palette, isActive: state.overlay == .search))
                .help("Search (⌘J)")
                .accessibilityLabel("Search")
                .disabled(library.isLibraryLocked)
                Button {
                    workspace.newNote()
                } label: {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 13.5, weight: .regular))
                }
                .buttonStyle(ChromeButtonStyle(palette: palette))
                .help("New Note")
                .accessibilityLabel("New Note")
            }
            .padding(.trailing, 10)
            .frame(height: TitlebarLayout.height)
            .background(WindowDragArea())

            LibraryBar(library: library, state: state, workspace: workspace, preferences: workspace.sidebar, palette: palette)

            SidebarView(library: library, state: state, workspace: workspace)
        }
        .background(Color(nsColor: palette.chrome))
    }
}

/// Under the search field: where the list is (the library, or a path back
/// from the folder looked into), the view menu and New Folder.
private struct LibraryBar: View {
    @Bindable var library: Library
    @Bindable var state: WindowState
    let workspace: Workspace
    @Bindable var preferences: SidebarPreferences
    let palette: EditorPalette
    @ViewState private var anchor: CGRect = .zero

    var body: some View {
        HStack(spacing: 2) {
            PathBack(scope: $state.scope, palette: palette)
            Spacer(minLength: 4)
            viewMenu
            Button {
                workspace.newFolder(in: state.scope, window: workspace.window(for: state))
            } label: {
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 12.5))
            }
            .buttonStyle(ChromeButtonStyle(palette: palette, size: 26))
            .help("New Folder")
            .accessibilityLabel("New Folder")
            .disabled(library.isLibraryLocked)
        }
        .padding(.leading, 14)
        .padding(.trailing, 10)
        .frame(height: 30)
    }

    private var viewMenu: some View {
        let isOpen: Bool = if case .viewOptions = state.overlay { true } else { false }
        return Button {
            if isOpen { state.dismissOverlay() } else { state.present(.viewOptions(anchor: anchor)) }
        } label: {
            Image(systemName: "line.3.horizontal.decrease")
                .font(.system(size: 12.5))
        }
        .buttonStyle(ChromeButtonStyle(palette: palette, isActive: isOpen, size: 26))
        .windowFrame { anchor = $0 }
        .help("View Options")
        .accessibilityLabel("View Options")
    }
}

/// "Notes", or "Notes ▸ Work ▸ Clients" while looking into a folder: each
/// part steps back to that folder.
private struct PathBack: View {
    @Binding var scope: FolderPath
    let palette: EditorPalette

    var body: some View {
        HStack(spacing: 3) {
            crumb("Notes", .root)
            ForEach(Array(scope.components.indices), id: \.self) { index in
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Color(nsColor: palette.syntax))
                crumb(scope.components[index], FolderPath(Array(scope.components.prefix(index + 1))))
            }
        }
        .lineLimit(1)
    }

    @ViewBuilder
    private func crumb(_ title: String, _ path: FolderPath) -> some View {
        let isCurrent = path == scope
        Button(title) { scope = path }
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Color(nsColor: isCurrent ? palette.text : palette.quote))
            .disabled(isCurrent)
            .help(isCurrent ? "" : "Show “\(title)”")
    }
}

/// The sidebar's edge: a hairline, wider to the pointer, dragged to resize.
struct SidebarDivider: View {
    @Binding var width: Double
    let palette: EditorPalette
    @ViewState private var startWidth: Double?

    var body: some View {
        Rectangle()
            .fill(Color(nsColor: palette.rule))
            .frame(width: 1)
            .overlay {
                Color.clear
                    .frame(width: 9)
                    .contentShape(Rectangle())
                    .pointerStyle(.columnResize)
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { value in
                                let start = startWidth ?? width
                                startWidth = start
                                let proposed = start + value.translation.width
                                width = min(max(proposed, SidebarMetrics.widths.lowerBound), SidebarMetrics.widths.upperBound).rounded()
                            }
                            .onEnded { _ in startWidth = nil }
                    )
            }
            .zIndex(1)
    }
}
