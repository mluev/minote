import Foundation
import Testing
@testable import MinoteKit

@MainActor
@Suite("Lock controller")
struct LockControllerTests {
    private let password = "correct horse battery"
    private let newPassword = "another long password"

    private func makeController(_ folder: TemporaryLibrary, defaults: UserDefaults = freshDefaults()) async
        -> (LockController, FakeBiometricUnlock) {
        let library = Library(store: folder.makeStore(), timing: .fast, defaults: defaults, passwordRounds: testRounds)
        library.attach(FakeEditor())
        await library.load()
        let biometrics = FakeBiometricUnlock()
        return (LockController(library: library, biometrics: biometrics, defaults: defaults), biometrics)
    }

    @Test func touchIDIsSetUpWithThePasswordAndUnlocks() async throws {
        let folder = try TemporaryLibrary()
        let (controller, _) = await makeController(folder)
        try await controller.setPassword(password, hint: nil, useBiometrics: true)
        #expect(controller.isBiometricReady)

        controller.lockNow()
        #expect(!controller.library.isUnlocked)
        #expect(await controller.unlockWithBiometrics())
        #expect(controller.library.isUnlocked)
    }

    @Test func aDismissedPromptLeavesTheNotesLocked() async throws {
        let folder = try TemporaryLibrary()
        let (controller, biometrics) = await makeController(folder)
        try await controller.setPassword(password, hint: nil, useBiometrics: true)
        controller.lockNow()

        biometrics.nextResult = .cancelled
        #expect(await !controller.unlockWithBiometrics())
        #expect(!controller.library.isUnlocked)
    }

    @Test("Changed fingerprints: the password once, then Touch ID again")
    func changedFingerprintsNeedThePasswordOnce() async throws {
        let folder = try TemporaryLibrary()
        let (controller, biometrics) = await makeController(folder)
        try await controller.setPassword(password, hint: nil, useBiometrics: true)
        controller.lockNow()

        biometrics.nextResult = .invalidated
        #expect(await !controller.unlockWithBiometrics())
        #expect(!controller.isBiometricReady)
        try await controller.unlock(password: password)
        #expect(controller.isBiometricReady)
    }

    @Test func aNewPasswordIsSetUpForTouchIDAndTheOldOneForgotten() async throws {
        let folder = try TemporaryLibrary()
        let (controller, biometrics) = await makeController(folder)
        try await controller.setPassword(password, hint: nil, useBiometrics: true)
        let oldKeyID = try #require(controller.library.vault?.key.keyID)
        try await controller.changePassword(from: password, to: newPassword, hint: nil)

        #expect(!biometrics.isEnrolled(oldKeyID))
        #expect(controller.isBiometricReady)
    }

    @Test func turningTouchIDOffForgetsTheKey() async throws {
        let folder = try TemporaryLibrary()
        let (controller, biometrics) = await makeController(folder)
        try await controller.setPassword(password, hint: nil, useBiometrics: true)
        let keyID = try #require(controller.library.vault?.key.keyID)
        controller.setUseBiometrics(false)
        #expect(!biometrics.isEnrolled(keyID))
        controller.lockNow()
        #expect(await !controller.unlockWithBiometrics())
    }

    @Test func idleTimeLocks() async throws {
        var fired = 0
        let timer = IdleTimer(timeout: .milliseconds(300)) { fired += 1 }
        timer.arm()
        // Activity pushes the deadline back.
        for _ in 0..<5 {
            try await Task.sleep(for: .milliseconds(100))
            timer.noteActivity()
        }
        #expect(fired == 0)
        try await Task.sleep(for: .milliseconds(900))
        #expect(fired == 1)
        #expect(!timer.isArmed)
    }

    @Test func noIdleTimeoutMeansNoTimer() {
        let timer = IdleTimer(timeout: nil) {}
        timer.arm()
        #expect(!timer.isArmed)
    }

    @Test func thePreferencesAreRemembered() async throws {
        let defaults = freshDefaults()
        let folder = try TemporaryLibrary()
        let (controller, _) = await makeController(folder, defaults: defaults)
        #expect(controller.lockAfter == .fiveMinutes)
        controller.setLockAfter(.oneHour)
        controller.setUseBiometrics(false)
        let (again, _) = await makeController(folder, defaults: defaults)
        #expect(again.lockAfter == .oneHour)
        #expect(!again.useBiometrics)
    }
}
