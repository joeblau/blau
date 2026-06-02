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
    /// Account for the paired peer's public key (base64), auto-synced over the
    /// encrypted Multipeer channel (issue #51).
    private static let peerAccount = "app.blau.securechannel.peer"
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

        if let raw = try readKeychain(account: account),
           let key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: raw) {
            cached = key
            return key
        }

        let key = Curve25519.KeyAgreement.PrivateKey()
        try writeKeychain(key.rawRepresentation, account: account)
        cached = key
        return key
    }

    /// The local device's public key as base64 — the value to share with a peer.
    /// Returns `nil` only if key generation/storage fails.
    static func publicKeyBase64() -> String? {
        guard let key = try? loadOrCreate() else { return nil }
        return key.publicKey.rawRepresentation.base64EncodedString()
    }

    /// Discard the current identity and generate a fresh key pair (e.g. the
    /// user tapped "Regenerate & re-sync"). The new public key must then be
    /// re-announced to the peer.
    @discardableResult
    static func regenerate() throws -> Curve25519.KeyAgreement.PrivateKey {
        lock.lock()
        defer { lock.unlock() }
        let key = Curve25519.KeyAgreement.PrivateKey()
        try writeKeychain(key.rawRepresentation, account: account)
        cached = key
        return key
    }

    /// Persist the paired peer's public key (base64), trusting it for the
    /// handshake. Overwrites any previously trusted peer.
    static func storePeerPublicKey(_ base64: String) {
        guard parsePeerPublicKey(base64) != nil,
              let data = base64.data(using: .utf8) else { return }
        try? writeKeychain(data, account: peerAccount)
    }

    /// The trusted peer's public key (base64), if one has been synced.
    static func peerPublicKeyBase64() -> String? {
        guard let data = try? readKeychain(account: peerAccount),
              let value = String(data: data, encoding: .utf8) else { return nil }
        return value
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

    private static func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private static func readKeychain(account: String) throws -> Data? {
        var query = baseQuery(account: account)
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

    private static func writeKeychain(_ data: Data, account: String) throws {
        // Replace any existing item so writes are idempotent.
        SecItemDelete(baseQuery(account: account) as CFDictionary)

        var attributes = baseQuery(account: account)
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.status(status) }
    }

    enum KeychainError: Error {
        case status(OSStatus)
    }
}
