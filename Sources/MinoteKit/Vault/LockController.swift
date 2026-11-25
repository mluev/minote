import Foundation
import Observation

/// How long unlocked notes stay open without being used.
public enum LockTimeout: Int, CaseIterable, Identifiable, Sendable {
    case oneMinute = 1
    case fiveMinutes = 5
    case fifteenMinutes = 15
    case oneHour = 60
    /// Only when the device locks, sleeps or the app quits.
    case never = 0

    public var id: Int { rawValue }

    public var title: String {
        switch self {
        case .oneMinute: "After 1 Minute"
        case .fiveMinutes: "After 5 Minutes"
        case .fifteenMinutes: "After 15 Minutes"
        case .oneHour: "After 1 Hour"
        case .never: "Only When the Device Locks"
        }
    }

    var duration: Duration? {
        self == .never ? nil : .seconds(rawValue * 60)
    }
}

/// Locks after a stretch without use. One one-shot timer, armed only while
/// unlocked; activity only notes the time, so typing costs nothing, and the
/// timer wakes at most once per timeout to see whether it's time.
@MainActor
final class IdleTimer {
    var timeout: Duration?
    private var lastActivity = ContinuousClock.now
    private var timer: Task<Void, Never>?
    private let fire: @MainActor () -> Void

    init(timeout: Duration?, fire: @escaping @MainActor () -> Void) {
        self.timeout = timeout
        self.fire = fire
    }

    var isArmed: Bool { timer != nil }

    func noteActivity() {
        lastActivity = .now
    }

    func arm() {
        disarm()
        lastActivity = .now
        if let timeout { schedule(after: timeout) }
    }

    func disarm() {
        timer?.cancel()
        timer = nil
    }

    private func schedule(after delay: Duration) {
        timer = Task { [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            self?.check()
        }
    }

    private func check() {
        timer = nil
        guard let timeout else { return }
        let idle = ContinuousClock.now - lastActivity
        if idle >= timeout {
            fire()
        } else {
            schedule(after: timeout - idle)
        }
    }
}

/// What the lock screens, the password sheets and Settings talk to: unlocking
/// with the password or Touch ID / Face ID, locking again after a while, and
/// this device's lock preferences. Shared by the Mac and iOS apps.
@MainActor
@Observable
public final class LockController {
    public let library: Library
    @ObservationIgnored public let biometrics: any BiometricUnlocking
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var idle: IdleTimer!

    /// A password is being stretched into a key, or Touch ID is asking.
    public private(set) var isBusy = false
    public private(set) var lockAfter: LockTimeout
    /// The user wants Touch ID / Face ID on this device.
    public private(set) var useBiometrics: Bool
    /// Bumped when Touch ID is set up or forgotten, which views can't observe on disk.
    private var biometricChanges = 0
    /// When Touch ID last asked on its own (see `unlockAutomatically`).
    @ObservationIgnored private var lastAutomaticPrompt: ContinuousClock.Instant?

    static let lockAfterKey = "LockAfterMinutes"
    static let biometricsKey = "UnlockWithBiometrics"

    public init(library: Library, biometrics: any BiometricUnlocking, defaults: UserDefaults = .standard) {
        self.library = library
        self.biometrics = biometrics
        self.defaults = defaults
        lockAfter = (defaults.object(forKey: Self.lockAfterKey) as? Int).flatMap(LockTimeout.init(rawValue:)) ?? .fiveMinutes
        useBiometrics = defaults.object(forKey: Self.biometricsKey) as? Bool ?? true
        idle = IdleTimer(timeout: lockAfter.duration) { [weak self] in self?.lockNow() }
    }

    public var biometricName: String { biometrics.name }
    public var canUseBiometrics: Bool { biometrics.isAvailable }

    /// Touch ID / Face ID would open the current password's key on this device.
    public var isBiometricReady: Bool {
        _ = biometricChanges
        guard useBiometrics, canUseBiometrics, let keyID = library.vault?.key.keyID else { return false }
        return biometrics.isEnrolled(keyID)
    }

    // MARK: Preferences

    public func setLockAfter(_ timeout: LockTimeout) {
        lockAfter = timeout
        defaults.set(timeout.rawValue, forKey: Self.lockAfterKey)
        idle.timeout = timeout.duration
        if library.isUnlocked { idle.arm() }
    }

    public func setUseBiometrics(_ enabled: Bool) {
        useBiometrics = enabled
        defaults.set(enabled, forKey: Self.biometricsKey)
        if enabled {
            enrolIfWanted()
        } else if let keyID = library.vault?.key.keyID {
            biometrics.forget(keyID)
            biometricChanges += 1
        }
    }

    // MARK: Unlocking

    /// Something was typed or clicked: the idle timer starts over.
    public func noteActivity() {
        idle.noteActivity()
    }

    /// Throws `LockError.wrongPassword`.
    public func unlock(password: String) async throws {
        isBusy = true
        defer { isBusy = false }
        try await library.unlock(password: password)
        didUnlock()
    }

    /// False when Touch ID / Face ID isn't set up here, was dismissed, or the
    /// password is needed (fingerprints changed): the password field is next.
    @discardableResult
    public func unlockWithBiometrics(reason: String = "unlock your locked notes") async -> Bool {
        guard isBiometricReady, !isBusy, let record = library.vault?.key else { return false }
        isBusy = true
        defer { isBusy = false }
        do {
            let key = try await biometrics.unlock(record, reason: reason)
            guard library.unlock(with: key) else { return false }
            didUnlock()
            return true
        } catch {
            biometricChanges += 1
            return false
        }
    }

    /// Touch ID / Face ID without being asked: the app came forward, opened,
    /// or the device was unlocked. Not again within a few seconds of the last
    /// time: the prompt itself can make the app inactive and active again,
    /// and a dismissed prompt mustn't come straight back.
    @discardableResult
    public func unlockAutomatically(reason: String = "unlock your locked notes") async -> Bool {
        guard isBiometricReady, !isBusy, !library.isUnlocked else { return false }
        if let last = lastAutomaticPrompt, ContinuousClock.now - last < .seconds(3) { return false }
        lastAutomaticPrompt = .now
        let unlocked = await unlockWithBiometrics(reason: reason)
        lastAutomaticPrompt = .now
        return unlocked
    }

    public func lockNow() {
        library.lockNow()
        idle.disarm()
    }

    // MARK: Password

    /// Returns the recovery key, for the user to keep (it's shown only now).
    @discardableResult
    public func setPassword(_ password: String, hint: String?, scope: LockScope = .notes, useBiometrics: Bool) async throws -> RecoveryCode {
        isBusy = true
        defer {
            isBusy = false
            if library.isUnlocked { didUnlock() }
        }
        let code = try await library.setPassword(password, hint: hint)
        setUseBiometrics(useBiometrics)
        // The password is set: whatever happens now, the recovery key must reach the user.
        if scope == .library {
            do {
                try await library.setScope(.library)
            } catch {
                library.presentedError = LibraryError(title: "Couldn't lock every note", message: error.localizedDescription)
            }
        }
        return code
    }

    /// Throws `LockError.wrongPassword` when `old` isn't the current password.
    /// Returns the new recovery key.
    @discardableResult
    public func changePassword(from old: String, to new: String, hint: String?) async throws -> RecoveryCode {
        try await replacePassword { try await self.library.changePassword(from: old, to: new, hint: hint) }
    }

    /// Changes the password with Touch ID / Face ID instead of the current
    /// one: the way back from a forgotten password while the fingerprints
    /// still open the key. Asks afresh even when unlocked. Throws
    /// `BiometricError` when the prompt doesn't open the key.
    @discardableResult
    public func changePasswordWithBiometrics(to new: String, hint: String?) async throws -> RecoveryCode {
        guard isBiometricReady, let record = library.vault?.key else { throw BiometricError.notEnrolled }
        // Checked before the prompt, not after the user has put a finger down.
        try PasswordPolicy.check(password: new, hint: hint)
        return try await replacePassword {
            let key = try await self.biometrics.unlock(record, reason: "change the password of your locked notes")
            return try await self.library.changePassword(with: key, to: new, hint: hint)
        }
    }

    /// Sets a new password with the recovery key, when the password is
    /// forgotten. Throws `LockError.wrongRecoveryKey`. Returns the new
    /// recovery key: the one just used stops working.
    @discardableResult
    public func resetPassword(recoveryCode: RecoveryCode, to new: String, hint: String?) async throws -> RecoveryCode {
        try PasswordPolicy.check(password: new, hint: hint)
        return try await replacePassword {
            let key = try await self.library.key(recoveryCode: recoveryCode)
            return try await self.library.changePassword(with: key, to: new, hint: hint)
        }
    }

    /// A new recovery key for the current password (the old one stops
    /// working). Needs the library unlocked.
    public func makeRecoveryCode() async throws -> RecoveryCode {
        isBusy = true
        defer { isBusy = false }
        return try await library.makeRecoveryCode()
    }

    /// A password change: busy meanwhile, Touch ID set up for the new key
    /// and forgotten for the old one.
    private func replacePassword(_ change: () async throws -> RecoveryCode) async throws -> RecoveryCode {
        let oldKeyID = library.vault?.key.keyID
        isBusy = true
        defer {
            isBusy = false
            if library.isUnlocked { didUnlock() }
        }
        let code = try await change()
        if let oldKeyID, oldKeyID != library.vault?.key.keyID {
            biometrics.forget(oldKeyID)
            biometricChanges += 1
        }
        return code
    }

    public func removePassword() async throws {
        let keyID = library.vault?.key.keyID
        try await library.removePassword()
        if !library.hasPassword, let keyID {
            biometrics.forget(keyID)
            biometricChanges += 1
            idle.disarm()
        }
    }

    private func didUnlock() {
        enrolIfWanted()
        idle.arm()
    }

    private func enrolIfWanted() {
        guard useBiometrics, canUseBiometrics, let key = library.unlockedKey, !biometrics.isEnrolled(key.keyID) else { return }
        do {
            try biometrics.enrol(key)
        } catch {
            library.presentedError = LibraryError(
                title: "Couldn't set up \(biometrics.name)",
                message: "\(error.localizedDescription)\n\nYou can still unlock with your password."
            )
        }
        biometricChanges += 1
    }
}
