import Foundation
import Testing
@testable import MinoteKit

/// What the security audit asked for: a way back from a forgotten password,
/// passwords that hold up, a lock mode the vault file can't weaken, and no
/// plain backups outliving a lock made on another device.
@MainActor
@Suite("Lock hardening")
struct LockHardeningTests {
    private let password = "correct horse battery"
    private let newPassword = "another long password"
    private let marker = "ZEBRA-4242"

    private func makeLibrary(_ folder: TemporaryLibrary, store: NoteFileStore? = nil,
                             defaults: UserDefaults = freshDefaults()) async -> (Library, FakeEditor) {
        let library = Library(store: store ?? folder.makeStore(), timing: .fast, defaults: defaults, passwordRounds: testRounds)
        let editor = FakeEditor()
        library.attach(editor)
        await library.load()
        return (library, editor)
    }

    private func makeController(_ folder: TemporaryLibrary, defaults: UserDefaults = freshDefaults()) async
        -> (LockController, FakeBiometricUnlock) {
        let (library, _) = await makeLibrary(folder, defaults: defaults)
        let biometrics = FakeBiometricUnlock()
        return (LockController(library: library, biometrics: biometrics, defaults: defaults), biometrics)
    }

    private func note(_ stem: String, in library: Library) throws -> Note {
        try #require(library.notes.first { $0.fileStem == stem || $0.title == stem })
    }

    private func files(containing text: String, under root: URL) -> [String] {
        let needle = Data(text.utf8)
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
        return walker.compactMap { $0 as? URL }.filter {
            (try? Data(contentsOf: $0))?.range(of: needle) != nil
        }.map(\.lastPathComponent)
    }

    private func vaultFile(_ folder: TemporaryLibrary) throws -> VaultRecord {
        try VaultRecord.decode(Data(contentsOf: folder.notes.appendingPathComponent(VaultRecord.fileName)))
    }

    // MARK: Password rules

    @Test func shortPasswordsAndRevealingHintsAreRefused() async throws {
        let folder = try TemporaryLibrary()
        let (library, _) = await makeLibrary(folder)
        await #expect(throws: LockError.passwordTooShort) { try await library.setPassword("short", hint: nil) }
        await #expect(throws: LockError.hintRevealsPassword) {
            try await library.setPassword(password, hint: "it's Correct Horse Battery")
        }
        #expect(!library.hasPassword)
        try await library.setPassword(password, hint: "a horse")
        await #expect(throws: LockError.passwordTooShort) { try await library.changePassword(from: password, to: "tiny", hint: nil) }
        #expect(PasswordPolicy.problem(password: password, hint: "  correcthorsebattery ") == .hintRevealsPassword)
        #expect(PasswordPolicy.problem(password: password, hint: nil) == nil)
    }

    // MARK: Recovery key

    @Test func recoveryKeysReadAsTypedAndPrintInGroups() throws {
        let code = RecoveryCode.generate()
        #expect(code.description.count == 29)
        #expect(code.description.split(separator: "-").allSatisfy { $0.count == 4 })
        let typed = code.description.lowercased().replacingOccurrences(of: "-", with: " ")
        #expect(RecoveryCode(typed) == code)
        #expect(RecoveryCode("ABCD") == nil)
        #expect(RecoveryCode(String(repeating: "0", count: 24)) == nil) // Never has a zero.
        #expect(RecoveryCode.generate() != code)
    }

    @Test func theRecoveryKeyOpensTheKeyAndNothingElseDoes() throws {
        let code = RecoveryCode.generate()
        let key = try LibraryKey.create(password: password, hint: nil, rounds: testRounds, recoveryCode: code)
        #expect(try LibraryKey.unlock(key.record, recoveryCode: code).rawKey == key.rawKey)
        #expect(throws: LockError.wrongRecoveryKey) { try LibraryKey.unlock(key.record, recoveryCode: .generate()) }
        let without = try LibraryKey.create(password: password, hint: nil, rounds: testRounds)
        #expect(throws: LockError.noRecoveryKey) { try LibraryKey.unlock(without.record, recoveryCode: code) }
    }

    @Test("Forgot the password: the recovery key sets a new one, and is replaced")
    func theRecoveryKeyResetsAForgottenPassword() async throws {
        let folder = try TemporaryLibrary()
        try folder.write("Secret \(marker)", to: "Secret.md")
        let (controller, _) = await makeController(folder)
        let library = controller.library
        let code = try await controller.setPassword(password, hint: nil, useBiometrics: false)
        try await library.lock(try note("Secret", in: library).id)
        controller.lockNow()

        await #expect(throws: LockError.wrongRecoveryKey) {
            try await controller.resetPassword(recoveryCode: .generate(), to: newPassword, hint: nil)
        }
        #expect(!library.isUnlocked)
        let next = try await controller.resetPassword(recoveryCode: code, to: newPassword, hint: nil)
        await library.waitUntilIdle()
        #expect(library.isUnlocked)
        #expect(try note("Secret", in: library).text == "Secret \(marker)")
        #expect(next != code)

        controller.lockNow()
        await #expect(throws: LockError.wrongPassword) { try await library.unlock(password: password) }
        await #expect(throws: LockError.wrongRecoveryKey) { _ = try await library.key(recoveryCode: code) }
        try await library.unlock(password: newPassword)
        controller.lockNow()
        _ = try await library.key(recoveryCode: next)
        #expect(files(containing: marker, under: folder.root).isEmpty)
    }

    @Test("Forgot the password: Touch ID sets a new one")
    func touchIDChangesAForgottenPassword() async throws {
        let folder = try TemporaryLibrary()
        try folder.write("Secret", to: "Secret.md")
        let (controller, biometrics) = await makeController(folder)
        let library = controller.library
        try await controller.setPassword(password, hint: nil, useBiometrics: true)
        try await library.lock(try note("Secret", in: library).id)
        let oldKeyID = try #require(library.vault?.key.keyID)
        controller.lockNow()

        biometrics.nextResult = .cancelled
        await #expect(throws: BiometricError.cancelled) { try await controller.changePasswordWithBiometrics(to: newPassword, hint: nil) }
        #expect(library.vault?.key.keyID == oldKeyID)

        try await controller.changePasswordWithBiometrics(to: newPassword, hint: nil)
        await library.waitUntilIdle()
        #expect(library.isUnlocked)
        #expect(library.vault?.key.keyID != oldKeyID)
        #expect(!biometrics.isEnrolled(oldKeyID))
        #expect(controller.isBiometricReady)
        controller.lockNow()
        try await library.unlock(password: newPassword)
        await library.waitUntilIdle()
        #expect(try note("Secret", in: library).text == "Secret")
    }

    @Test func aNewRecoveryKeyRetiresTheOldOne() async throws {
        let folder = try TemporaryLibrary()
        try folder.write("One", to: "One.md")
        let (library, _) = await makeLibrary(folder)
        let old = try await library.setPassword(password, hint: nil)
        try await library.lock(try note("One", in: library).id)
        let fresh = try await library.makeRecoveryCode()
        await library.waitUntilIdle()

        #expect(try vaultFile(folder).key.recovery == library.vault?.key.recovery)
        let header = try await folder.makeStore().lockedRecord(at: folder.notes.appendingPathComponent("One.mdlock"))
        #expect(header == library.vault?.key)
        #expect(throws: LockError.wrongRecoveryKey) { try LibraryKey.unlock(header, recoveryCode: old) }
        _ = try LibraryKey.unlock(header, recoveryCode: fresh)
        // The password is unchanged.
        library.lockNow()
        try await library.unlock(password: password)
    }

    // MARK: Whole library mode can't be edited away

    private func editVaultScope(_ folder: TemporaryLibrary, to scope: String) throws {
        let url = folder.notes.appendingPathComponent(VaultRecord.fileName)
        var json = try String(contentsOf: url, encoding: .utf8)
        json = json.replacingOccurrences(of: "\"library\"", with: "\"\(scope)\"").replacingOccurrences(of: "\"notes\"", with: "\"\(scope)\"")
        try json.write(to: url, atomically: true, encoding: .utf8)
    }

    @Test("Whole Library edited to Selected Notes in the vault file: still locked, and put back")
    func editingTheVaultCantTurnOffWholeLibrary() async throws {
        let folder = try TemporaryLibrary()
        let defaults = freshDefaults()
        let (library, _) = await makeLibrary(folder, defaults: defaults)
        try await library.setPassword(password, hint: nil)
        try await library.setScope(.library)
        library.lockNow()
        try editVaultScope(folder, to: "notes")

        // Next launch on this device.
        let (next, editor) = await makeLibrary(folder, defaults: defaults)
        #expect(next.isLibraryLocked)
        #expect(next.makeDraft() == nil)
        next.newNote()
        editor.type("New \(marker)", in: next)
        await next.waitUntilIdle()
        #expect(files(containing: marker, under: folder.root).isEmpty)

        try await next.unlock(password: password)
        await next.waitUntilIdle()
        #expect(next.lockScope == .library)
        #expect(next.presentedError != nil)
        #expect(try vaultFile(folder).scope == .library)
    }

    @Test("Another device that never saw Whole Library still can't be fooled by a broken signature")
    func aBrokenSignatureLocksTheWholeLibrary() async throws {
        let folder = try TemporaryLibrary()
        try folder.write("Plain \(marker)", to: "Plain.md")
        let (library, _) = await makeLibrary(folder)
        try await library.setPassword(password, hint: nil)
        try await library.setScope(.library)
        library.lockNow()
        try editVaultScope(folder, to: "notes")

        let (other, _) = await makeLibrary(folder) // Its own preferences: no copy of the vault.
        try await other.unlock(password: password)
        await other.waitUntilIdle()
        #expect(other.lockScope == .library)
    }

    @Test("Selected Notes chosen on another device is believed once unlocked here")
    func aRealChangeElsewhereIsTakenAfterUnlocking() async throws {
        let folder = try TemporaryLibrary()
        let (a, _) = await makeLibrary(folder)
        try await a.setPassword(password, hint: nil)
        try await a.setScope(.library)

        let (b, _) = await makeLibrary(folder)
        #expect(b.isLibraryLocked)
        try await a.setScope(.notes)
        await b.rescanNow()
        // Held until B can check it.
        #expect(b.isLibraryLocked)
        try await b.unlock(password: password)
        #expect(b.lockScope == .notes)
        #expect(b.presentedError == nil)
    }

    @Test("An old copy of the vault put back can't undo Whole Library")
    func anOldVaultPutBackIsIgnored() async throws {
        let folder = try TemporaryLibrary()
        let defaults = freshDefaults()
        let (library, _) = await makeLibrary(folder, defaults: defaults)
        try await library.setPassword(password, hint: nil)
        let url = folder.notes.appendingPathComponent(VaultRecord.fileName)
        let old = try Data(contentsOf: url) // Signed, Selected Notes.
        try await library.setScope(.library)
        library.lockNow()
        try old.write(to: url)

        let (next, _) = await makeLibrary(folder, defaults: defaults)
        #expect(next.isLibraryLocked)
        try await next.unlock(password: password)
        await next.waitUntilIdle()
        #expect(next.lockScope == .library)
        #expect(try vaultFile(folder).scope == .library)
    }

    @Test func aVaultRebuiltFromTheNotesKeepsSelectedNotes() async throws {
        let folder = try TemporaryLibrary()
        try folder.write("Kept", to: "Kept.md")
        let (library, _) = await makeLibrary(folder)
        try await library.setPassword(password, hint: nil)
        try await library.lock(try note("Kept", in: library).id)
        try FileManager.default.removeItem(at: folder.notes.appendingPathComponent(VaultRecord.fileName))

        let (other, _) = await makeLibrary(folder)
        await other.waitUntilIdle()
        try await other.unlock(password: password)
        await other.waitUntilIdle()
        #expect(other.lockScope == .notes)
        #expect(other.presentedError == nil)
        #expect(try vaultFile(folder).isSigned(by: try #require(other.unlockedKey)))
    }

    // MARK: Plain backups

    private func store(_ folder: TemporaryLibrary, backups: String) -> NoteFileStore {
        let trash = folder.trash
        return NoteFileStore(directory: folder.notes, backupDirectory: folder.root.appendingPathComponent(backups)) { url in
            let destination = trash.appendingPathComponent("\(UUID().uuidString)-\(url.lastPathComponent)")
            try FileManager.default.moveItem(at: url, to: destination)
            return destination
        }
    }

    @Test("Locked on another device: this device's plain backups of it go too")
    func lockingElsewhereRemovesThisDevicesPlainBackups() async throws {
        let folder = try TemporaryLibrary()
        try folder.write("Diary \(marker)\nfirst", to: "Diary.md")
        let backupsA = folder.root.appendingPathComponent("BackupsA")
        let (a, editorA) = await makeLibrary(folder, store: store(folder, backups: "BackupsA"))
        a.selectedID = try note("Diary", in: a).id
        editorA.type("", in: a) // Emptied on A: a plain backup there.
        await a.waitUntilIdle()
        editorA.type("Diary\nsecond", in: a)
        await a.waitUntilIdle()
        #expect(!files(containing: marker, under: backupsA).isEmpty)
        // Renamed after the backup (the backup keeps the old name).
        try FileManager.default.moveItem(at: folder.notes.appendingPathComponent("Diary.md"),
                                         to: folder.notes.appendingPathComponent("Journal.md"))
        await a.rescanNow()

        let (b, _) = await makeLibrary(folder, store: store(folder, backups: "BackupsB"))
        try await b.setPassword(password, hint: nil)
        try await b.lock(try note("Journal", in: b).id)
        await a.rescanNow()

        #expect(files(containing: marker, under: backupsA).isEmpty)
    }

    @Test("At launch, plain backups named like a locked note go; sealed ones and others stay")
    func launchingRemovesPlainBackupsOfLockedNotes() async throws {
        let folder = try TemporaryLibrary()
        try folder.write("Secret \(marker)", to: "Secret.md")
        try folder.write("Other", to: "Other.md")
        let (library, _) = await makeLibrary(folder)
        try await library.setPassword(password, hint: nil)
        try await library.lock(try note("Secret", in: library).id)
        try FileManager.default.createDirectory(at: folder.backups, withIntermediateDirectories: true)
        let sealed = try Data(contentsOf: folder.notes.appendingPathComponent("Secret.mdlock"))
        try "old \(marker)".write(to: folder.backups.appendingPathComponent("2026-01-01T00-00-00Z Secret.md"), atomically: true, encoding: .utf8)
        try sealed.write(to: folder.backups.appendingPathComponent("2026-01-02T00-00-00Z Secret.mdlock"))
        try "other".write(to: folder.backups.appendingPathComponent("2026-01-03T00-00-00Z Other.md"), atomically: true, encoding: .utf8)

        let (next, _) = await makeLibrary(folder)
        _ = next
        let left = try FileManager.default.contentsOfDirectory(atPath: folder.backups.path).sorted()
        #expect(left == ["2026-01-02T00-00-00Z Secret.mdlock", "2026-01-03T00-00-00Z Other.md"])
    }
}
