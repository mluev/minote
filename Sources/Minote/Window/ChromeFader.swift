import AppKit
import SwiftUI

/// Fades the traffic lights and toolbar out while the user types, and brings
/// them back when the mouse moves. Only the titlebar's alpha changes, so the
/// layout never shifts.
final class ChromeFader {
    /// Fading only happens in pure writing mode (sidebar hidden).
    var isEnabled = false {
        didSet { if !isEnabled { show() } }
    }

    /// Off when the user asked to reduce motion: the chrome hides instantly.
    var animates = true

    private weak var window: NSWindow?
    private var mouseMonitor: Any?
    private var isFaded = false

    func attach(to window: NSWindow) {
        guard self.window !== window else { return }
        self.window = window
        window.acceptsMouseMovedEvents = true

        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            MainActor.assumeIsolated {
                if event.window === self?.window { self?.show() }
            }
            return event
        }
        NotificationCenter.default.addObserver(self, selector: #selector(windowResignedKey), name: NSWindow.didResignKeyNotification, object: window)
    }

    func userDidType() {
        guard isEnabled, !isFaded, let window, !window.styleMask.contains(.fullScreen),
              let titlebar = titlebarContainer else { return }
        isFaded = true
        setAlpha(0, of: titlebar, duration: 0.25)
    }

    func show() {
        guard isFaded else { return }
        isFaded = false
        guard let titlebar = titlebarContainer else { return }
        setAlpha(1, of: titlebar, duration: 0.2)
    }

    private func setAlpha(_ alpha: CGFloat, of view: NSView, duration: TimeInterval) {
        guard animates else {
            view.alphaValue = alpha
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            view.animator().alphaValue = alpha
        }
    }

    @objc private func windowResignedKey() {
        show()
    }

    /// The view holding the traffic lights and the toolbar.
    private var titlebarContainer: NSView? {
        guard let closeButton = window?.standardWindowButton(.closeButton) else { return nil }
        var view: NSView? = closeButton
        while let current = view {
            if NSStringFromClass(type(of: current)) == "NSTitlebarContainerView" { return current }
            view = current.superview
        }
        return closeButton.superview
    }

    isolated deinit {
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
    }
}

/// Hands the hosting NSWindow to SwiftUI code once the view is in a window.
struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> WindowObservingView {
        let view = WindowObservingView()
        view.onWindow = onWindow
        return view
    }

    func updateNSView(_ view: WindowObservingView, context: Context) {
        view.onWindow = onWindow
    }

    final class WindowObservingView: NSView {
        var onWindow: ((NSWindow) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { onWindow?(window) }
        }
    }
}
