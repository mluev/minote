import AppKit
import MinoteEditor
import MinoteKit
import SwiftUI

/// The top of the window, on a solid band of its own above the page: the
/// window buttons and the sidebar toggle (while the sidebar is hidden; it
/// has them otherwise), the tabs, "+", and "Aa" at the far end. Tabs are as
/// wide as fit, up to a maximum; past a minimum the tabs scroll. Each tab
/// is a rounded plate inset in the bar, shaped and colored like a note row in
/// the sidebar. With a single tab there are no tabs to tell apart: the bar
/// takes the page's paper and shows only its buttons, at the same height,
/// so a second tab brings the tabs back without moving the page.
struct TabBar: View {
    let page: PageWindow
    let workspace: Workspace
    @Bindable var state: WindowState
    let palette: EditorPalette

    var body: some View {
        let showsTabs = state.tabs.count > 1
        HStack(spacing: 0) {
            if !state.isSidebarVisible {
                WindowButtonsSpace(width: state.windowButtonsWidth)
                SidebarToggle(state: state, palette: palette)
            }
            TabStrip(page: page, workspace: workspace, state: state, palette: palette, showsTabs: showsTabs)
                .padding(.leading, TabMetrics.stripInset)
            TextSettingsButton(windowState: state, palette: palette)
                .padding(.leading, 6)
                .padding(.trailing, 10)
        }
        .frame(height: TitlebarLayout.height)
        .background {
            ZStack(alignment: .bottom) {
                Color(nsColor: showsTabs ? palette.chrome : palette.background)
                WindowDragArea()
                Rectangle()
                    .fill(Color(nsColor: palette.rule))
                    .frame(height: 1)
                    .opacity(showsTabs ? 1 : 0)
                    .allowsHitTesting(false)
            }
            .animation(.smooth(duration: 0.2), value: showsTabs)
        }
    }
}

/// The tabs' shape in the bar.
private enum TabMetrics {
    /// Between the bar's top or bottom and a tab.
    static let verticalInset: CGFloat = 6
    /// Between two tabs, split between their slots so the layout's tab widths
    /// stay the slots' widths.
    static let gap: CGFloat = 4
    /// Before the first tab.
    static let stripInset: CGFloat = 6
    /// Inside a tab, before its title.
    static let titleInset: CGFloat = 12
    /// The close button: as wide as tall, as far from the tab's end as from
    /// its top.
    static let closeSize: CGFloat = 16
    static let closeInset: CGFloat = (TitlebarLayout.height - 2 * verticalInset - closeSize) / 2
}

/// The tabs, then "+".
private struct TabStrip: View {
    let page: PageWindow
    let workspace: Workspace
    @Bindable var state: WindowState
    let palette: EditorPalette
    /// False with a single tab: the bar shows no tab, only "+".
    let showsTabs: Bool

    @ViewState private var drag: TabDrag?
    @ViewState private var scrollOffset: CGFloat = 0

    var body: some View {
        GeometryReader { proxy in
            // A single tab is laid out as none: "+" takes its place, and a tab
            // dropped from another window lands before or after it.
            let tabs = showsTabs ? state.tabs : []
            let layout = TabStripLayout(count: tabs.count, available: proxy.size.width - NewTabButton.width)
            HStack(spacing: 0) {
                ScrollViewReader { scroller in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 0) {
                            ForEach(Array(tabs.enumerated()), id: \.element.id) { index, tab in
                                item(tab, at: index, in: tabs, layout: layout)
                            }
                        }
                    }
                    .scrollDisabled(!layout.scrolls)
                    .mask { edgeFade(layout) }
                    .frame(width: layout.visibleWidth)
                    .onScrollGeometryChange(for: CGFloat.self, of: { $0.contentOffset.x }) { _, offset in
                        scrollOffset = offset
                    }
                    .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { frame in
                        state.strip = TabStripGeometry(frame: frame, tabWidth: layout.tabWidth, scrollOffset: scrollOffset)
                    }
                    .onChange(of: state.selectedTab?.id, initial: true) { _, id in
                        guard let id, layout.scrolls else { return }
                        withAnimation(.smooth(duration: 0.25)) { scroller.scrollTo(id) }
                    }
                }
                NewTabButton(palette: palette) { workspace.newTab(in: page) }
                Spacer(minLength: 0)
            }
            // The bar's full height, with no tabs to fill it too.
            .frame(height: proxy.size.height)
            .onChange(of: scrollOffset) { _, offset in
                state.strip?.scrollOffset = offset
            }
            .onChange(of: layout.tabWidth) { _, width in
                state.strip?.tabWidth = width
            }
        }
    }

    /// Tabs scrolled out of sight fade out at that edge.
    private func edgeFade(_ layout: TabStripLayout) -> some View {
        let fade: CGFloat = 28
        let leading = layout.scrolls && scrollOffset > 1
        let trailing = layout.scrolls && scrollOffset < layout.contentWidth - layout.visibleWidth - 1
        return HStack(spacing: 0) {
            LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                .frame(width: leading ? fade : 0)
            Color.black
            LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: trailing ? fade : 0)
        }
    }

    private func item(_ tab: PageTab, at index: Int, in tabs: [PageTab], layout: TabStripLayout) -> some View {
        let isSelected = tab === state.selectedTab
        let isHovered = state.hoveredTab == tab.id && drag == nil
        let next = tabs.indices.contains(index + 1) ? tabs[index + 1] : nil
        // A hairline between two tabs that sit on the bar.
        let separates = next != nil && !isSelected && next !== state.selectedTab
            && !isHovered && state.hoveredTab != next?.id && drag == nil
        return TabItem(tab: tab, isSelected: isSelected, isHovered: isHovered, showsSeparator: separates,
                       isLifted: drag?.id == tab.id && drag?.isTornOff == true, palette: palette) {
            page.close(tab)
        }
        .frame(width: layout.tabWidth)
        .offset(x: offset(of: index, layout: layout))
        .zIndex(drag?.id == tab.id ? 1 : 0)
        .id(tab.id)
        .onHover { inside in
            if inside {
                state.hoveredTab = tab.id
            } else if state.hoveredTab == tab.id {
                state.hoveredTab = nil
            }
        }
        .gesture(dragGesture(tab, at: index, layout: layout))
        .contextMenu { contextMenu(for: tab) }
    }

    // MARK: Dragging

    /// Pressing a tab selects it. Dragging it sideways moves it along the bar,
    /// the others stepping aside; pulling it out of the bar drops it into
    /// another window's bar, or into a window of its own.
    private func dragGesture(_ tab: PageTab, at index: Int, layout: TabStripLayout) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { value in
                guard var current = drag else {
                    drag = TabDrag(id: tab.id, from: index, over: index)
                    page.select(tab)
                    // A double-click keeps an untouched tab, as typing would.
                    if Self.isDoubleClick, tab.isUntouched { tab.isEdited = true }
                    return
                }
                current.translation = value.translation
                if !current.isDragging, hypot(value.translation.width, value.translation.height) > 4 {
                    current.isDragging = true
                }
                current.isTornOff = abs(value.translation.height) > TitlebarLayout.height * 0.75
                let over = current.isTornOff ? current.from : layout.dropIndex(from: current.from, translation: value.translation.width)
                if over != current.over {
                    withAnimation(.snappy(duration: 0.2)) {
                        current.over = over
                        drag = current
                    }
                } else {
                    drag = current
                }
                if current.isTornOff {
                    TabDragPreview.shared.show(title: tab.title, italic: tab.isUntouched, palette: palette,
                                               at: page.screenPoint(value.location))
                } else {
                    TabDragPreview.shared.hide()
                }
            }
            .onEnded { value in
                TabDragPreview.shared.hide()
                guard let current = drag else { return }
                if current.isTornOff {
                    drag = nil
                    drop(tab, at: page.screenPoint(value.location))
                } else {
                    withAnimation(.snappy(duration: 0.2)) {
                        if current.over != current.from { page.move(tab, to: current.over) }
                        drag = nil
                    }
                }
            }
    }

    /// The press being handled is a double-click. Only a mouse down or up has
    /// a click count: asking another event raises an exception.
    private static var isDoubleClick: Bool {
        guard let event = NSApp.currentEvent, event.type == .leftMouseDown || event.type == .leftMouseUp else { return false }
        return event.clickCount == 2
    }

    /// A tab let go outside its bar.
    private func drop(_ tab: PageTab, at point: NSPoint) {
        // After the gesture: the window may close under it.
        DispatchQueue.main.async { workspace.drop(tab, at: point) }
    }

    private func offset(of index: Int, layout: TabStripLayout) -> CGFloat {
        guard let drag, drag.isDragging else { return 0 }
        if index == drag.from {
            return drag.isTornOff ? 0 : layout.clampedTranslation(drag.translation.width, from: index)
        }
        return layout.shift(of: index, dragging: drag.from, over: drag.over)
    }

    // MARK: Menu

    @ViewBuilder
    private func contextMenu(for tab: PageTab) -> some View {
        Button("Close Tab") { page.close(tab) }
        Button("Close Other Tabs") { page.closeOtherTabs(than: tab) }
            .disabled(page.tabs.count < 2)
        Button("Close Tabs to the Right") { page.closeTabs(after: tab) }
            .disabled(page.tabs.last === tab)
        Divider()
        if tab.isUntouched {
            Button("Keep Open") { tab.isEdited = true }
        }
        Button("Move Tab to New Window") { workspace.moveToNewWindow(tab) }
            .disabled(page.tabs.count < 2)
        Divider()
        Button("Show in Finder") {
            if let url = tab.file?.url ?? tab.note?.fileURL { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
        .disabled(tab.file == nil && tab.note?.fileURL == nil)
    }
}

/// A tab being pressed or dragged.
private struct TabDrag {
    let id: ObjectIdentifier
    /// Where it was picked up.
    let from: Int
    /// Where it would land.
    var over: Int
    var translation: CGSize = .zero
    /// Moved far enough to be a drag, not a click.
    var isDragging = false
    /// Pulled out of the bar: it leaves this window.
    var isTornOff = false
}

/// One tab: its title (in italics while untouched), and a close button that
/// shows on the tab in front and under the pointer. The tab fills its slot
/// in the layout; its plate is inset in it, so presses between two plates
/// still go to a tab.
private struct TabItem: View {
    let tab: PageTab
    let isSelected: Bool
    let isHovered: Bool
    let showsSeparator: Bool
    let isLifted: Bool
    let palette: EditorPalette
    let close: () -> Void

    var body: some View {
        let showsClose = isSelected || isHovered
        Text(tab.title)
            .font(.system(size: 12.5, weight: isSelected ? .medium : .regular))
            .italic(tab.isUntouched)
            .foregroundStyle(Color(nsColor: isSelected ? palette.text : palette.quote))
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            // The title takes the close button's room while it's hidden.
            .padding(.leading, TabMetrics.titleInset)
            .padding(.trailing, showsClose ? TabMetrics.closeSize + 2 * TabMetrics.closeInset : TabMetrics.titleInset)
            .overlay(alignment: .trailing) {
                TabCloseButton(palette: palette, action: close)
                    .padding(.trailing, TabMetrics.closeInset)
                    .opacity(showsClose ? 1 : 0)
                    .allowsHitTesting(showsClose)
            }
            .background { plate }
            .padding(.horizontal, TabMetrics.gap / 2)
            .padding(.vertical, TabMetrics.verticalInset)
            // A hairline between two tabs that sit on the bar, in the gap.
            .overlay(alignment: .trailing) {
                Rectangle()
                    .fill(Color(nsColor: palette.rule))
                    .frame(width: 1, height: 14)
                    .offset(x: 0.5)
                    .opacity(showsSeparator ? 1 : 0)
            }
        .opacity(isLifted ? 0.35 : 1)
        .contentShape(Rectangle())
        .help(tab.file?.url.path ?? tab.title)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(named: "Close Tab", close)
    }

    /// As a note row in the sidebar: the selection's shade on the tab in
    /// front, a lighter one under the pointer.
    @ViewBuilder
    private var plate: some View {
        if isSelected || isHovered {
            RoundedRectangle(cornerRadius: SidebarMetrics.rowCornerRadius, style: .continuous)
                .fill(Color(nsColor: isSelected ? palette.sidebarSelection : palette.sidebarHover))
        }
    }
}

/// The small × on a tab.
private struct TabCloseButton: View {
    let palette: EditorPalette
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 8.5, weight: .bold))
        }
        // Small and close around its glyph; the bar's other buttons are 28 pt.
        .buttonStyle(ChromeButtonStyle(palette: palette, cornerRadius: 5, size: TabMetrics.closeSize))
        .help("Close Tab")
        .accessibilityLabel("Close Tab")
    }
}

/// "+": a new tab with an empty note.
private struct NewTabButton: View {
    static let width: CGFloat = 40
    let palette: EditorPalette
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
                .font(.system(size: 13, weight: .regular))
        }
        .buttonStyle(ChromeButtonStyle(palette: palette))
        .padding(.leading, 6)
        .frame(width: Self.width, alignment: .leading)
        .help("New Tab")
        .accessibilityLabel("New Tab")
    }
}

/// The room the close, minimize and zoom buttons take at the top left (a
/// little margin in full screen, where they aren't in the window).
struct WindowButtonsSpace: View {
    let width: CGFloat?

    var body: some View {
        Color.clear
            .frame(width: width ?? 10)
            .allowsHitTesting(false)
    }
}

/// Shows or hides the sidebar. It stays in one place: at the top of the
/// sidebar while it shows, at the start of the tab bar while it doesn't.
struct SidebarToggle: View {
    @Bindable var state: WindowState
    let palette: EditorPalette

    var body: some View {
        Button {
            withAnimation(.smooth(duration: 0.22)) { state.isSidebarVisible.toggle() }
        } label: {
            Image(systemName: "sidebar.left")
                .font(.system(size: 14, weight: .regular))
        }
        .buttonStyle(ChromeButtonStyle(palette: palette))
        .help(state.isSidebarVisible ? "Hide Sidebar" : "Show Sidebar")
        .accessibilityLabel(state.isSidebarVisible ? "Hide Sidebar" : "Show Sidebar")
    }
}

/// The bar's buttons: a quiet glyph, a soft plate under the pointer.
struct ChromeButtonStyle: ButtonStyle {
    let palette: EditorPalette
    var cornerRadius: CGFloat = 6
    var isActive = false
    /// The plate's side, at least: what's pressable and what lights up.
    var size: CGFloat = 28

    func makeBody(configuration: Configuration) -> some View {
        Plate(configuration: configuration, palette: palette, cornerRadius: cornerRadius, isActive: isActive, size: size)
    }

    private struct Plate: View {
        let configuration: ButtonStyleConfiguration
        let palette: EditorPalette
        let cornerRadius: CGFloat
        let isActive: Bool
        let size: CGFloat
        @Environment(\.isEnabled) private var isEnabled
        @ViewState private var isHovered = false

        var body: some View {
            let strength = configuration.isPressed || isActive ? 0.13 : isHovered && isEnabled ? 0.07 : 0
            configuration.label
                .frame(minWidth: size, minHeight: size)
                .foregroundStyle(Color(nsColor: isHovered || isActive ? palette.text : palette.quote))
                .opacity(isEnabled ? 1 : 0.4)
                .contentShape(Rectangle())
                .background {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(Color(nsColor: palette.text).opacity(strength))
                }
                .onHover { isHovered = $0 }
        }
    }
}

/// A tab pulled out of its bar, under the pointer until it's let go.
@MainActor
final class TabDragPreview {
    static let shared = TabDragPreview()
    private var panel: NSPanel?

    func show(title: String, italic: Bool, palette: EditorPalette, at point: NSPoint) {
        let size = NSSize(width: 200, height: 36)
        let panel = self.panel ?? makePanel(size: size)
        self.panel = panel
        let chip = TabChip(title: title, italic: italic, palette: palette)
            .frame(width: size.width - 16, height: size.height - 8)
            .padding(4)
            .padding(.horizontal, 4)
        if let host = panel.contentView as? NSHostingView<AnyView> {
            host.rootView = AnyView(chip)
        }
        panel.setFrameOrigin(NSPoint(x: point.x - 60, y: point.y - size.height / 2))
        if !panel.isVisible { panel.orderFront(nil) }
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func makePanel(size: NSSize) -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: AnyView(EmptyView()))
        host.sizingOptions = []
        panel.contentView = host
        return panel
    }

    private struct TabChip: View {
        let title: String
        let italic: Bool
        let palette: EditorPalette

        var body: some View {
            Text(title)
                .font(.system(size: 12.5, weight: .medium))
                .italic(italic)
                .foregroundStyle(Color(nsColor: palette.text))
                .lineLimit(1)
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .background {
                    RoundedRectangle(cornerRadius: SidebarMetrics.rowCornerRadius, style: .continuous)
                        .fill(Color(nsColor: palette.background))
                        .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: SidebarMetrics.rowCornerRadius, style: .continuous)
                        .strokeBorder(Color(nsColor: palette.rule))
                }
        }
    }
}

extension EditorPalette {
    /// The tab bar and the sidebar: one band of the page's paper, a shade darker.
    var chrome: NSColor { sidebarBackground }
}
