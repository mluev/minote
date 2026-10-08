import AppKit
import QuartzCore
import MinoteEditor

/// The thick blue caret. AppKit's own insertion point can't be resized under
/// TextKit 2 (drawInsertionPoint overrides are ignored since macOS 14), so the
/// text view hides it and positions this view instead.
final class CaretView: NSView {
    private static let fadeKey = "fade"
    /// Time between blinks: the caret is shown, then hidden, for this long.
    private static let blinkInterval: TimeInterval = 0.55
    private static let fadeDuration: CFTimeInterval = 0.11
    /// How long the caret stays solid after typing or moving.
    private static let solidDelay: TimeInterval = 1

    /// Steps the blink. A repeating Core Animation blink would keep the
    /// render server drawing every frame for as long as the caret shows; a
    /// timer only costs the short fades.
    private var blinkTimer: Timer?
    private var isLit = true

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = EditorTheme.caret.cgColor
        layer?.actions = ["position": NSNull(), "bounds": NSNull(), "hidden": NSNull()]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { true }

    /// Clicks go through to the text.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Shows the caret solid, then starts a soft blink after a short idle delay.
    /// Called on every keystroke and caret move, so the caret never blinks out
    /// while the user is typing.
    func restartBlink() {
        stopBlink()
        let timer = Timer(fire: Date().addingTimeInterval(Self.solidDelay), interval: Self.blinkInterval, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            // Scheduled on the main run loop.
            MainActor.assumeIsolated { self.blink() }
        }
        timer.tolerance = 0.03
        RunLoop.main.add(timer, forMode: .common)
        blinkTimer = timer
    }

    /// Stops blinking, leaving the caret solid (call when it's hidden).
    func stopBlink() {
        blinkTimer?.invalidate()
        blinkTimer = nil
        isLit = true
        layer?.removeAnimation(forKey: Self.fadeKey)
        layer?.opacity = 1
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { stopBlink() }
    }

    private func blink() {
        isLit.toggle()
        fade(to: isLit ? 1 : 0)
    }

    private func fade(to opacity: Float) {
        guard let layer else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = layer.presentation()?.opacity ?? layer.opacity
        fade.toValue = opacity
        fade.duration = Self.fadeDuration
        fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.opacity = opacity
        layer.add(fade, forKey: Self.fadeKey)
    }
}
