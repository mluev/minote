import Foundation

/// Where following a link leads.
public enum MarkdownLinkDestination: Equatable, Sendable {
    /// A web page, a mail address or anything another app opens.
    case external(URL)
    /// A relative path, e.g. another note: `[see](Other%20note.md)`.
    case file(String)
    /// A place in the same note (a heading or a footnote), as a UTF-16 offset.
    case anchor(Int)
}

/// Resolves link targets written in a note: reference definitions, footnotes,
/// heading anchors, bare domains and relative paths.
public enum MarkdownLinks {
    public static func resolve(_ target: MarkdownLinkTarget, in text: NSString) -> MarkdownLinkDestination? {
        switch target {
        case .url(let destination):
            return resolve(destination: destination, in: text)
        case .reference(let label):
            guard let url = definition(of: label, in: text) else { return nil }
            return resolve(destination: url, in: text)
        case .footnote(let id):
            return lineStart(in: text) { line in line.hasPrefix("[^\(id)]:") }.map(MarkdownLinkDestination.anchor)
        }
    }

    static func resolve(destination raw: String, in text: NSString) -> MarkdownLinkDestination? {
        let destination = raw.trimmingCharacters(in: .whitespaces)
        guard !destination.isEmpty else { return nil }
        if destination.hasPrefix("#") {
            let slug = String(destination.dropFirst()).removingPercentEncoding ?? String(destination.dropFirst())
            return headingLocation(slug: slug.lowercased(), in: text).map(MarkdownLinkDestination.anchor)
        }
        let lowered = destination.lowercased()
        if lowered.hasPrefix("www.") {
            return URL(string: "https://" + destination).map(MarkdownLinkDestination.external)
        }
        if let scheme = URL(string: destination)?.scheme, !scheme.isEmpty, scheme.count > 1 {
            return URL(string: destination).map(MarkdownLinkDestination.external)
        }
        if destination.contains("@"), !destination.contains("/") {
            return URL(string: "mailto:" + destination).map(MarkdownLinkDestination.external)
        }
        return .file(destination.removingPercentEncoding ?? destination)
    }

    /// The URL of `[label]: url`, matched the CommonMark way (case-insensitive,
    /// whitespace collapsed).
    static func definition(of label: String, in text: NSString) -> String? {
        let wanted = normalized(label)
        var found: String?
        text.enumerateLines { line, stop in
            let parsed = MarkdownLexer.lex(line)
            guard parsed.kind == .linkDefinition, let link = parsed.links.first, case .url(let url) = link.target else { return }
            let units = Array(line.utf16)
            guard let close = units.firstIndex(of: 0x5D), let open = units.firstIndex(of: 0x5B), open < close else { return }
            let name = String(decoding: units[(open + 1)..<close], as: UTF16.self)
            if normalized(name) == wanted {
                found = url
                stop.pointee = true
            }
        }
        return found
    }

    /// The heading whose GitHub-style slug matches ("My Heading" → "my-heading").
    static func headingLocation(slug: String, in text: NSString) -> Int? {
        lineStart(in: text) { line in
            let parsed = MarkdownLexer.lex(line)
            guard case .heading = parsed.kind else { return false }
            let units = Array(line.utf16)
            let title = String(decoding: units[parsed.contentStart...], as: UTF16.self)
            return Self.slug(title) == slug
        }
    }

    public static func slug(_ title: String) -> String {
        var result = ""
        for character in title.lowercased() {
            if character.isLetter || character.isNumber || character == "-" || character == "_" {
                result.append(character)
            } else if character == " " {
                result.append("-")
            }
        }
        return result
    }

    private static func normalized(_ label: String) -> String {
        label.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func lineStart(in text: NSString, where matches: (String) -> Bool) -> Int? {
        var location = 0
        let length = text.length
        while location < length {
            var lineEnd = 0, contentsEnd = 0
            text.getLineStart(nil, end: &lineEnd, contentsEnd: &contentsEnd, for: NSRange(location: location, length: 0))
            if matches(text.substring(with: NSRange(location: location, length: contentsEnd - location))) { return location }
            if lineEnd <= location { break }
            location = lineEnd
        }
        return nil
    }
}
