import Foundation

/// Pure text rules shared by the library and the file store: how a note's
/// title, excerpt and file name are derived from its plain-text contents.
public enum NoteNaming {
    /// Extension used for files Minote creates.
    public static let fileExtension = "md"

    /// Extensions the library lists. Anything else in the folder is ignored.
    public static let supportedExtensions: Set<String> = ["md", "markdown", "txt", "text"]

    /// File name used when a note has no usable first line.
    public static let untitled = "Untitled"

    /// Upper bound for a generated file name, in characters.
    public static let maxStemLength = 80

    /// Upper bound in UTF-8 bytes. APFS allows 255; we leave room for
    /// a " 999" collision suffix and the extension.
    static let maxStemBytes = 200

    /// How much of a note's beginning is enough to derive its title and excerpt.
    public static let prefixLength = 1_000

    // MARK: Title

    /// The first non-blank line, without Markdown heading, quote or list markers.
    public static func title(of text: some StringProtocol) -> String {
        for line in text.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline) {
            let cleaned = stripLineMarkers(Substring(line))
            if !cleaned.isEmpty { return String(cleaned.prefix(200)) }
        }
        return ""
    }

    /// Text following the title line, whitespace collapsed, for the sidebar preview.
    public static func excerpt(of text: some StringProtocol, skippingTitleLine: Bool = true, limit: Int = 240) -> String {
        var parts: [Substring] = []
        var length = 0
        var skipped = !skippingTitleLine
        for line in text.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline) {
            let cleaned = stripLineMarkers(Substring(line))
            guard !cleaned.isEmpty else { continue }
            if !skipped {
                skipped = true
                continue
            }
            parts.append(cleaned)
            length += cleaned.count + 1
            if length >= limit { break }
        }
        let joined = parts.joined(separator: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        return String(joined.prefix(limit))
    }

    /// The readable text of a line: block markers, emphasis markers, link
    /// destinations and other markup removed ("**Bold** [site](url)" → "Bold site").
    static func stripLineMarkers(_ line: Substring) -> Substring {
        let units = Array(line.utf16)
        let lexed = MarkdownLexer.lex(units, insideFence: false)
        switch lexed.kind {
        case .blank, .fence, .thematicBreak:
            return ""
        default:
            break
        }
        var hidden = [Bool](repeating: false, count: units.count)
        for i in 0..<min(lexed.contentStart, units.count) { hidden[i] = true }
        for span in lexed.spans where span.style == .syntax || span.style == .destination {
            for i in span.range where i < hidden.count { hidden[i] = true }
        }
        var kept: [UInt16] = []
        kept.reserveCapacity(units.count)
        for (i, unit) in units.enumerated() where !hidden[i] { kept.append(unit) }
        let text = String(decoding: kept, as: UTF16.self)
        return Substring(text.trimmingCharacters(in: .whitespaces))
    }

    // MARK: File names

    /// A safe file name stem (no extension) for a note title.
    public static func fileStem(forTitle title: String) -> String {
        var scalars = String.UnicodeScalarView()
        var lastWasSpace = false
        for scalar in title.unicodeScalars {
            let mapped: Unicode.Scalar
            switch scalar {
            case "/", ":":
                mapped = "-"
            case _ where CharacterSet.controlCharacters.contains(scalar)
                || CharacterSet.whitespacesAndNewlines.contains(scalar):
                mapped = " "
            default:
                mapped = scalar
            }
            if mapped == " " {
                if lastWasSpace { continue }
                lastWasSpace = true
            } else {
                lastWasSpace = false
            }
            scalars.append(mapped)
        }

        var stem = String(scalars)
        stem = trimmed(stem, leading: true)
        stem = truncated(stem)
        stem = trimmed(stem, leading: false)
        return stem.isEmpty ? untitled : stem.precomposedStringWithCanonicalMapping
    }

    /// Strips whitespace and dots: leading dots would hide the file,
    /// trailing dots make "Title..md".
    private static func trimmed(_ s: String, leading: Bool) -> String {
        let isJunk: (Character) -> Bool = { $0 == "." || $0.isWhitespace }
        if leading {
            return String(s.drop(while: isJunk))
        }
        var result = Substring(s)
        while let last = result.last, isJunk(last) { result = result.dropLast() }
        return String(result)
    }

    /// Cuts to `maxStemLength` characters, preferring a word boundary,
    /// then enforces the UTF-8 byte budget.
    private static func truncated(_ s: String) -> String {
        var result = s
        if result.count > maxStemLength {
            let hard = result.prefix(maxStemLength)
            if let space = hard.lastIndex(of: " "),
               hard.distance(from: hard.startIndex, to: space) >= maxStemLength / 2 {
                result = String(hard[..<space])
            } else {
                result = String(hard)
            }
        }
        while result.utf8.count > maxStemBytes {
            result.removeLast()
        }
        return result
    }

    /// The first stem in "Base", "Base 2", "Base 3", … for which `isTaken` is false.
    public static func uniqueStem(base: String, isTaken: (String) -> Bool) -> String {
        if !isTaken(base) { return base }
        var counter = 2
        while isTaken("\(base) \(counter)") { counter += 1 }
        return "\(base) \(counter)"
    }

    /// Whether two stems name the same file on a case-insensitive,
    /// normalization-insensitive volume (the APFS default).
    public static func stemsMatch(_ a: String, _ b: String) -> Bool {
        a.precomposedStringWithCanonicalMapping
            .compare(b.precomposedStringWithCanonicalMapping, options: [.caseInsensitive]) == .orderedSame
    }

    /// Whether a URL has an extension the library lists.
    public static func isNoteFile(_ url: URL) -> Bool {
        supportedExtensions.contains(url.pathExtension.lowercased())
    }
}

extension StringProtocol {
    /// True when the text has no visible characters.
    public var isBlank: Bool {
        allSatisfy(\.isWhitespace)
    }
}
