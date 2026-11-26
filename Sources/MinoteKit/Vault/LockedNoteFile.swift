import CommonCrypto
import CryptoKit
import Foundation

/// Why a locked note couldn't be opened, saved or unlocked.
public enum LockError: Error, Equatable, LocalizedError {
    case wrongPassword
    /// The file was changed by something other than Minote, or is cut short.
    case damaged
    /// The note was sealed with a key the library doesn't hold (an earlier password).
    case lockedWithAnotherPassword
    case unsupportedVersion
    /// A locked note was read as text.
    case lockedNote
    case noPassword
    case notUnlocked
    /// The notes being moved and the folder they move to use different passwords.
    case differentPasswords
    /// The library's password isn't known yet (still being read or downloaded).
    case notReady
    /// Shorter than `PasswordPolicy.minimumLength`.
    case passwordTooShort
    /// The hint, which anyone can read, gives the password away.
    case hintRevealsPassword
    case wrongRecoveryKey
    /// The password was set without a recovery key.
    case noRecoveryKey

    public var errorDescription: String? {
        switch self {
        case .wrongPassword: "The password is incorrect."
        case .damaged: "This locked note is damaged and can't be opened."
        case .lockedWithAnotherPassword: "This note was locked with a different password."
        case .unsupportedVersion: "This locked note was made by a newer version of Minote."
        case .lockedNote: "This is a locked Minote note. Open it from Minote's library."
        case .noPassword: "Set a password for locked notes first."
        case .notUnlocked: "Unlock your locked notes first."
        case .differentPasswords: "The notes there are locked with a different password."
        case .notReady: "Minote is still reading your library. Try again in a moment."
        case .passwordTooShort: "Use at least \(PasswordPolicy.minimumLength) characters. A few unrelated words make a strong password that's easy to remember."
        case .hintRevealsPassword: "The hint can't contain the password: anyone can read it."
        case .wrongRecoveryKey: "That recovery key doesn't open these notes."
        case .noRecoveryKey: "This password has no recovery key."
        }
    }
}

/// Turns a password into a key with PBKDF2-HMAC-SHA256: slow on purpose, so
/// guessing passwords against a copied file takes a long time.
public enum PasswordKey {
    /// OWASP's 2023 figure for PBKDF2-HMAC-SHA256. Stored with every record,
    /// so it can rise later without breaking older files.
    public static let defaultRounds = 600_000
    /// Far above anything Minote writes; a record asking for more is refused.
    static let maxRounds = 20_000_000
    static let algorithm = "pbkdf2-sha256"

    /// Takes a noticeable fraction of a second: never call it on the main thread.
    static func derive(_ password: String, salt: Data, rounds: Int) throws -> SymmetricKey {
        // The same password typed on another keyboard may arrive decomposed.
        let normalized = password.precomposedStringWithCanonicalMapping
        let length = normalized.utf8.count
        var derived = [UInt8](repeating: 0, count: 32)
        defer { derived.withUnsafeMutableBytes { _ = memset_s($0.baseAddress, $0.count, 0, $0.count) } }
        let status = normalized.withCString { password in
            salt.withUnsafeBytes { salt in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    password, length,
                    salt.bindMemory(to: UInt8.self).baseAddress, salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(clamping: rounds),
                    &derived, derived.count
                )
            }
        }
        guard status == kCCSuccess else { throw LockError.damaged }
        return SymmetricKey(data: derived)
    }
}

/// The library key, sealed with a key derived from the password. Not secret:
/// it's kept in the vault file and in every locked note, so each locked note
/// can be opened with the password on its own.
public struct KeyRecord: Codable, Sendable, Equatable {
    public let keyID: UUID
    public let kdf: String
    public let rounds: Int
    public let salt: Data
    public let wrappedKey: Data
    /// Proves that a key recovered without the password (Touch ID) is this one.
    public let keyCheck: Data
    public let hint: String?
    /// The same key, sealed with the recovery key: the way in when the
    /// password is forgotten. Nil for a password set without one.
    public let recovery: RecoveryRecord?
}

/// The library key sealed with a key derived from the recovery key, the way
/// `KeyRecord` seals it with the password.
public struct RecoveryRecord: Codable, Sendable, Equatable {
    public let rounds: Int
    public let salt: Data
    public let wrappedKey: Data
}

/// The key every locked note of a library is sealed with, one per password.
/// Lives only in memory, while the notes are unlocked.
public struct LibraryKey: Sendable {
    public let record: KeyRecord
    let key: SymmetricKey

    public var keyID: UUID { record.keyID }

    /// A new random key, protected by `password`, and by `recoveryCode` when given.
    /// Doesn't check `PasswordPolicy`: `Library` does, before calling this.
    public static func create(password: String, hint: String?, rounds: Int = PasswordKey.defaultRounds,
                              recoveryCode: RecoveryCode? = nil) throws -> LibraryKey {
        let keyID = UUID()
        let key = SymmetricKey(size: .bits256)
        let salt = newSalt()
        let wrappingKey = try PasswordKey.derive(password, salt: salt, rounds: rounds)
        let wrapped = try AES.GCM.seal(key.withUnsafeBytes { Data($0) }, using: wrappingKey, authenticating: wrapContext(keyID))
        let hint = hint?.trimmingCharacters(in: .whitespacesAndNewlines)
        let record = KeyRecord(
            keyID: keyID, kdf: PasswordKey.algorithm, rounds: rounds, salt: salt,
            wrappedKey: wrapped.combined!, keyCheck: keyCheck(key, keyID),
            hint: hint?.isEmpty == false ? hint : nil,
            recovery: try recoveryCode.map { try recoveryRecord(key, keyID: keyID, code: $0, rounds: rounds) }
        )
        return LibraryKey(record: record, key: key)
    }

    /// The same key and password with a new recovery key. Notes sealed from
    /// now on carry the new one; the old one still opens notes sealed before.
    /// Slow (see `PasswordKey`): never call it on the main thread.
    public func withRecoveryCode(_ code: RecoveryCode) throws -> LibraryKey {
        let updated = KeyRecord(
            keyID: record.keyID, kdf: record.kdf, rounds: record.rounds, salt: record.salt,
            wrappedKey: record.wrappedKey, keyCheck: record.keyCheck, hint: record.hint,
            recovery: try Self.recoveryRecord(key, keyID: record.keyID, code: code, rounds: record.rounds)
        )
        return LibraryKey(record: updated, key: key)
    }

    /// Opens the record with the recovery key instead of the password.
    /// Throws `LockError.wrongRecoveryKey`, or `.noRecoveryKey` when it has none.
    /// Slow (see `PasswordKey`): never call it on the main thread.
    public static func unlock(_ record: KeyRecord, recoveryCode: RecoveryCode) throws -> LibraryKey {
        guard let recovery = record.recovery else { throw LockError.noRecoveryKey }
        guard (1...PasswordKey.maxRounds).contains(recovery.rounds), recovery.salt.count >= 16 else { throw LockError.damaged }
        let wrappingKey = try PasswordKey.derive(recoveryCode.characters, salt: recovery.salt, rounds: recovery.rounds)
        do {
            let box = try AES.GCM.SealedBox(combined: recovery.wrappedKey)
            let raw = try AES.GCM.open(box, using: wrappingKey, authenticating: recoveryContext(record.keyID))
            return try LibraryKey(record: record, rawKey: raw)
        } catch {
            throw LockError.wrongRecoveryKey
        }
    }

    private static func recoveryRecord(_ key: SymmetricKey, keyID: UUID, code: RecoveryCode, rounds: Int) throws -> RecoveryRecord {
        let salt = newSalt()
        let wrappingKey = try PasswordKey.derive(code.characters, salt: salt, rounds: rounds)
        let wrapped = try AES.GCM.seal(key.withUnsafeBytes { Data($0) }, using: wrappingKey, authenticating: recoveryContext(keyID))
        return RecoveryRecord(rounds: rounds, salt: salt, wrappedKey: wrapped.combined!)
    }

    private static func newSalt() -> Data {
        SymmetricKey(size: .bits128).withUnsafeBytes { Data($0) }
    }

    /// The lock mode, signed with this key, so the vault file can't be edited
    /// to lock less than the user chose (see `VaultRecord.scopeCheck`).
    func scopeCheck(_ scope: LockScope, revision: Int) -> Data {
        var message = Data("minote-lock-scope".utf8) + keyID.data + Data(scope.rawValue.utf8)
        withUnsafeBytes(of: Int64(revision).bigEndian) { message.append(contentsOf: $0) }
        return Data(HMAC<SHA256>.authenticationCode(for: message, using: key))
    }

    /// Opens the record with the password. Throws `LockError.wrongPassword`.
    /// Slow (see `PasswordKey`): never call it on the main thread.
    public static func unlock(_ record: KeyRecord, password: String) throws -> LibraryKey {
        guard record.kdf == PasswordKey.algorithm else { throw LockError.unsupportedVersion }
        // The record isn't authenticated: a planted one mustn't make unlocking hang.
        guard (1...PasswordKey.maxRounds).contains(record.rounds), record.salt.count >= 16 else { throw LockError.damaged }
        let wrappingKey = try PasswordKey.derive(password, salt: record.salt, rounds: record.rounds)
        let raw: Data
        do {
            let box = try AES.GCM.SealedBox(combined: record.wrappedKey)
            raw = try AES.GCM.open(box, using: wrappingKey, authenticating: wrapContext(record.keyID))
        } catch {
            throw LockError.wrongPassword
        }
        return try LibraryKey(record: record, rawKey: raw)
    }

    /// A key recovered another way (Touch ID), checked against its record.
    public init(record: KeyRecord, rawKey: Data) throws {
        let key = SymmetricKey(data: rawKey)
        guard rawKey.count == 32, Self.keyCheck(key, record.keyID) == record.keyCheck else { throw LockError.wrongPassword }
        self.init(record: record, key: key)
    }

    private init(record: KeyRecord, key: SymmetricKey) {
        self.record = record
        self.key = key
    }

    /// The key's bytes, for sealing it to this device's Secure Enclave.
    public var rawKey: Data { key.withUnsafeBytes { Data($0) } }

    private static func wrapContext(_ keyID: UUID) -> Data {
        Data("minote-library-key".utf8) + keyID.data
    }

    private static func recoveryContext(_ keyID: UUID) -> Data {
        Data("minote-recovery-key".utf8) + keyID.data
    }

    private static func keyCheck(_ key: SymmetricKey, _ keyID: UUID) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data("minote-key-check".utf8) + keyID.data, using: key))
    }
}

/// How a locked note is stored: a readable first line saying what the file is,
/// a header holding the password record, then the note's text sealed with
/// AES-GCM. The header is authenticated with the text, so neither can be
/// swapped or altered without the note refusing to open.
///
///     "MINOTE-LOCKED\n" · version (1 byte) · header length (UInt32, big-endian) · header (JSON) · sealed text
public enum LockedNoteFile {
    public static let fileExtension = "mdlock"
    static let magic = Data("MINOTE-LOCKED\n".utf8)
    static let version: UInt8 = 1

    /// Whether these bytes are a locked note, whatever the file is called.
    public static func isLocked(_ data: Data) -> Bool {
        data.starts(with: magic)
    }

    /// The password record a locked note was sealed with.
    public static func record(of data: Data) throws -> KeyRecord {
        try parse(data).record
    }

    static func seal(_ text: String, with key: LibraryKey) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let header = try encoder.encode(key.record)
        var prefix = magic
        prefix.append(version)
        withUnsafeBytes(of: UInt32(header.count).bigEndian) { prefix.append(contentsOf: $0) }
        prefix.append(header)
        let box = try AES.GCM.seal(Data(text.utf8), using: key.key, authenticating: prefix)
        return prefix + box.combined!
    }

    /// The note's text and the record it was sealed with. `key` returns the
    /// key for a key ID, or nil when the library doesn't hold it.
    static func open(_ data: Data, key: (UUID) -> SymmetricKey?) throws -> (text: String, record: KeyRecord) {
        let parsed = try parse(data)
        guard let symmetricKey = key(parsed.record.keyID) else { throw LockError.lockedWithAnotherPassword }
        do {
            let box = try AES.GCM.SealedBox(combined: parsed.body)
            let plain = try AES.GCM.open(box, using: symmetricKey, authenticating: parsed.prefix)
            guard let text = String(data: plain, encoding: .utf8) else { throw LockError.damaged }
            return (text, parsed.record)
        } catch let error as LockError {
            throw error
        } catch {
            throw LockError.damaged
        }
    }

    private struct Parsed {
        let record: KeyRecord
        let prefix: Data
        let body: Data
    }

    private static func parse(_ data: Data) throws -> Parsed {
        let bytes = [UInt8](data)
        guard bytes.starts(with: magic) else { throw LockError.damaged }
        var offset = magic.count
        guard bytes.count >= offset + 5 else { throw LockError.damaged }
        guard bytes[offset] == version else {
            throw bytes[offset] > version ? LockError.unsupportedVersion : LockError.damaged
        }
        offset += 1
        let length = bytes[offset..<offset + 4].reduce(0) { $0 << 8 | Int($1) }
        offset += 4
        guard length > 0, bytes.count > offset + length else { throw LockError.damaged }
        let header = Data(bytes[offset..<offset + length])
        offset += length
        guard let record = try? JSONDecoder().decode(KeyRecord.self, from: header) else { throw LockError.damaged }
        return Parsed(record: record, prefix: Data(bytes[..<offset]), body: Data(bytes[offset...]))
    }
}

/// Seals and opens locked notes while the library is unlocked: the current
/// key, plus keys of earlier passwords for notes not yet sealed again.
public struct NoteSealer: Sendable {
    public private(set) var current: LibraryKey
    private var earlier: [UUID: SymmetricKey] = [:]

    public init(_ key: LibraryKey) {
        current = key
    }

    public var keyID: UUID { current.keyID }

    /// The same key with a new record (a new recovery key): saves carry it from now on.
    func replacingRecord(with key: LibraryKey) -> NoteSealer {
        guard key.keyID == current.keyID else { return self }
        var copy = self
        copy.current = key
        return copy
    }

    /// Also reads notes sealed with `key`. New saves still use `current`.
    func reading(_ key: LibraryKey) -> NoteSealer {
        guard key.keyID != current.keyID else { return self }
        var copy = self
        copy.earlier[key.keyID] = key.key
        return copy
    }

    func canOpen(_ keyID: UUID) -> Bool {
        keyID == current.keyID || earlier[keyID] != nil
    }

    public func seal(_ text: String) throws -> Data {
        try LockedNoteFile.seal(text, with: current)
    }

    /// The text and the key ID it was sealed with.
    public func open(_ data: Data) throws -> (text: String, keyID: UUID) {
        let opened = try LockedNoteFile.open(data) { id in id == current.keyID ? current.key : earlier[id] }
        return (opened.text, opened.record.keyID)
    }
}

extension UUID {
    var data: Data { withUnsafeBytes(of: uuid) { Data($0) } }
}
