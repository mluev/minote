#if os(macOS)
import AppKit
public typealias PlatformFont = NSFont
public typealias PlatformColor = NSColor
#else
import UIKit
public typealias PlatformFont = UIFont
public typealias PlatformColor = UIColor
#endif

/// What the writing surface shares across palettes: the caret, the parts of
/// speech, and the page's metrics. The page's own colors are in `EditorPalette`.
public enum EditorTheme {
    public static let caret = PlatformColor(srgbHex: 0x01C2FC)

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

    static func dynamicColor(light: UInt32, dark: UInt32, highContrastLight: UInt32? = nil, highContrastDark: UInt32? = nil, name: String) -> PlatformColor {
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

/// The paper a light page is printed on. Dark pages are the same for both.
public enum EditorPaper: String, CaseIterable, Sendable {
    case standard, sepia
}

/// Colors of the writing surface, shared by the Mac and iOS apps. Values were
/// sampled from the iA Writer reference screenshots (sepia: warm paper with
/// brown ink, in the spirit of a book page); each has a higher-contrast variant
/// for the Increase Contrast accessibility setting. One instance per paper,
/// so a color's identity says which paper it belongs to.
public struct EditorPalette: Sendable {
    public let paper: EditorPaper
    public let background: PlatformColor
    public let text: PlatformColor
    /// Markdown markup: `#`, `**`, brackets, URLs.
    public let syntax: PlatformColor
    /// Text outside the focused sentence or paragraph.
    public let faded: PlatformColor
    public let selection: PlatformColor
    /// Behind inline code and code blocks in rendered view.
    public let codeBackground: PlatformColor
    /// Block quotes in rendered view.
    public let quote: PlatformColor
    /// Underline under link text in rendered view.
    public let linkUnderline: PlatformColor
    /// List bullets and numbers, and empty task boxes, in rendered view.
    public let listMarker: PlatformColor
    /// A done task's box.
    public let checkboxDone: PlatformColor
    /// The text of a done task.
    public let doneTask: PlatformColor
    /// The bar beside a quote.
    public let quoteBar: PlatformColor
    /// Rules and table lines.
    public let rule: PlatformColor

    // The library list: the page's paper, a shade darker.
    public let sidebarBackground: PlatformColor
    /// Behind the selected note.
    public let sidebarSelection: PlatformColor
    /// Behind the note under the pointer.
    public let sidebarHover: PlatformColor

    public static let standard = EditorPalette(paper: .standard)
    public static let sepia = EditorPalette(paper: .sepia)

    public static func of(_ paper: EditorPaper) -> EditorPalette {
        switch paper {
        case .standard: standard
        case .sepia: sepia
        }
    }

    private init(paper: EditorPaper) {
        self.paper = paper
        let isSepia = paper == .sepia
        /// Sepia replaces the light values; dark pages don't change.
        func color(_ name: String, light: UInt32, dark: UInt32, sepia: UInt32,
                   highContrastLight: UInt32? = nil, highContrastDark: UInt32? = nil, highContrastSepia: UInt32? = nil) -> PlatformColor {
            EditorTheme.dynamicColor(
                light: isSepia ? sepia : light,
                dark: dark,
                highContrastLight: isSepia ? highContrastSepia : highContrastLight,
                highContrastDark: highContrastDark,
                name: "Minote" + name + (isSepia ? "Sepia" : "")
            )
        }
        background = color("Background", light: 0xF6F6F6, dark: 0x1B1B1B, sepia: 0xF4ECDB)
        text = color("Text", light: 0x141414, dark: 0xD0D0D0, sepia: 0x3A2C1E, highContrastLight: 0x000000, highContrastDark: 0xF2F2F2, highContrastSepia: 0x1E140A)
        syntax = color("Syntax", light: 0xA9A9A9, dark: 0x6B6B6B, sepia: 0xAE9C80, highContrastLight: 0x6A6A6A, highContrastDark: 0x9C9C9C, highContrastSepia: 0x6E5C42)
        faded = color("Faded", light: 0xBEBEBE, dark: 0x4D4D4D, sepia: 0xC9BA9E, highContrastLight: 0x8C8C8C, highContrastDark: 0x7A7A7A, highContrastSepia: 0x958468)
        selection = color("Selection", light: 0xBFE8F8, dark: 0x0C3247, sepia: 0xE5D5AE)
        codeBackground = color("CodeBackground", light: 0xEBEBEB, dark: 0x262626, sepia: 0xECE2CB, highContrastLight: 0xDDDDDD, highContrastDark: 0x333333, highContrastSepia: 0xE2D5BA)
        quote = color("Quote", light: 0x5C5C5C, dark: 0xA3A3A3, sepia: 0x6A5640, highContrastLight: 0x333333, highContrastDark: 0xCFCFCF, highContrastSepia: 0x3E2F20)
        linkUnderline = color("LinkUnderline", light: 0x8FD4EF, dark: 0x2C6E8C, sepia: 0x86BFD3)
        listMarker = color("ListMarker", light: 0x8A8A8A, dark: 0x858585, sepia: 0x958165, highContrastLight: 0x4D4D4D, highContrastDark: 0xBDBDBD, highContrastSepia: 0x5C4A33)
        checkboxDone = color("CheckboxDone", light: 0x01A8DC, dark: 0x0596C4, sepia: 0x01A8DC, highContrastLight: 0x00749A, highContrastDark: 0x3CC8F5, highContrastSepia: 0x00749A)
        doneTask = color("DoneTask", light: 0x9A9A9A, dark: 0x6E6E6E, sepia: 0xA59379, highContrastLight: 0x5E5E5E, highContrastDark: 0xA8A8A8, highContrastSepia: 0x6A5940)
        quoteBar = color("QuoteBar", light: 0xD4D4D4, dark: 0x3D3D3D, sepia: 0xDDCFB3, highContrastLight: 0x8A8A8A, highContrastDark: 0x8A8A8A, highContrastSepia: 0x9A896C)
        rule = color("Rule", light: 0xD4D4D4, dark: 0x3A3A3A, sepia: 0xDDCFB3, highContrastLight: 0x8C8C8C, highContrastDark: 0x7A7A7A, highContrastSepia: 0x9A896C)
        sidebarBackground = color("SidebarBackground", light: 0xEEEEEE, dark: 0x161616, sepia: 0xECE3CF, highContrastLight: 0xE6E6E6, highContrastDark: 0x0E0E0E, highContrastSepia: 0xE4D8BE)
        sidebarSelection = color("SidebarSelection", light: 0xE2E2E2, dark: 0x2A2A2A, sepia: 0xE0D3B6, highContrastLight: 0xCFCFCF, highContrastDark: 0x3A3A3A, highContrastSepia: 0xCEBF9E)
        sidebarHover = color("SidebarHover", light: 0xE7E7E7, dark: 0x212121, sepia: 0xE6DBC3, highContrastLight: 0xDBDBDB, highContrastDark: 0x2A2A2A, highContrastSepia: 0xD9CBAD)
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

/// Fonts, colors and geometry for one font and paper choice: line height, the
/// centered column, and the margin gutter that heading markers hang into.
public final class EditorStyleSheet {
    public let family: EditorFontFamily
    public let fonts: EditorFonts
    public let palette: EditorPalette
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

    public init(family: EditorFontFamily, size: CGFloat, hangsMarkers: Bool = true, paper: EditorPaper = .standard) {
        self.family = family
        fonts = EditorFonts(family: family, size: size)
        palette = .of(paper)
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
        // By descriptor, not name: system faces (New York) can't be looked up
        // by their private names, and the full-size fallback left gaps.
        #if os(macOS)
        hiddenFont = NSFont(descriptor: regular.fontDescriptor, size: 0.01) ?? regular
        #else
        hiddenFont = UIFont(descriptor: regular.fontDescriptor, size: 0.01)
        #endif
        checkboxSize = (size * 0.8).rounded()
        quoteIndent = (max(characterWidth * 2, size * 1.1)).rounded()
        codeIndent = characterWidth.rounded()

        baseAttributes = [
            .font: regular,
            .foregroundColor: palette.text,
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
    /// The paper of a light page.
    public var paper: EditorPaper

    public init(family: EditorFontFamily, size: Double, focus: FocusMode, typewriter: Bool, partsOfSpeech: Bool, showsSyntax: Bool = false, preview: Bool = false, paper: EditorPaper = .standard) {
        self.family = family
        self.size = size
        self.paper = paper
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
