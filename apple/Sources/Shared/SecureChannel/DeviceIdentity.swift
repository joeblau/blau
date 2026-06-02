import Foundation
import CryptoKit

/// The device's long-term Curve25519 identity key pair for the peer-to-peer
/// secure channel (issue #51).
///
/// The private key is generated once and persisted in the Keychain; the base64
/// public key is what the user shares out-of-band with their peer (the peer
/// enters it during pairing so the Noise IK handshake can authenticate it).
///
/// This is the cross-platform (CryptoKit + Security only) storage layer that the
/// iOS/macOS UI builds on. It never exposes raw private bytes beyond what the
/// Keychain round-trip requires, and it caches the loaded key for the process
/// lifetime so repeated reads don't keep hitting the Keychain.
enum DeviceIdentity {

    /// Keychain generic-password account used to store the raw private key.
    private static let account = "app.blau.securechannel.identity"
    /// Service scopes the item to this app family.
    private static let service = "app.blau.securechannel"

    // Access to `cached` is always serialized by `lock`, so the unchecked
    // annotation is sound (Swift 6 can't prove the lock discipline statically).
    nonisolated(unsafe) private static var cached: Curve25519.KeyAgreement.PrivateKey?
    private static let lock = NSLock()

    /// Load the persisted identity key, generating and storing one on first use.
    /// Throws only if the Keychain is unavailable for write on first generation.
    static func loadOrCreate() throws -> Curve25519.KeyAgreement.PrivateKey {
        lock.lock()
        defer { lock.unlock() }

        if let cached { return cached }

        if let raw = try readKeychain(),
           let key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: raw) {
            cached = key
            return key
        }

        let key = Curve25519.KeyAgreement.PrivateKey()
        try writeKeychain(key.rawRepresentation)
        cached = key
        return key
    }

    /// The local device's public key as base64 — the value to share with a peer.
    /// Returns `nil` only if key generation/storage fails.
    static func publicKeyBase64() -> String? {
        guard let key = try? loadOrCreate() else { return nil }
        return key.publicKey.rawRepresentation.base64EncodedString()
    }

    /// Parse a peer's shared base64 public key back into a CryptoKit key, or
    /// `nil` if the string isn't a valid 32-byte X25519 key.
    static func parsePeerPublicKey(_ base64: String) -> Curve25519.KeyAgreement.PublicKey? {
        let trimmed = base64.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = Data(base64Encoded: trimmed),
              data.count == NoiseIK.keyLength,
              let key = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: data)
        else { return nil }
        return key
    }

    // MARK: - Keychain

    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private static func readKeychain() throws -> Data? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            return item as? Data
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.status(status)
        }
    }

    private static func writeKeychain(_ data: Data) throws {
        // Replace any existing item so generation is idempotent.
        SecItemDelete(baseQuery() as CFDictionary)

        var attributes = baseQuery()
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.status(status) }
    }

    enum KeychainError: Error {
        case status(OSStatus)
    }
}
