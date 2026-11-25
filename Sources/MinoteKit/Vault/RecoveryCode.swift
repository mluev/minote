import CryptoKit
import Foundation

/// The second way into the library key, for a forgotten password: 24 random
/// characters (120 bits), shown once to be printed or kept in a password
/// manager. Unlike a password it can't be guessed, so it has no hint.
public struct RecoveryCode: Sendable, Equatable, CustomStringConvertible {
    /// No I, O, 0 or 1: nothing that reads as something else on paper.
    static let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
    static let length = 24

    /// Upper case, without dashes or spaces: what the key is derived from.
    let characters: String

    private init(characters: String) {
        self.characters = characters
    }

    public static func generate() -> RecoveryCode {
        // 32 symbols divide 256 evenly: every symbol is equally likely.
        let bytes = SymmetricKey(size: SymmetricKeySize(bitCount: length * 8)).withUnsafeBytes { Array($0) }
        return RecoveryCode(characters: String(bytes.map { alphabet[Int($0) % alphabet.count] }))
    }

    /// The key as typed: any case, with or without dashes and spaces. Nil
    /// when it can't be a recovery key (wrong length, or a letter it never has).
    public init?(_ typed: String) {
        let cleaned = typed.uppercased().filter { !$0.isWhitespace && $0 != "-" }
        guard cleaned.count == Self.length, cleaned.allSatisfy(Self.alphabet.contains) else { return nil }
        characters = cleaned
    }

    /// In groups of four, as it's shown and printed: "ABCD-EFGH-…".
    public var description: String {
        stride(from: 0, to: characters.count, by: 4).map { start in
            let from = characters.index(characters.startIndex, offsetBy: start)
            return String(characters[from..<characters.index(from, offsetBy: 4)])
        }.joined(separator: "-")
    }
}

/// What a password must be. Checked by `Library` before any password is set,
/// so every app and the debug driver obey it, not only the sheets.
public enum PasswordPolicy {
    /// Long enough that guessing it against a copied file takes years rather
    /// than hours, even on graphics cards (each guess costs `PasswordKey.defaultRounds`).
    public static let minimumLength = 12
    /// Wrong attempts before the hint shows: a nudge for the owner, but not
    /// handed to whoever tries a password first.
    public static let hintAfterFailures = 3

    /// What's wrong with this password and hint, or nil when they'll do.
    public static func problem(password: String, hint: String?) -> LockError? {
        if password.count < minimumLength { return .passwordTooShort }
        if let hint, !hint.isEmpty {
            let hint = comparable(hint), secret = comparable(password)
            if !secret.isEmpty && hint.contains(secret) { return .hintRevealsPassword }
        }
        return nil
    }

    public static func check(password: String, hint: String?) throws {
        if let problem = problem(password: password, hint: hint) { throw problem }
    }

    /// Case, accents typed apart and spacing ignored: "Correct Horse" in a
    /// hint gives away "correcthorse".
    private static func comparable(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping.lowercased().filter { !$0.isWhitespace }
    }
}
