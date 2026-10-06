#if os(macOS)
import AppKit
#else
import UIKit
#endif
import MinoteKit

extension NSAttributedString.Key {
    /// Something drawn in place of one run of markup: a `MarkdownMark` raw value.
    public static let minoteMark = NSAttributedString.Key("MinoteMark")
    /// Something drawn behind a whole line: a `MarkdownBlock` raw value.
    public static let minoteBlock = NSAttributedString.Key("MinoteBlock")
    /// Where a link points: a `MarkdownLinkTarget` encoded by `LinkAttribute`.
    public static let minoteLink = NSAttributedString.Key("MinoteLink")
    /// Set on text that Focus mode fades, so drawings fade with it.
    public static let minoteFaded = NSAttributedString.Key("MinoteFaded")
}

/// Drawn in place of markup characters (which stay in the text, invisible).
public enum MarkdownMark: Hashable, Sendable {
    /// A list bullet; deeper levels get a ring, then a square.
    case bullet(level: Int)
    case checkbox(done: Bool)
    /// A `---` rule across the column.
    case rule
    /// A `|` in a table: a thin vertical line.
    case tablePipe
    /// The `|---|---|` row under a table header: a thin line.
    case tableRule

    public var rawValue: String {
        switch self {
        case .bullet(let level): "bullet:\(level)"
        case .checkbox(let done): done ? "box:x" : "box: "
        case .rule: "rule"
        case .tablePipe: "pipe"
        case .tableRule: "tableRule"
        }
    }

    public init?(rawValue: String) {
        switch rawValue {
        case "box:x": self = .checkbox(done: true)
        case "box: ": self = .checkbox(done: false)
        case "rule": self = .rule
        case "pipe": self = .tablePipe
        case "tableRule": self = .tableRule
        default:
            guard rawValue.hasPrefix("bullet:"), let level = Int(rawValue.dropFirst(7)) else { return nil }
            self = .bullet(level: level)
        }
    }
}

/// Drawn behind a whole line.
public enum MarkdownBlock: Hashable, Sendable {
    /// Quote bars, one per level.
    case quote(depth: Int)
    /// Part of a code block's box; the first and last lines round its corners.
    case code(top: Bool, bottom: Bool)

    public var rawValue: String {
        switch self {
        case .quote(let depth): "quote:\(depth)"
        case .code(let top, let bottom): "code:\(top ? 1 : 0)\(bottom ? 1 : 0)"
        }
    }

    public init?(rawValue: String) {
        if rawValue.hasPrefix("quote:"), let depth = Int(rawValue.dropFirst(6)) {
            self = .quote(depth: depth)
        } else if rawValue.hasPrefix("code:"), rawValue.count == 7 {
            let flags = Array(rawValue.dropFirst(5))
            self = .code(top: flags[0] == "1", bottom: flags[1] == "1")
        } else {
            return nil
        }
    }
}

/// Link targets as attribute values (strings compare cheaply and coalesce).
public enum LinkAttribute {
    public static func encode(_ target: MarkdownLinkTarget) -> String {
        switch target {
        case .url(let url): "u" + url
        case .reference(let label): "r" + label
        case .footnote(let id): "f" + id
        }
    }

    public static func decode(_ value: Any?) -> MarkdownLinkTarget? {
        guard let string = value as? String, let kind = string.first else { return nil }
        let rest = String(string.dropFirst())
        switch kind {
        case "u": return .url(rest)
        case "r": return .reference(rest)
        case "f": return .footnote(rest)
        default: return nil
        }
    }
}

/// Supplies `MarkdownLayoutFragment`s to a text layout manager. The engine
/// owns it (the layout manager's delegate is weak).
public final class MarkdownLayoutDelegate: NSObject, NSTextLayoutManagerDelegate {
    public var styleSheet: EditorStyleSheet

    init(styleSheet: EditorStyleSheet) {
        self.styleSheet = styleSheet
    }

    public func textLayoutManager(_ textLayoutManager: NSTextLayoutManager, textLayoutFragmentFor location: any NSTextLocation, in textElement: NSTextElement) -> NSTextLayoutFragment {
        let fragment = MarkdownLayoutFragment(textElement: textElement, range: textElement.elementRange)
        fragment.styleSheet = styleSheet
        return fragment
    }
}

/// A paragraph's layout that also draws what its hidden markup stands for:
/// bullets, task boxes, quote bars, rules, code boxes and table lines.
public final class MarkdownLayoutFragment: NSTextLayoutFragment {
    var styleSheet: EditorStyleSheet?

    private var paragraphString: NSAttributedString? {
        (textElement as? NSTextParagraph)?.attributedString
    }

    private var containerWidth: CGFloat {
        textLayoutManager?.textContainer?.size.width ?? layoutFragmentFrame.width
    }

    /// Room for drawings beyond the glyphs: the whole column, full height.
    public override var renderingSurfaceBounds: CGRect {
        let base = super.renderingSurfaceBounds
        guard hasDecorations else { return base }
        let line = CGRect(x: -layoutFragmentFrame.minX, y: 0, width: containerWidth, height: layoutFragmentFrame.height)
        return base.union(line)
    }

    private lazy var hasDecorations: Bool = {
        guard let string = paragraphString, string.length > 0 else { return false }
        let all = NSRange(location: 0, length: string.length)
        var found = false
        for key in [NSAttributedString.Key.minoteMark, .minoteBlock] {
            string.enumerateAttribute(key, in: all) { value, _, stop in
                if value != nil { found = true; stop.pointee = true }
            }
        }
        return found
    }()

    public override func draw(at point: CGPoint, in context: CGContext) {
        guard hasDecorations, let sheet = styleSheet, let string = paragraphString else {
            super.draw(at: point, in: context)
            return
        }
        // Fragment coordinates → context coordinates.
        let origin = CGPoint(x: point.x - layoutFragmentFrame.minX, y: point.y)
        let column = CGRect(x: origin.x + sheet.gutter, y: point.y,
                            width: max(0, containerWidth - 2 * sheet.gutter), height: layoutFragmentFrame.height)
        let block = string.length > 0 ? (string.attribute(.minoteBlock, at: 0, effectiveRange: nil) as? String).flatMap(MarkdownBlock.init(rawValue:)) : nil
        let faded = string.length > 0 && string.attribute(.minoteFaded, at: 0, effectiveRange: nil) != nil

        context.saveGState()
        if case .code(let top, let bottom)? = block {
            drawCodeBox(in: column, top: top, bottom: bottom, context: context)
        }
        context.restoreGState()

        super.draw(at: point, in: context)

        context.saveGState()
        if case .quote(let depth)? = block {
            drawQuoteBars(depth: depth, column: column, sheet: sheet, faded: faded, context: context)
        }
        for mark in marks() {
            let rect = mark.rect.offsetBy(dx: point.x, dy: point.y)
            drawMark(mark, in: rect, line: mark.line.offsetBy(dx: point.x, dy: point.y), baseline: mark.baseline + point.y,
                     column: column, sheet: sheet, context: context)
        }
        context.restoreGState()
    }

    // MARK: Geometry

    struct PlacedMark {
        var kind: MarkdownMark
        /// The marked characters, in fragment coordinates.
        var rect: CGRect
        /// Their line.
        var line: CGRect
        /// Where the line's regular text sits.
        var baseline: CGFloat
        var faded: Bool
        /// Offset of the first marked character in the paragraph.
        var characterOffset: Int
    }

    /// Every mark with where it sits, in fragment coordinates.
    func marks() -> [PlacedMark] {
        guard let string = paragraphString else { return [] }
        var result: [PlacedMark] = []
        for lineFragment in textLineFragments {
            let range = lineFragment.characterRange
            guard range.length > 0, NSMaxRange(range) <= string.length else { continue }
            let bounds = lineFragment.typographicBounds
            string.enumerateAttribute(.minoteMark, in: range) { value, run, _ in
                guard let raw = value as? String, let kind = MarkdownMark(rawValue: raw) else { return }
                let start = lineFragment.locationForCharacter(at: run.location).x
                let end = lineFragment.locationForCharacter(at: NSMaxRange(run)).x
                let rect = CGRect(x: bounds.minX + start, y: bounds.minY, width: max(0, end - start), height: bounds.height)
                let faded = string.attribute(.minoteFaded, at: run.location, effectiveRange: nil) != nil
                // The glyph origin is the baseline before the run's baseline offset moves it.
                let offset = (string.attribute(.baselineOffset, at: run.location, effectiveRange: nil) as? CGFloat) ?? 0
                let baseline = bounds.minY + lineFragment.glyphOrigin.y - offset
                result.append(PlacedMark(kind: kind, rect: rect, line: bounds, baseline: baseline, faded: faded, characterOffset: run.location))
            }
        }
        return result
    }

    /// The task box drawn for a checkbox mark, in fragment coordinates.
    func checkboxRect(for mark: PlacedMark) -> CGRect? {
        guard case .checkbox = mark.kind, let sheet = styleSheet else { return nil }
        let size = sheet.checkboxSize
        let center = mark.baseline - sheet.fonts.regular.capHeight / 2
        return CGRect(x: mark.rect.minX, y: (center - size / 2).rounded(), width: size, height: size)
    }

    // MARK: Drawing

    private func drawMark(_ mark: PlacedMark, in rect: CGRect, line: CGRect, baseline: CGFloat, column: CGRect, sheet: EditorStyleSheet, context: CGContext) {
        let faded = mark.faded
        let markerColor = cgColor(faded ? EditorTheme.faded : EditorTheme.listMarker)
        switch mark.kind {
        case .bullet(let level):
            let diameter = (sheet.fonts.regular.pointSize * 0.3).rounded()
            let center = CGPoint(x: rect.midX, y: baseline - sheet.fonts.regular.xHeight / 2)
            let dot = CGRect(x: center.x - diameter / 2, y: center.y - diameter / 2, width: diameter, height: diameter)
            switch level % 3 {
            case 0:
                context.setFillColor(markerColor)
                context.fillEllipse(in: dot)
            case 1:
                context.setStrokeColor(markerColor)
                context.setLineWidth(1.2)
                context.strokeEllipse(in: dot.insetBy(dx: 0.6, dy: 0.6))
            default:
                context.setFillColor(markerColor)
                context.fill(dot.insetBy(dx: diameter * 0.08, dy: diameter * 0.08))
            }
        case .checkbox(let done):
            let size = sheet.checkboxSize
            let center = baseline - sheet.fonts.regular.capHeight / 2
            let box = CGRect(x: rect.minX, y: (center - size / 2).rounded(), width: size, height: size)
            let radius = size * 0.24
            if done {
                context.setFillColor(cgColor(faded ? EditorTheme.faded : EditorTheme.checkboxDone))
                context.addPath(CGPath(roundedRect: box, cornerWidth: radius, cornerHeight: radius, transform: nil))
                context.fillPath()
                let check = CGMutablePath()
                check.move(to: CGPoint(x: box.minX + size * 0.26, y: box.minY + size * 0.52))
                check.addLine(to: CGPoint(x: box.minX + size * 0.43, y: box.minY + size * 0.69))
                check.addLine(to: CGPoint(x: box.minX + size * 0.75, y: box.minY + size * 0.33))
                context.setStrokeColor(cgColor(EditorTheme.background))
                context.setLineWidth(max(1.5, size * 0.12))
                context.setLineCap(.round)
                context.setLineJoin(.round)
                context.addPath(check)
                context.strokePath()
            } else {
                let inset = box.insetBy(dx: 0.65, dy: 0.65)
                context.setStrokeColor(markerColor)
                context.setLineWidth(1.3)
                context.addPath(CGPath(roundedRect: inset, cornerWidth: radius, cornerHeight: radius, transform: nil))
                context.strokePath()
            }
        case .rule:
            context.setFillColor(cgColor(EditorTheme.rule))
            context.fill(CGRect(x: column.minX, y: (line.midY - 0.5).rounded(), width: column.width, height: 1))
        case .tablePipe:
            context.setFillColor(cgColor(EditorTheme.rule))
            context.fill(CGRect(x: (rect.midX - 0.5).rounded(), y: line.minY, width: 1, height: line.height))
        case .tableRule:
            context.setFillColor(cgColor(EditorTheme.rule))
            context.fill(CGRect(x: rect.minX, y: (line.midY - 0.5).rounded(), width: rect.width, height: 1))
        }
    }

    private func drawQuoteBars(depth: Int, column: CGRect, sheet: EditorStyleSheet, faded: Bool, context: CGContext) {
        context.setFillColor(cgColor(faded ? EditorTheme.faded : EditorTheme.quoteBar))
        let width = max(2, (sheet.fonts.regular.pointSize * 0.14).rounded())
        for level in 0..<max(1, depth) {
            let x = column.minX + CGFloat(level) * sheet.quoteIndent + 1
            context.fill(CGRect(x: x, y: column.minY, width: width, height: column.height))
        }
    }

    private func drawCodeBox(in column: CGRect, top: Bool, bottom: Bool, context: CGContext) {
        let radius: CGFloat = 6
        let rect = column
        let path = CGMutablePath()
        let topRadius = top ? radius : 0, bottomRadius = bottom ? radius : 0
        path.move(to: CGPoint(x: rect.minX, y: rect.minY + topRadius))
        if top {
            path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.minY), tangent2End: CGPoint(x: rect.minX + radius, y: rect.minY), radius: radius)
            path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.minY), tangent2End: CGPoint(x: rect.maxX, y: rect.minY + radius), radius: radius)
        } else {
            path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        }
        if bottom {
            path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.maxY), tangent2End: CGPoint(x: rect.maxX - radius, y: rect.maxY), radius: radius)
            path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.maxY), tangent2End: CGPoint(x: rect.minX, y: rect.maxY - bottomRadius), radius: radius)
        } else {
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        }
        path.closeSubpath()
        context.setFillColor(cgColor(EditorTheme.codeBackground))
        context.addPath(path)
        context.fillPath()
    }

    /// A theme color resolved for the appearance being drawn.
    private func cgColor(_ color: PlatformColor) -> CGColor {
        #if os(macOS)
        var resolved = color.cgColor
        NSAppearance.currentDrawing().performAsCurrentDrawingAppearance { resolved = color.cgColor }
        return resolved
        #else
        return color.resolvedColor(with: UITraitCollection.current).cgColor
        #endif
    }
}
