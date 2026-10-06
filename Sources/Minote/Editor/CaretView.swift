import AppKit
import QuartzCore
import MinoteEditor

/// The thick blue caret. AppKit's own insertion point can't be resized under
/// TextKit 2 (drawInsertionPoint overrides are ignored since macOS 14), so the
/// text view hides it and positions this view instead.
final class CaretView: NSView {
    private static let blinkKey = "blink"

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
        guard let layer else { return }
        layer.removeAnimation(forKey: Self.blinkKey)
        layer.opacity = 1

        let blink = CAKeyframeAnimation(keyPath: "opacity")
        blink.values = [1, 1, 0, 0, 1]
        blink.keyTimes = [0, 0.46, 0.56, 0.9, 1]
        blink.timingFunctions = [
            CAMediaTimingFunction(name: .linear),
            CAMediaTimingFunction(name: .easeInEaseOut),
            CAMediaTimingFunction(name: .linear),
            CAMediaTimingFunction(name: .easeInEaseOut),
        ]
        blink.duration = 1.1
        blink.repeatCount = .infinity
        blink.beginTime = CACurrentMediaTime() + 0.5
        blink.fillMode = .backwards
        blink.isRemovedOnCompletion = false
        layer.add(blink, forKey: Self.blinkKey)
    }
}
