import AppKit
import MinoteEditor

/// A quiet hint at the bottom of the page while the pointer is over a link:
/// where it goes and how to follow it, like a browser's status bar.
final class LinkHintView: NSView {
    private let label = NSTextField(labelWithString: "")
    private(set) var text = ""

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 0.5
        alphaValue = 0
        isHidden = true
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.lineBreakMode = .byTruncatingMiddle
        label.maximumNumberOfLines = 1
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
        ])
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Clicks go through to the text.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateLayer() {
        layer?.backgroundColor = EditorTheme.background.blended(withFraction: 0.06, of: .labelColor)?.cgColor
        layer?.borderColor = NSColor.separatorColor.cgColor
    }

    /// Shows `address` and how to open it; nil hides the hint.
    func show(address: String?, action: String) {
        guard let address else {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.12
                animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    if self?.alphaValue == 0 { self?.isHidden = true }
                }
            })
            text = ""
            return
        }
        let string = NSMutableAttributedString(string: address, attributes: [.foregroundColor: NSColor.labelColor])
        string.append(NSAttributedString(string: "  " + action, attributes: [.foregroundColor: NSColor.secondaryLabelColor]))
        label.attributedStringValue = string
        text = address + "  " + action
        isHidden = false
        (superview as? NSScrollView)?.tile()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            animator().alphaValue = 1
        }
    }
}
