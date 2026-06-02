import Foundation
import CryptoKit

/// Low-level crypto primitives for the peer-to-peer secure channel.
///
/// Everything here is cross-platform (CryptoKit only — no UIKit/AppKit) and
/// pure value-layer so it can be unit-tested without sockets. The handshake and
/// transport layers build on these helpers; this file deliberately knows
/// nothing about packets, sockets, or the connection state machine.
enum CryptoCore {

    // MARK: - Transcript hashing

    /// A running SHA-256 transcript hash. The Noise-style handshake "mixes" each
    /// public element (ephemeral keys, ciphertexts) into this hash so that the
    /// final key derivation is bound to the exact bytes both sides observed. Any
    /// divergence (tampering, wrong key) yields different transport keys and an
    /// AEAD open failure.
    struct Transcript {
        private(set) var hash: Data

        /// Seed the transcript with a fixed protocol label so unrelated
        /// protocols can never collide on the same derived material.
        init(protocolLabel: String) {
            self.hash = Data(SHA256.hash(data: Data(protocolLabel.utf8)))
        }

        /// Fold a chunk of bytes into the transcript: `h = SHA256(h || data)`.
        mutating func mix(_ data: Data) {
            var hasher = SHA256()
            hasher.update(data: hash)
            hasher.update(data: data)
            hash = Data(hasher.finalize())
        }
    }

    // MARK: - Diffie-Hellman

    /// Thrown when an X25519 agreement produces an all-zero shared secret,
    /// which indicates a low-order/contributory-behaviour attack (a peer-chosen
    /// ephemeral that cancels that DH's contribution to the chaining key).
    struct InvalidPublicKeyError: Error {}

    /// X25519 ECDH shared secret as raw bytes.
    ///
    /// CryptoKit accepts low-order points and does not itself reject an all-zero
    /// shared secret, so we reject it here in constant time. An all-zero output
    /// means the peer forced the DH contribution to a known value, removing that
    /// exchange's contribution to forward secrecy / key agreement.
    static func dh(
        _ privateKey: Curve25519.KeyAgreement.PrivateKey,
        _ publicKey: Curve25519.KeyAgreement.PublicKey
    ) throws -> Data {
        let shared = try privateKey.sharedSecretFromKeyAgreement(with: publicKey)
        let bytes = shared.withUnsafeBytes { Data($0) }
        // Constant-time all-zero check (OR-accumulate every byte).
        var acc: UInt8 = 0
        for b in bytes { acc |= b }
        guard acc != 0 else { throw InvalidPublicKeyError() }
        return bytes
    }

    // MARK: - HKDF chaining

    /// Mix a DH output into the running chaining key, returning the next
    /// chaining key plus a fresh AEAD key. This is the Noise `MixKey` step:
    /// `(ck', k) = HKDF(ck, dh, info)` split into two 32-byte halves.
    ///
    /// The transcript hash is folded into `info` so the derived AEAD key is
    /// authenticated against everything seen so far.
    static func mixKey(
        chainingKey: Data,
        input: Data,
        transcript: Data
    ) -> (chainingKey: Data, messageKey: SymmetricKey) {
        let salt = chainingKey
        let okm = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: input),
            salt: salt,
            info: Data("blau-p2p mixkey".utf8) + transcript,
            outputByteCount: 64
        )
        let bytes = okm.withUnsafeBytes { Data($0) }
        let newCK = bytes.prefix(32)
        let mk = SymmetricKey(data: bytes.suffix(32))
        return (Data(newCK), mk)
    }

    /// Final split: derive the two directional transport keys and their 96-bit
    /// base nonces from the finished chaining key. Both static public keys and
    /// the full transcript are bound into `info`, so a wrong static key on
    /// either side produces different keys and the first transport (or the
    /// handshake AEAD) fails to open — that is the authentication guarantee.
    static func splitTransport(
        chainingKey: Data,
        transcript: Data,
        initiatorStatic: Curve25519.KeyAgreement.PublicKey,
        responderStatic: Curve25519.KeyAgreement.PublicKey
    ) -> TransportKeys {
        var info = Data("blau-p2p split v1".utf8)
        info.append(transcript)
        info.append(initiatorStatic.rawRepresentation)
        info.append(responderStatic.rawRepresentation)

        // 2 keys (32 each) + 2 base nonces (12 each) = 88 bytes.
        let okm = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: chainingKey),
            salt: Data(),
            info: info,
            outputByteCount: 88
        )
        let bytes = okm.withUnsafeBytes { Data($0) }
        let kI2R = SymmetricKey(data: bytes[0..<32])
        let kR2I = SymmetricKey(data: bytes[32..<64])
        let nI2R = Data(bytes[64..<76])
        let nR2I = Data(bytes[76..<88])
        return TransportKeys(
            initiatorToResponderKey: kI2R,
            responderToInitiatorKey: kR2I,
            initiatorToResponderBaseNonce: nI2R,
            responderToInitiatorBaseNonce: nR2I
        )
    }
}

/// The two directional transport keys + base nonces produced by the handshake.
struct TransportKeys: Equatable {
    let initiatorToResponderKey: SymmetricKey
    let responderToInitiatorKey: SymmetricKey
    let initiatorToResponderBaseNonce: Data
    let responderToInitiatorBaseNonce: Data
}
