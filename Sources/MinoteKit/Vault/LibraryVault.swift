import Foundation

/// What gets locked.
public enum LockScope: String, Codable, Sendable {
    /// Only the notes the user locks.
    case notes
    /// Every note: new notes start locked and the app opens behind a lock screen.
    case library
}

/// The library's password and lock mode, kept in a hidden file in the library
/// folder so every device sees the same ones. Holds nothing secret: the key in
/// it is sealed with the password.
public struct VaultRecord: Codable, Sendable, Equatable {
    public static let fileName = ".minote-vault"
    static let currentVersion = 1

    public var version: Int
    public var key: KeyRecord
    public var scope: LockScope
    /// Counts changes of `scope`, so an old copy of this file put back can't
    /// undo a later change. Nil (0) in records written before it existed.
    public var scopeRevision: Int?
    /// `scope` and `scopeRevision` signed with the library key. Anything can
    /// edit this file, but only Minote, unlocked, can sign it: a record that
    /// asks to lock less without a valid signature isn't believed (see
    /// `Library.trustedScope`). Nil in a record rebuilt from a note's header.
    public var scopeCheck: Data?

    /// An unsigned record (rebuilt from a locked note's header while locked).
    public init(key: KeyRecord, scope: LockScope) {
        version = Self.currentVersion
        self.key = key
        self.scope = scope
    }

    /// A record signed with the library key: what Minote writes.
    init(key record: KeyRecord, scope: LockScope, revision: Int, signedWith key: LibraryKey) {
        self.init(key: record, scope: scope)
        scopeRevision = revision
        scopeCheck = key.scopeCheck(scope, revision: revision)
    }

    var revision: Int { scopeRevision ?? 0 }

    /// Minote wrote this lock mode with `key`, and nothing changed it since.
    func isSigned(by key: LibraryKey) -> Bool {
        guard let scopeCheck, self.key.keyID == key.keyID else { return false }
        return scopeCheck == key.scopeCheck(scope, revision: revision)
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return try encoder.encode(self)
    }

    static func decode(_ data: Data) throws -> VaultRecord {
        let record = try JSONDecoder().decode(VaultRecord.self, from: data)
        guard record.version <= currentVersion else { throw LockError.unsupportedVersion }
        return record
    }
}

/// What reading the vault file found.
public enum VaultRead: Sendable, Equatable {
    /// No vault: no password was ever set for this folder.
    case missing
    /// iCloud has a vault this device hasn't downloaded yet.
    case pending
    case found(VaultRecord)
    /// There is a file, but it can't be read (damaged, or from a newer Minote).
    case unreadable
}

/// The last vault this device saw, kept outside the library folder. Stands in
/// while the real one is unavailable (not downloaded yet, or iCloud is off and
/// the library is on this device meanwhile), so the lock mode never lapses.
struct VaultMirror {
    static let key = "LockVault"

    let defaults: UserDefaults

    var record: VaultRecord? {
        get { defaults.data(forKey: Self.key).flatMap { try? VaultRecord.decode($0) } }
        nonmutating set {
            if let newValue, let data = try? newValue.encoded() {
                defaults.set(data, forKey: Self.key)
            } else {
                defaults.removeObject(forKey: Self.key)
            }
        }
    }
}
