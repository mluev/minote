import CryptoKit
import Foundation
import LocalAuthentication
import Security

/// Why Touch ID or Face ID didn't unlock.
public enum BiometricError: Error, Equatable {
    /// Not set up for this password on this device.
    case notEnrolled
    /// The user dismissed the prompt.
    case cancelled
    /// The user chose to type the password instead.
    case fallback
    /// Fingerprints or faces changed since it was set up: the password is
    /// needed once, and Touch ID is set up again.
    case invalidated
    case failed(String)
}

/// Unlocking with Touch ID or Face ID, on this device only.
@MainActor
public protocol BiometricUnlocking: AnyObject {
    /// Whether this device has a Secure Enclave and enrolled fingerprints or faces.
    var isAvailable: Bool { get }
    /// "Touch ID", "Face ID" or "Optic ID".
    var name: String { get }
    func isEnrolled(_ keyID: UUID) -> Bool
    /// Keeps the key for unlocking with biometrics from now on.
    func enrol(_ key: LibraryKey) throws
    /// Shows the system prompt and returns the key it opened.
    func unlock(_ record: KeyRecord, reason: String) async throws -> LibraryKey
    func forget(_ keyID: UUID)
}

/// The library key, sealed to a key that lives in this device's Secure Enclave
/// and can be used only right after the user's fingerprint or face. The sealed
/// key sits in Application Support (never synced); without the Secure Enclave
/// of this very device, and the user's finger, it's useless. No keychain, so
/// no entitlement: it works in ad-hoc signed builds too.
@MainActor
public final class SecureEnclaveUnlock: BiometricUnlocking {
    private let directory: URL

    public init(directory: URL = URL.applicationSupportDirectory
        .appendingPathComponent("Minote", isDirectory: true)
        .appendingPathComponent("Unlock", isDirectory: true)) {
        self.directory = directory
    }

    private struct Stored: Codable {
        /// The Secure Enclave key, as an opaque handle only this device can use.
        let enclaveKey: Data
        let ephemeralPublicKey: Data
        let sealedKey: Data
    }

    /// Asked once per launch: views read it on every render.
    public private(set) lazy var isAvailable: Bool = {
        guard SecureEnclave.isAvailable else { return false }
        var error: NSError?
        return LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
    }()

    public private(set) lazy var name: String = {
        let context = LAContext()
        var error: NSError?
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
        switch context.biometryType {
        case .faceID: return "Face ID"
        case .opticID: return "Optic ID"
        default: return "Touch ID"
        }
    }()

    public func isEnrolled(_ keyID: UUID) -> Bool {
        FileManager.default.fileExists(atPath: file(for: keyID).path)
    }

    public func enrol(_ key: LibraryKey) throws {
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(
            nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, [.privateKeyUsage, .biometryCurrentSet], &error
        ) else {
            throw error.map { $0.takeRetainedValue() as Error } ?? BiometricError.failed("No access control")
        }
        let enclaveKey = try SecureEnclave.P256.KeyAgreement.PrivateKey(accessControl: access)
        // Sealing needs no fingerprint: only the Secure Enclave's public half.
        let ephemeral = P256.KeyAgreement.PrivateKey()
        let wrapping = try Self.wrappingKey(ephemeral.sharedSecretFromKeyAgreement(with: enclaveKey.publicKey), keyID: key.keyID)
        let sealed = try AES.GCM.seal(key.rawKey, using: wrapping)
        let stored = Stored(enclaveKey: enclaveKey.dataRepresentation,
                            ephemeralPublicKey: ephemeral.publicKey.rawRepresentation,
                            sealedKey: sealed.combined!)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(stored).write(to: file(for: key.keyID), options: .atomic)
    }

    public func unlock(_ record: KeyRecord, reason: String) async throws -> LibraryKey {
        guard let data = try? Data(contentsOf: file(for: record.keyID)),
              let stored = try? JSONDecoder().decode(Stored.self, from: data) else { throw BiometricError.notEnrolled }
        let context = LAContext()
        context.localizedFallbackTitle = "Enter Password"
        do {
            // Asked first so the prompt says why; the Secure Enclave key then uses this approval.
            _ = try await context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason)
        } catch let error as LAError {
            switch error.code {
            case .userCancel, .systemCancel, .appCancel: throw BiometricError.cancelled
            case .userFallback: throw BiometricError.fallback
            default: throw BiometricError.failed(error.localizedDescription)
            }
        }
        do {
            let enclaveKey = try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: stored.enclaveKey, authenticationContext: context)
            let publicKey = try P256.KeyAgreement.PublicKey(rawRepresentation: stored.ephemeralPublicKey)
            let wrapping = try Self.wrappingKey(enclaveKey.sharedSecretFromKeyAgreement(with: publicKey), keyID: record.keyID)
            let raw = try AES.GCM.open(AES.GCM.SealedBox(combined: stored.sealedKey), using: wrapping)
            return try LibraryKey(record: record, rawKey: raw)
        } catch {
            // Enrolled fingerprints changed (`biometryCurrentSet`), or the file is damaged.
            forget(record.keyID)
            throw BiometricError.invalidated
        }
    }

    public func forget(_ keyID: UUID) {
        try? FileManager.default.removeItem(at: file(for: keyID))
    }

    private func file(for keyID: UUID) -> URL {
        directory.appendingPathComponent("\(keyID.uuidString).json", isDirectory: false)
    }

    private static func wrappingKey(_ secret: SharedSecret, keyID: UUID) -> SymmetricKey {
        secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: keyID.data,
                                       sharedInfo: Data("minote-biometric-unlock".utf8), outputByteCount: 32)
    }
}

/// Stands in for Touch ID where there's no finger to put on it: unit tests,
/// the debug driver and UI tests.
@MainActor
public final class FakeBiometricUnlock: BiometricUnlocking {
    public var isAvailable = true
    public var name = "Touch ID"
    /// What the next prompt does: nil unlocks, an error is thrown.
    public var nextResult: BiometricError?
    private var keys: [UUID: LibraryKey] = [:]

    public init() {}

    public func isEnrolled(_ keyID: UUID) -> Bool { keys[keyID] != nil }

    public func enrol(_ key: LibraryKey) throws { keys[key.keyID] = key }

    public func unlock(_ record: KeyRecord, reason: String) async throws -> LibraryKey {
        if let error = nextResult {
            nextResult = nil
            if error == .invalidated { keys[record.keyID] = nil }
            throw error
        }
        guard let key = keys[record.keyID] else { throw BiometricError.notEnrolled }
        return key
    }

    public func forget(_ keyID: UUID) { keys[keyID] = nil }
}
