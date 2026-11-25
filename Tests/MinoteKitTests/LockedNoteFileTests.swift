import CryptoKit
import Foundation
import Testing
@testable import MinoteKit

/// Few rounds keep the tests fast; the format and the checks are the same.
let testRounds = 1_000

@Suite("Locked note format")
struct LockedNoteFileTests {
    @Test func sealedTextOpensWithTheSameKey() throws {
        let key = try LibraryKey.create(password: "correct horse", hint: "a horse", rounds: testRounds)
        let sealer = NoteSealer(key)
        let data = try sealer.seal("Secret\nplans with ünïcödé ✓")

        #expect(LockedNoteFile.isLocked(data))
        #expect(data.range(of: Data("Secret".utf8)) == nil)
        #expect(data.range(of: Data("plans".utf8)) == nil)
        let opened = try sealer.open(data)
        #expect(opened.text == "Secret\nplans with ünïcödé ✓")
        #expect(opened.keyID == key.keyID)
        #expect(try LockedNoteFile.record(of: data) == key.record)
    }

    @Test func everySealUsesAFreshNonce() throws {
        let sealer = NoteSealer(try LibraryKey.create(password: "pw", hint: nil, rounds: testRounds))
        #expect(try sealer.seal("same") != sealer.seal("same"))
    }

    @Test func thePasswordUnlocksTheRecord() throws {
        let key = try LibraryKey.create(password: "correct horse", hint: nil, rounds: testRounds)
        let unlocked = try LibraryKey.unlock(key.record, password: "correct horse")
        #expect(unlocked.rawKey == key.rawKey)
        #expect(throws: LockError.wrongPassword) { try LibraryKey.unlock(key.record, password: "wrong horse") }
        #expect(throws: LockError.wrongPassword) { try LibraryKey.unlock(key.record, password: "") }
    }

    @Test("A password typed decomposed (e + ◌́) matches the precomposed one")
    func passwordsAreNormalized() throws {
        let key = try LibraryKey.create(password: "caf\u{E9}", hint: nil, rounds: testRounds)
        #expect(throws: Never.self) { try LibraryKey.unlock(key.record, password: "cafe\u{301}") }
    }

    @Test func aKeyFromElsewhereIsCheckedAgainstItsRecord() throws {
        let key = try LibraryKey.create(password: "pw", hint: nil, rounds: testRounds)
        #expect(try LibraryKey(record: key.record, rawKey: key.rawKey).rawKey == key.rawKey)
        let other = try LibraryKey.create(password: "pw", hint: nil, rounds: testRounds)
        #expect(throws: LockError.wrongPassword) { try LibraryKey(record: key.record, rawKey: other.rawKey) }
    }

    @Test func anotherKeyCantOpenANote() throws {
        let data = try NoteSealer(try LibraryKey.create(password: "a", hint: nil, rounds: testRounds)).seal("text")
        let other = NoteSealer(try LibraryKey.create(password: "a", hint: nil, rounds: testRounds))
        #expect(throws: LockError.lockedWithAnotherPassword) { try other.open(data) }
    }

    @Test func anEarlierKeyStillReadsItsNotes() throws {
        let old = try LibraryKey.create(password: "old", hint: nil, rounds: testRounds)
        let data = try NoteSealer(old).seal("from before")
        let sealer = NoteSealer(try LibraryKey.create(password: "new", hint: nil, rounds: testRounds)).reading(old)
        #expect(try sealer.open(data) == ("from before", old.keyID))
    }

    @Test("Changing any byte, in the header or the text, is detected")
    func tamperingIsDetected() throws {
        let sealer = NoteSealer(try LibraryKey.create(password: "pw", hint: "hint", rounds: testRounds))
        let data = try sealer.seal("Do not touch")
        let headerEnd = data.count - 12 - 16 - "Do not touch".utf8.count
        for index in [LockedNoteFile.magic.count + 6, headerEnd - 2, headerEnd + 3, data.count - 1] {
            var damaged = data
            damaged[index] ^= 0x01
            #expect(throws: (any Error).self) { try sealer.open(damaged) }
        }
        #expect(throws: LockError.damaged) { try sealer.open(data.prefix(data.count - 20)) }
        #expect(throws: LockError.damaged) { try sealer.open(Data("plain text".utf8)) }
    }

    @Test func aNewerFormatIsRefusedClearly() throws {
        var data = try NoteSealer(try LibraryKey.create(password: "pw", hint: nil, rounds: testRounds)).seal("x")
        data[LockedNoteFile.magic.count] = 9
        #expect(throws: LockError.unsupportedVersion) { try LockedNoteFile.record(of: data) }
    }

    @Test func theHintIsKeptAndEmptyHintsAreDropped() throws {
        #expect(try LibraryKey.create(password: "pw", hint: "  the usual  ", rounds: testRounds).record.hint == "the usual")
        #expect(try LibraryKey.create(password: "pw", hint: "  ", rounds: testRounds).record.hint == nil)
    }

    @Test func theVaultRoundTrips() throws {
        let key = try LibraryKey.create(password: "pw", hint: nil, rounds: testRounds)
        let vault = VaultRecord(key: key.record, scope: .library)
        #expect(try VaultRecord.decode(vault.encoded()) == vault)

        let defaults = freshDefaults()
        let mirror = VaultMirror(defaults: defaults)
        #expect(mirror.record == nil)
        mirror.record = vault
        #expect(VaultMirror(defaults: defaults).record == vault)
        mirror.record = nil
        #expect(mirror.record == nil)
    }
}
