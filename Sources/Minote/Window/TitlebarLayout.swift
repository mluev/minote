import AppKit
import SwiftUI

/// The window has no titlebar of its own: the tab bar (and the sidebar's
/// header beside it) is the top of the window. The close, minimize and zoom
/// buttons sit in it, centered in its height, and its empty parts move the
/// window like a titlebar does.
enum TitlebarLayout {
    /// The tab bar's height, and the sidebar header's.
    static let height: CGFloat = 40
    /// From the window's left edge to the close button, as from the top edge.
    private static let buttonsLeading: CGFloat = 14
    /// After the zoom button, before whatever the bar shows next.
    private static let buttonsTrailing: CGFloat = 10
    /// The room the buttons take until they're measured.
    static let defaultButtonsWidth: CGFloat = 78

    /// Centers the window buttons in the bar's height. Returns the width they
    /// take from the left edge, or nil in full screen (they aren't in the
    /// window then).
    @discardableResult
    static func placeWindowButtons(in window: NSWindow) -> CGFloat? {
        guard !window.styleMask.contains(.fullScreen) else { return nil }
        let buttons = windowButtons(of: window)
        guard let first = buttons.first, let last = buttons.last,
              let titlebar = first.superview, let container = titlebar.superview else { return defaultButtonsWidth }

        // The titlebar is as tall as the bar, so the buttons aren't clipped.
        var frame = container.frame
        if frame.height != height || frame.maxY != window.frame.height {
            frame.size.height = height
            frame.origin.y = window.frame.height - height
            container.frame = frame
        }
        if titlebar.frame != container.bounds { titlebar.frame = container.bounds }
        for (index, button) in buttons.enumerated() {
            let origin = NSPoint(x: buttonsLeading + CGFloat(index) * buttonsSpacing,
                                 y: ((height - button.frame.height) / 2).rounded())
            if button.frame.origin != origin { button.setFrameOrigin(origin) }
        }
        return (last.frame.maxX + buttonsTrailing).rounded()
    }

    /// From one button's left edge to the next.
    private static let buttonsSpacing: CGFloat = 20

    static func windowButtons(of window: NSWindow) -> [NSButton] {
        [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap(window.standardWindowButton)
    }
}

/// Keeps the window buttons where `TitlebarLayout` puts them: AppKit lays its
/// titlebar out again whenever it likes (resizing, becoming key, leaving full
/// screen), and each time they're put back before anything draws.
final class WindowButtonsKeeper {
    private weak var window: NSWindow?
    private var observers: [NSObjectProtocol] = []
    private var isPlacing = false
    /// The room the buttons take, after each placement.
    var onPlace: ((CGFloat?) -> Void)?

    init(window: NSWindow) {
        self.window = window
    }

    /// Watches the titlebar: call once the window has its frame view.
    func start() {
        guard observers.isEmpty, let window else { return }
        let buttons = TitlebarLayout.windowButtons(of: window)
        let watched = buttons + [buttons.first?.superview, buttons.first?.superview?.superview].compactMap { $0 }
        for view in watched {
            view.postsFrameChangedNotifications = true
            observers.append(NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: view, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated { self?.place() }
            })
        }
        place()
    }

    func place() {
        guard !isPlacing, let window else { return }
        isPlacing = true
        defer { isPlacing = false }
        onPlace?(TitlebarLayout.placeWindowButtons(in: window))
    }

    isolated deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }
}

/// The empty parts of the bar: dragging moves the window, a double-click
/// zooms or minimizes it as set in System Settings ▸ Desktop & Dock.
struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ view: DragView, context: Context) {}

    final class DragView: NSView {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override var mouseDownCanMoveWindow: Bool { false }

        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            if event.clickCount == 2 {
                switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
                case "Minimize": window.performMiniaturize(nil)
                case "None": break
                default: window.performZoom(nil)
                }
            } else {
                window.performDrag(with: event)
            }
        }
    }
}

/// Keeps the hosting window's background on the page's paper: it shows
/// while the window resizes, before the page draws.
struct WindowBackground: NSViewRepresentable {
    let color: NSColor

    func makeNSView(context: Context) -> BackgroundView {
        let view = BackgroundView()
        view.color = color
        return view
    }

    func updateNSView(_ view: BackgroundView, context: Context) {
        view.color = color
    }

    final class BackgroundView: NSView {
        var color: NSColor? {
            didSet { applyColor() }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            applyColor()
        }

        private func applyColor() {
            guard let color, let window, window.backgroundColor != color else { return }
            window.backgroundColor = color
        }
    }
}
