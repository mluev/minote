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
}

/// The left column: a header level with the tab bar (the window buttons, the
/// sidebar toggle and "New Note"), the search field, and the notes. It runs
/// the window's full height, on the same paper as the tab bar.
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

            SearchField(text: $library.searchText, focusRequest: state.searchFocusRequest, palette: palette)
                .padding(.horizontal, 10)
                .padding(.top, 4)
                .padding(.bottom, 6)

            SidebarView(library: library, state: state, workspace: workspace)
        }
        .background(Color(nsColor: palette.chrome))
    }
}

/// Searches every note's text; Escape clears it.
private struct SearchField: View {
    @Binding var text: String
    let focusRequest: Int
    let palette: EditorPalette
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Color(nsColor: palette.syntax))
            TextField("Search", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .foregroundStyle(Color(nsColor: palette.text))
                .focused($isFocused)
                .onExitCommand { text = "" }
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Color(nsColor: palette.syntax))
                }
                .buttonStyle(.plain)
                .help("Clear Search")
                .accessibilityLabel("Clear Search")
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 28)
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color(nsColor: palette.background).opacity(isFocused ? 1 : 0.6))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(Color(nsColor: palette.rule).opacity(isFocused ? 1 : 0.6))
        }
        .contentShape(Rectangle())
        .onTapGesture { isFocused = true }
        .onChange(of: focusRequest) { isFocused = true }
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
