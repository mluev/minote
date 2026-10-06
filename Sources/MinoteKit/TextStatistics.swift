import Foundation

/// Words, characters and reading time for the counter.
public struct TextStatistics: Equatable, Sendable {
    public var words: Int
    public var characters: Int

    public init(words: Int, characters: Int) {
        self.words = words
        self.characters = characters
    }

    /// Minutes at an average silent-reading speed of 238 words per minute.
    public var readingMinutes: Int {
        words == 0 ? 0 : max(1, Int((Double(words) / 238).rounded()))
    }

    /// Counts words the way a writer would: runs of letters and digits (Markdown
    /// markup isn't a word); each CJK ideograph counts as a word. Characters
    /// exclude line breaks.
    public init(_ text: String) {
        var words = 0
        var inWord = false
        for scalar in text.unicodeScalars {
            let properties = scalar.properties
            if properties.isIdeographic {
                words += 1
                inWord = false
            } else if properties.isAlphabetic || properties.numericType != nil {
                if !inWord { words += 1 }
                inWord = true
            } else if inWord, scalar == "'" || scalar == "’" || scalar == "-" {
                continue // Apostrophes and hyphens join a word: don't, well-known.
            } else {
                inWord = false
            }
        }
        var characters = 0
        for character in text where !character.isNewline { characters += 1 }
        self.init(words: words, characters: characters)
    }
}
