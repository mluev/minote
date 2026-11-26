import AppKit
import MinoteEditor
import MinoteKit
import SwiftUI

/// Something shown above the window's content in Minote's own style: a menu,
/// a panel under a button, or the search palette. Never the system's menus
/// or popovers. One at a time per window (`WindowState.overlay`).
enum ChromeOverlay: Equatable {
    /// A list menu, its top left at a point (a row's right-click menu).
    case menu(ChromeMenu, at: CGPoint)
    /// The sidebar's view options, under their button.
    case viewOptions(anchor: CGRect)
    /// Size, theme and font, under the "Aa" button.
    case textSettings(anchor: CGRect)
    /// Search everything.
    case search

    /// The window's coordinates (from its top left), in which anchors are given.
    nonisolated static let space = "PageWindow"

    /// Opened from the keyboard or a button and shown dimmed behind: the
    /// palette is a moment of its own; menus and panels aren't.
    var dimsWindow: Bool { self == .search }
}

/// How overlays come and go: quick, settled springs; plain fades when the
/// Mac asks for less motion.
enum ChromeMotion {
    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    static var appear: Animation { reduceMotion ? .easeOut(duration: 0.12) : .spring(response: 0.28, dampingFraction: 0.84) }
    static var disappear: Animation { reduceMotion ? .easeOut(duration: 0.1) : .easeOut(duration: 0.13) }
    static var move: Animation { reduceMotion ? .easeOut(duration: 0.1) : .spring(response: 0.24, dampingFraction: 0.9) }

    /// A panel growing out of the point it belongs to.
    static func transition(from anchor: UnitPoint) -> AnyTransition {
        reduceMotion ? .opacity : .scale(scale: 0.94, anchor: anchor).combined(with: .opacity)
    }
}

extension WindowState {
    func present(_ overlay: ChromeOverlay) {
        withAnimation(ChromeMotion.appear) { self.overlay = overlay }
        // Under the pointer now: an arrow, not the page's I-beam.
        NSCursor.arrow.set()
    }

    func dismissOverlay() {
        guard overlay != nil else { return }
        withAnimation(ChromeMotion.disappear) { overlay = nil }
        NSApp.keyWindow?.invalidateCursorRects(for: NSApp.keyWindow?.contentView ?? NSView())
    }

    /// Opens the overlay, or closes it if it's the one showing (a button pressed twice).
    func toggle(_ overlay: ChromeOverlay) {
        if self.overlay == overlay { dismissOverlay() } else { present(overlay) }
    }
}

/// The surface every overlay sits on: the page's paper, a hairline and a
/// soft shadow, rounded like the rest of the chrome.
struct ChromeSurface: ViewModifier {
    let palette: EditorPalette
    var cornerRadius: CGFloat = 12

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color(nsColor: palette.background))
                    .shadow(color: .black.opacity(0.22), radius: 22, y: 10)
                    .shadow(color: .black.opacity(0.08), radius: 2, y: 1)
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color(nsColor: palette.rule))
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

extension View {
    func chromeSurface(_ palette: EditorPalette, cornerRadius: CGFloat = 12) -> some View {
        modifier(ChromeSurface(palette: palette, cornerRadius: cornerRadius))
    }
}

/// Above the window's content: whatever overlay is showing, and a layer
/// that closes it on a click anywhere else.
struct ChromeOverlayLayer: View {
    @Bindable var state: WindowState
    let workspace: Workspace
    let palette: EditorPalette

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                if let overlay = state.overlay {
                    Color.black.opacity(overlay.dimsWindow ? 0.14 : 0.0001)
                        .contentShape(Rectangle())
                        .onTapGesture { state.dismissOverlay() }
                        .transition(.opacity)
                    content(overlay, in: proxy.size)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
        }
        .allowsHitTesting(state.overlay != nil)
    }

    @ViewBuilder
    private func content(_ overlay: ChromeOverlay, in size: CGSize) -> some View {
        switch overlay {
        case .menu(let menu, let point):
            Placed(at: point, in: size) {
                ChromeMenuView(menu: menu, palette: palette, maxHeight: size.height - 16) { state.dismissOverlay() }
            }
            .transition(ChromeMotion.transition(from: .topLeading))
            .id(menu.id)
        case .viewOptions(let anchor):
            // Right-aligned under its button, so it opens over the sidebar it changes.
            Placed(at: CGPoint(x: anchor.maxX, y: anchor.maxY + 6), in: size, alignRight: true) {
                ViewOptionsPanel(library: workspace.library, state: state, workspace: workspace,
                                 preferences: workspace.sidebar, palette: palette)
            }
            .transition(ChromeMotion.transition(from: .topTrailing))
        case .textSettings(let anchor):
            Placed(at: CGPoint(x: anchor.maxX, y: anchor.maxY + 6), in: size, alignRight: true) {
                TextSettingsPanel()
                    .chromeSurface(palette)
                    .onExitCommand { state.dismissOverlay() }
            }
            .transition(ChromeMotion.transition(from: .topTrailing))
        case .search:
            // As tall as the window allows: the field, the footer and a margin
            // below always fit, and the results take what's left (up to 400 pt).
            let top = min(96, size.height * 0.12)
            let chrome = SearchPalette.fieldHeight + SearchPalette.footerHeight + 2
            let results = min(400, max(0, size.height - top - chrome - 16))
            SearchPalette(library: workspace.library, state: state, workspace: workspace, palette: palette,
                          maxResultsHeight: results)
                .frame(width: min(640, size.width - 48))
                .frame(maxWidth: .infinity)
                .padding(.top, top)
                .transition(ChromeMotion.reduceMotion ? .opacity
                            : .scale(scale: 0.97, anchor: .top).combined(with: .opacity).combined(with: .offset(y: -6)))
        }
    }
}

/// Puts its content with its top left (or top right) at a point, moved back
/// inside the window if it would go past an edge.
struct Placed<Content: View>: View {
    let point: CGPoint
    let size: CGSize
    var alignRight = false
    @ViewBuilder let content: Content
    @ViewState private var contentSize: CGSize = .zero

    init(at point: CGPoint, in size: CGSize, alignRight: Bool = false, @ViewBuilder content: () -> Content) {
        self.point = point
        self.size = size
        self.alignRight = alignRight
        self.content = content()
    }

    var body: some View {
        let margin: CGFloat = 8
        let x = alignRight ? point.x - contentSize.width : point.x
        let clampedX = min(max(x, margin), max(margin, size.width - contentSize.width - margin))
        // Not enough room below: above the point instead.
        let fitsBelow = point.y + contentSize.height + margin <= size.height
        let y = fitsBelow ? point.y : max(margin, point.y - contentSize.height)
        content
            .fixedSize()
            .onGeometryChange(for: CGSize.self) { $0.size } action: { contentSize = $0 }
            .offset(x: clampedX, y: y)
            .opacity(contentSize == .zero ? 0 : 1)
    }
}

extension View {
    /// Reports the view's frame in the window's coordinates, for an overlay anchored to it.
    func windowFrame(_ update: @escaping (CGRect) -> Void) -> some View {
        onGeometryChange(for: CGRect.self) { $0.frame(in: .named(ChromeOverlay.space)) } action: { update($0) }
    }
}
