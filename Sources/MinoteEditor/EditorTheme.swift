#if os(macOS)
import AppKit
public typealias PlatformFont = NSFont
public typealias PlatformColor = NSColor
#else
import UIKit
public typealias PlatformFont = UIFont
public typealias PlatformColor = UIColor
#endif

/// Colors of the writing surface, shared by the Mac and iOS apps. Values were
/// sampled from the iA Writer reference screenshots; each has a
/// higher-contrast variant for the Increase Contrast accessibility setting.
public enum EditorTheme {
    public static let background = dynamicColor(light: 0xF6F6F6, dark: 0x1B1B1B, name: "MinoteBackground")
    public static let text = dynamicColor(light: 0x141414, dark: 0xD0D0D0, highContrastLight: 0x000000, highContrastDark: 0xF2F2F2, name: "MinoteText")
    /// Markdown markup: `#`, `**`, brackets, URLs.
    public static let syntax = dynamicColor(light: 0xA9A9A9, dark: 0x6B6B6B, highContrastLight: 0x6A6A6A, highContrastDark: 0x9C9C9C, name: "MinoteSyntax")
    /// Text outside the focused sentence or paragraph.
    public static let faded = dynamicColor(light: 0xBEBEBE, dark: 0x4D4D4D, highContrastLight: 0x8C8C8C, highContrastDark: 0x7A7A7A, name: "MinoteFaded")
    public static let selection = dynamicColor(light: 0xBFE8F8, dark: 0x0C3247, name: "MinoteSelection")
    /// Behind inline code and code blocks in rendered view.
    public static let codeBackground = dynamicColor(light: 0xEBEBEB, dark: 0x262626, highContrastLight: 0xDDDDDD, highContrastDark: 0x333333, name: "MinoteCodeBackground")
    /// Block quotes in rendered view.
    public static let quote = dynamicColor(light: 0x5C5C5C, dark: 0xA3A3A3, highContrastLight: 0x333333, highContrastDark: 0xCFCFCF, name: "MinoteQuote")
    /// Underline under link text in rendered view.
    public static let linkUnderline = dynamicColor(light: 0x8FD4EF, dark: 0x2C6E8C, name: "MinoteLinkUnderline")
    public static let caret = PlatformColor(srgbHex: 0x01C2FC)
    /// List bullets and numbers, and empty task boxes, in rendered view.
    public static let listMarker = dynamicColor(light: 0x8A8A8A, dark: 0x858585, highContrastLight: 0x4D4D4D, highContrastDark: 0xBDBDBD, name: "MinoteListMarker")
    /// A done task's box.
    public static let checkboxDone = dynamicColor(light: 0x01A8DC, dark: 0x0596C4, highContrastLight: 0x00749A, highContrastDark: 0x3CC8F5, name: "MinoteCheckboxDone")
    /// The text of a done task.
    public static let doneTask = dynamicColor(light: 0x9A9A9A, dark: 0x6E6E6E, highContrastLight: 0x5E5E5E, highContrastDark: 0xA8A8A8, name: "MinoteDoneTask")
    /// The bar beside a quote.
    public static let quoteBar = dynamicColor(light: 0xD4D4D4, dark: 0x3D3D3D, highContrastLight: 0x8A8A8A, highContrastDark: 0x8A8A8A, name: "MinoteQuoteBar")
    /// Rules and table lines.
    public static let rule = dynamicColor(light: 0xD4D4D4, dark: 0x3A3A3A, highContrastLight: 0x8C8C8C, highContrastDark: 0x7A7A7A, name: "MinoteRule")

    // The library list: the page's paper, a shade darker.
    public static let sidebarBackground = dynamicColor(light: 0xEEEEEE, dark: 0x161616, highContrastLight: 0xE6E6E6, highContrastDark: 0x0E0E0E, name: "MinoteSidebarBackground")
    /// Behind the selected note.
    public static let sidebarSelection = dynamicColor(light: 0xE2E2E2, dark: 0x2A2A2A, highContrastLight: 0xCFCFCF, highContrastDark: 0x3A3A3A, name: "MinoteSidebarSelection")
    /// Behind the note under the pointer.
    public static let sidebarHover = dynamicColor(light: 0xE7E7E7, dark: 0x212121, highContrastLight: 0xDBDBDB, highContrastDark: 0x2A2A2A, name: "MinoteSidebarHover")

    // Parts of speech (Syntax Highlight).
    public static let adjective = dynamicColor(light: 0xB0731F, dark: 0xD9A04E, name: "MinoteAdjective")
    public static let noun = dynamicColor(light: 0xC2402F, dark: 0xE8705F, name: "MinoteNoun")
    public static let adverb = dynamicColor(light: 0x9C3FBF, dark: 0xC889E0, name: "MinoteAdverb")
    public static let verb = dynamicColor(light: 0x1D72B0, dark: 0x5AAEE6, name: "MinoteVerb")
    public static let conjunction = dynamicColor(light: 0x2F8A35, dark: 0x6CC071, name: "MinoteConjunction")

    // MARK: Metrics

    /// Line height as a multiple of the font size.
    public static let lineHeightMultiple: CGFloat = 1.6
    /// Column width in characters (CSS `ch`: advances of "0").
    public static let lineLength = 64
    public static let minimumHorizontalMargin: CGFloat = 32
    /// Caret size relative to the font size.
    public static let caretWidthRatio: CGFloat = 0.15
    public static let caretHeightRatio: CGFloat = 1.45

    public static let defaultFontSize: Double = 18
    public static let fontSizeRange: ClosedRange<Double> = 12...32

    // MARK: Helpers

    private static func dynamicColor(light: UInt32, dark: UInt32, highContrastLight: UInt32? = nil, highContrastDark: UInt32? = nil, name: String) -> PlatformColor {
        #if os(macOS)
        return NSColor(name: name) { appearance in
            switch appearance.bestMatch(from: [.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua]) {
            case .darkAqua: NSColor(srgbHex: dark)
            case .accessibilityHighContrastDarkAqua: NSColor(srgbHex: highContrastDark ?? dark)
            case .accessibilityHighContrastAqua: NSColor(srgbHex: highContrastLight ?? light)
            default: NSColor(srgbHex: light)
            }
        }
        #else
        return UIColor { traits in
            let isDark = traits.userInterfaceStyle == .dark
            let highContrast = traits.accessibilityContrast == .high
            switch (isDark, highContrast) {
            case (true, true): return UIColor(srgbHex: highContrastDark ?? dark)
            case (true, false): return UIColor(srgbHex: dark)
            case (false, true): return UIColor(srgbHex: highContrastLight ?? light)
            case (false, false): return UIColor(srgbHex: light)
            }
        }
        #endif
    }
}

/// The four faces of the editor font.
public struct EditorFonts {
    public let regular: PlatformFont
    public let bold: PlatformFont
    public let italic: PlatformFont
    public let boldItalic: PlatformFont

    public init(family: EditorFontFamily, size: CGFloat) {
        let regular: PlatformFont
        switch family {
        case .plexMono:
            regular = PlatformFont(name: "IBMPlexMono", size: size) ?? .monospacedSystemFont(ofSize: size, weight: .regular)
        case .sfMono:
            regular = .monospacedSystemFont(ofSize: size, weight: .regular)
        case .newYork:
            let base = PlatformFont.systemFont(ofSize: size)
            #if os(macOS)
            regular = base.fontDescriptor.withDesign(.serif).flatMap { NSFont(descriptor: $0, size: size) } ?? base
            #else
            regular = base.fontDescriptor.withDesign(.serif).map { UIFont(descriptor: $0, size: size) } ?? base
            #endif
        case .sfPro:
            regular = .systemFont(ofSize: size)
        }
        self.regular = regular
        if family == .plexMono, let bold = PlatformFont(name: "IBMPlexMono-Bold", size: size),
           let italic = PlatformFont(name: "IBMPlexMono-Italic", size: size),
           let boldItalic = PlatformFont(name: "IBMPlexMono-BoldItalic", size: size) {
            self.bold = bold
            self.italic = italic
            self.boldItalic = boldItalic
        } else {
            bold = Self.font(regular, bold: true, italic: false)
            italic = Self.font(regular, bold: false, italic: true)
            boldItalic = Self.font(regular, bold: true, italic: true)
        }
    }

    public func font(strong: Bool, emphasis: Bool) -> PlatformFont {
        switch (strong, emphasis) {
        case (true, true): boldItalic
        case (true, false): bold
        case (false, true): italic
        case (false, false): regular
        }
    }

    private static func font(_ base: PlatformFont, bold: Bool, italic: Bool) -> PlatformFont {
        #if os(macOS)
        var traits: NSFontDescriptor.SymbolicTraits = []
        if bold { traits.insert(.bold) }
        if italic { traits.insert(.italic) }
        let descriptor = base.fontDescriptor.withSymbolicTraits(traits)
        return NSFont(descriptor: descriptor, size: base.pointSize) ?? base
        #else
        var traits: UIFontDescriptor.SymbolicTraits = []
        if bold { traits.insert(.traitBold) }
        if italic { traits.insert(.traitItalic) }
        guard let descriptor = base.fontDescriptor.withSymbolicTraits(traits) else { return base }
        return UIFont(descriptor: descriptor, size: base.pointSize)
        #endif
    }
}

/// Fonts and geometry for one font choice: line height, the centered column,
/// and the margin gutter that heading markers hang into.
public final class EditorStyleSheet {
    public let family: EditorFontFamily
    public let fonts: EditorFonts
    public let lineHeight: CGFloat
    /// Width of one `ch`.
    public let characterWidth: CGFloat
    /// Width of the text column.
    public let columnWidth: CGFloat
    /// Room left of the column for hanging `######` heading markers. The text
    /// container is wider than the column by this much on each side. Zero on
    /// narrow screens, where markers sit inline.
    public let gutter: CGFloat
    public let baselineOffset: CGFloat
    public private(set) var baseAttributes: [NSAttributedString.Key: Any] = [:]
    /// Markup in rendered view is set in this (practically zero-width) font.
    public let hiddenFont: PlatformFont
    /// Side of a drawn task box.
    public let checkboxSize: CGFloat
    /// How far each quote level indents its text.
    public let quoteIndent: CGFloat
    /// How far code sits inside its box.
    public let codeIndent: CGFloat

    private var paragraphStyles: [ParagraphKey: NSParagraphStyle] = [:]
    private var headings: [Int: Heading] = [:]

    private struct ParagraphKey: Hashable {
        let firstLine: Int
        let head: Int
        let lineHeight: Int
        let spacingBefore: Int
    }

    /// How a heading of one level looks.
    public struct Heading {
        public let font: PlatformFont
        public let lineHeight: CGFloat
        public let baselineOffset: CGFloat
        public let spacingBefore: CGFloat
    }

    /// Rendered view sets headings larger; the source view keeps one size, like iA.
    public static func headingScale(_ level: Int) -> CGFloat {
        switch level {
        case 1: 1.6
        case 2: 1.35
        case 3: 1.15
        default: 1
        }
    }

    public init(family: EditorFontFamily, size: CGFloat, hangsMarkers: Bool = true) {
        self.family = family
        fonts = EditorFonts(family: family, size: size)
        let regular = fonts.regular
        lineHeight = (size * EditorTheme.lineHeightMultiple).rounded()
        characterWidth = ("0" as NSString).size(withAttributes: [.font: regular]).width
        columnWidth = (characterWidth * CGFloat(EditorTheme.lineLength)).rounded()
        gutter = hangsMarkers ? ("###### " as NSString).size(withAttributes: [.font: regular]).width.rounded(.up) : 0

        // A fixed line height puts all the extra space above the glyphs. Under
        // TextKit 2 a *negative* baseline offset moves the glyphs up inside the
        // fixed line box (a positive one shrinks the box instead — measured),
        // so -extra/2 centers the text, and with it the caret, in the line.
        let naturalHeight = regular.ascender - regular.descender
        baselineOffset = -(((lineHeight - naturalHeight) / 2) * 2).rounded() / 2
        hiddenFont = PlatformFont(name: regular.fontName, size: 0.01) ?? regular
        checkboxSize = (size * 0.8).rounded()
        quoteIndent = (max(characterWidth * 2, size * 1.1)).rounded()
        codeIndent = characterWidth.rounded()

        baseAttributes = [
            .font: regular,
            .foregroundColor: EditorTheme.text,
            .paragraphStyle: paragraphStyle(firstLineIndent: 0, headIndent: 0),
            .baselineOffset: baselineOffset,
        ]
    }

    /// A paragraph style with indents measured from the column's left edge
    /// (negative first-line indents hang into the gutter).
    public func paragraphStyle(firstLineIndent: CGFloat, headIndent: CGFloat, lineHeight: CGFloat? = nil, spacingBefore: CGFloat = 0) -> NSParagraphStyle {
        let height = lineHeight ?? self.lineHeight
        let key = ParagraphKey(
            firstLine: Int((firstLineIndent * 2).rounded()),
            head: Int((headIndent * 2).rounded()),
            lineHeight: Int((height * 2).rounded()),
            spacingBefore: Int((spacingBefore * 2).rounded())
        )
        if let style = paragraphStyles[key] { return style }
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = height
        style.maximumLineHeight = height
        style.paragraphSpacingBefore = spacingBefore
        style.lineBreakMode = .byWordWrapping
        style.firstLineHeadIndent = max(0, gutter + firstLineIndent)
        style.headIndent = max(0, gutter + headIndent)
        style.tailIndent = -gutter
        style.tabStops = []
        style.defaultTabInterval = characterWidth * 4
        paragraphStyles[key] = style
        return style
    }

    /// The font and line metrics of a heading in rendered view.
    public func heading(level: Int) -> Heading {
        if let heading = headings[level] { return heading }
        let scale = Self.headingScale(level)
        let size = fonts.regular.pointSize * scale
        let base = fonts.bold
        #if os(macOS)
        let font = NSFont(descriptor: base.fontDescriptor, size: size) ?? base
        #else
        let font = UIFont(descriptor: base.fontDescriptor, size: size)
        #endif
        let height = scale == 1 ? lineHeight : (size * 1.35).rounded()
        let natural = font.ascender - font.descender
        let heading = Heading(
            font: font,
            lineHeight: height,
            baselineOffset: -(((height - natural) / 2) * 2).rounded() / 2,
            spacingBefore: scale > 1 ? (lineHeight * 0.4).rounded() : 0
        )
        headings[level] = heading
        return heading
    }

    /// Width of leading markup such as "  - " or "## ", tabs counted as four spaces.
    public func width(of prefix: String) -> CGFloat {
        let expanded = prefix.replacingOccurrences(of: "\t", with: "    ")
        if family.isMonospaced { return CGFloat(expanded.utf16.count) * characterWidth }
        return (expanded as NSString).size(withAttributes: [.font: fonts.regular]).width
    }
}

/// Typefaces offered in the View menu.
public enum EditorFontFamily: String, CaseIterable, Identifiable, Sendable {
    case plexMono, sfMono, newYork, sfPro

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .plexMono: "IBM Plex Mono"
        case .sfMono: "SF Mono"
        case .newYork: "New York"
        case .sfPro: "SF Pro"
        }
    }

    public var isMonospaced: Bool { self == .plexMono || self == .sfMono }
}

/// Focus mode: what stays dark.
public enum FocusMode: String, CaseIterable, Identifiable, Sendable {
    case off, sentence, paragraph

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .off: "Off"
        case .sentence: "Sentence"
        case .paragraph: "Paragraph"
        }
    }
}

/// How the page looks, from the View menu.
public struct EditorConfiguration: Equatable, Sendable {
    public var family: EditorFontFamily
    public var size: Double
    public var focus: FocusMode
    public var typewriter: Bool
    public var partsOfSpeech: Bool
    /// Show Markdown markup everywhere (dimmed, iA style) instead of rendering it.
    public var showsSyntax: Bool
    /// Preview: read-only, nothing reveals its markup, links open on click.
    public var preview: Bool

    public init(family: EditorFontFamily, size: Double, focus: FocusMode, typewriter: Bool, partsOfSpeech: Bool, showsSyntax: Bool = false, preview: Bool = false) {
        self.family = family
        self.size = size
        self.focus = focus
        self.typewriter = typewriter
        self.partsOfSpeech = partsOfSpeech
        self.showsSyntax = showsSyntax
        self.preview = preview
    }

    /// Markup is rendered (hidden) rather than shown.
    public var rendersMarkdown: Bool { preview || !showsSyntax }
}

/// UserDefaults keys for view preferences, shared by both apps.
public enum PreferenceKey {
    public static let fontFamily = "EditorFontFamily"
    public static let fontSize = "EditorFontSize"
    public static let appearance = "Appearance"
    public static let focusEnabled = "FocusMode"
    public static let focusUnit = "FocusUnit"
    public static let typewriter = "TypewriterMode"
    public static let syntaxHighlight = "SyntaxHighlight"
    public static let showCounter = "ShowWordCount"
    public static let counterMetric = "WordCountMetric"
    public static let showsSyntax = "ShowMarkdownSyntax"
}

extension PlatformColor {
    public convenience init(srgbHex hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}
