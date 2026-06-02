import Foundation
import CryptoKit

/// A simplified Noise IK handshake using CryptoKit primitives only.
///
/// "IK": the **I**nitiator already **K**nows the responder's static public key
/// (the user enters it once during pairing), and the initiator transmits its
/// own static key encrypted within the handshake. On success both sides derive
/// the same pair of directional transport keys (see ``TransportKeys``).
///
/// Message flow:
///
///   msg1  I -> R:  e_I (clear)  ||  AEAD( s_I )  ||  AEAD( payload )
///                  keyed by HKDF over DH(e_I, s_R) then DH(s_I, s_R),
///                  transcript-mixed.
///   msg2  R -> I:  e_R (clear)  ||  AEAD( payload )
///                  keyed by HKDF over DH(e_R, e_I) then DH(e_R, s_I).
///
/// After msg2 both sides split the chaining key into transport keys. The
/// responder's and initiator's static public keys are bound into the final
/// HKDF `info`, so a wrong `s_R` (initiator side) or a forged `s_I` (responder
/// side) makes an AEAD open fail and the handshake aborts — that is the mutual
/// authentication.
enum NoiseIK {

    static let protocolLabel = "Noise_IK_25519_ChaChaPoly_SHA256/blau-p2p-v1"

    enum HandshakeError: Error, Equatable {
        case decryptFailed   // wrong static key / tampered handshake message
        case malformedMessage
        case unauthorizedPeer // initiator static key not in the responder's allow-list
    }

    /// 32-byte X25519 public key length.
    static let keyLength = 32

    // A throwaway all-zero nonce is safe here: each handshake AEAD uses a
    // freshly derived one-time key (HKDF output is unique per handshake), so the
    // (key, nonce) pair never repeats.
    fileprivate static var zeroNonce: ChaChaPoly.Nonce {
        try! ChaChaPoly.Nonce(data: Data(repeating: 0, count: 12))
    }

    fileprivate static func sealRaw(_ plaintext: Data, key: SymmetricKey) throws -> Data {
        let box = try ChaChaPoly.seal(plaintext, using: key, nonce: zeroNonce)
        return box.ciphertext + box.tag
    }

    fileprivate static func openRaw(_ sealed: Data, key: SymmetricKey) throws -> Data {
        guard sealed.count >= PacketCodec.tagLength else { throw HandshakeError.malformedMessage }
        let split = sealed.index(sealed.endIndex, offsetBy: -PacketCodec.tagLength)
        let ct = sealed[sealed.startIndex..<split]
        let tag = sealed[split...]
        do {
            let box = try ChaChaPoly.SealedBox(nonce: zeroNonce, ciphertext: ct, tag: tag)
            return try ChaChaPoly.open(box, using: key)
        } catch {
            throw HandshakeError.decryptFailed
        }
    }

    // MARK: - Initiator

    /// State carried by the initiator between sending msg1 and receiving msg2.
    struct Initiator {
        let staticKey: Curve25519.KeyAgreement.PrivateKey
        let responderStatic: Curve25519.KeyAgreement.PublicKey
        fileprivate let ephemeral: Curve25519.KeyAgreement.PrivateKey
        fileprivate var transcript: CryptoCore.Transcript
        fileprivate var chainingKey: Data

        /// Build msg1. Returns the handshake state plus the wire bytes to send.
        static func start(
            staticKey: Curve25519.KeyAgreement.PrivateKey,
            responderStatic: Curve25519.KeyAgreement.PublicKey,
            payload: Data = Data()
        ) throws -> (state: Initiator, message: Data) {
            let ephemeral = Curve25519.KeyAgreement.PrivateKey()
            var transcript = CryptoCore.Transcript(protocolLabel: protocolLabel)
            var ck = Data(SHA256.hash(data: Data(protocolLabel.utf8)))

            // Canonical Noise_IK mixes the pre-known responder static key into
            // the transcript hash before any ephemeral, so the transcript (a
            // legitimate channel-binding value) commits to the responder
            // identity from the start.
            transcript.mix(responderStatic.rawRepresentation)

            // e_I in the clear; mix into transcript.
            let ePub = ephemeral.publicKey.rawRepresentation
            transcript.mix(ePub)

            // es = DH(e_I, s_R) -> static-encryption key.
            let es = try CryptoCore.dh(ephemeral, responderStatic)
            let m1 = CryptoCore.mixKey(chainingKey: ck, input: es, transcript: transcript.hash)
            ck = m1.chainingKey

            let sealedStatic = try NoiseIK.sealRaw(staticKey.publicKey.rawRepresentation, key: m1.messageKey)
            transcript.mix(sealedStatic)

            // ss = DH(s_I, s_R) -> payload key.
            let ss = try CryptoCore.dh(staticKey, responderStatic)
            let m2 = CryptoCore.mixKey(chainingKey: ck, input: ss, transcript: transcript.hash)
            ck = m2.chainingKey

            let sealedPayload = try NoiseIK.sealRaw(payload, key: m2.messageKey)
            transcript.mix(sealedPayload)

            var message = Data()
            message.append(ePub)
            message.append(sealedStatic)
            message.append(sealedPayload)

            let state = Initiator(
                staticKey: staticKey,
                responderStatic: responderStatic,
                ephemeral: ephemeral,
                transcript: transcript,
                chainingKey: ck
            )
            return (state, message)
        }

        /// Consume msg2 from the responder. Returns the derived transport keys
        /// plus any responder payload. Throws on auth failure.
        func receive(_ message: Data) throws -> (keys: TransportKeys, payload: Data) {
            var transcript = transcript
            var ck = chainingKey

            guard message.count >= keyLength + PacketCodec.tagLength else {
                throw HandshakeError.malformedMessage
            }
            let base = message.startIndex
            let eRBytes = message[base..<(base + keyLength)]
            guard let eR = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: Data(eRBytes)) else {
                throw HandshakeError.malformedMessage
            }
            transcript.mix(Data(eRBytes))

            // ee = DH(e_I, e_R) — matches responder's DH(e_R, e_I).
            let ee = try CryptoCore.dh(ephemeral, eR)
            let m1 = CryptoCore.mixKey(chainingKey: ck, input: ee, transcript: transcript.hash)
            ck = m1.chainingKey

            // se = DH(s_I, e_R) — matches responder's DH(e_R, s_I).
            let se = try CryptoCore.dh(staticKey, eR)
            let m2 = CryptoCore.mixKey(chainingKey: ck, input: se, transcript: transcript.hash)
            ck = m2.chainingKey

            let sealed = Data(message[(base + keyLength)...])
            let payload = try NoiseIK.openRaw(sealed, key: m2.messageKey)
            transcript.mix(sealed)

            let keys = CryptoCore.splitTransport(
                chainingKey: ck,
                transcript: transcript.hash,
                initiatorStatic: staticKey.publicKey,
                responderStatic: responderStatic
            )
            return (keys, payload)
        }
    }

    // MARK: - Responder

    /// State carried by the responder between receiving msg1 and sending msg2.
    struct Responder {
        let staticKey: Curve25519.KeyAgreement.PrivateKey
        /// Initiator's authenticated static public key, recovered from msg1.
        let initiatorStatic: Curve25519.KeyAgreement.PublicKey
        /// Any payload the initiator carried in msg1.
        let initiatorPayload: Data

        fileprivate let ephemeral: Curve25519.KeyAgreement.PrivateKey
        fileprivate let initiatorEphemeral: Curve25519.KeyAgreement.PublicKey
        fileprivate var transcript: CryptoCore.Transcript
        fileprivate var chainingKey: Data

        /// Consume msg1. Recovers and authenticates the initiator's static key
        /// and payload. Throws on auth failure (e.g. the initiator used the
        /// wrong responder static key, so `es` differs and the AEAD won't open).
        ///
        /// Raw Noise IK authenticates that *some* initiator possesses the static
        /// key it presents, but it cannot tell whether that initiator is the peer
        /// the user actually paired with. The caller MUST therefore supply an
        /// `authorize` closure that checks the recovered initiator static key
        /// against the pinned/allow-listed peer; otherwise the responder would
        /// establish an authenticated session with any attacker who knows the
        /// responder's (out-of-band shared) static key. When `authorize` returns
        /// `false` this throws `.unauthorizedPeer` and no transport keys are ever
        /// released. The default closure accepts any key — pass an explicit pin
        /// for real (non-test) callers.
        static func receive(
            staticKey: Curve25519.KeyAgreement.PrivateKey,
            message: Data,
            authorize: (Curve25519.KeyAgreement.PublicKey) -> Bool = { _ in true }
        ) throws -> Responder {
            var transcript = CryptoCore.Transcript(protocolLabel: protocolLabel)
            var ck = Data(SHA256.hash(data: Data(protocolLabel.utf8)))

            // Symmetric with the initiator: bind this responder's own static
            // identity into the transcript before any ephemeral.
            transcript.mix(staticKey.publicKey.rawRepresentation)

            let sealedStaticLen = keyLength + PacketCodec.tagLength
            guard message.count >= keyLength + sealedStaticLen + PacketCodec.tagLength else {
                throw HandshakeError.malformedMessage
            }
            let base = message.startIndex
            let eIBytes = message[base..<(base + keyLength)]
            guard let eI = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: Data(eIBytes)) else {
                throw HandshakeError.malformedMessage
            }
            transcript.mix(Data(eIBytes))

            // es = DH(s_R, e_I) — matches initiator's DH(e_I, s_R).
            let es = try CryptoCore.dh(staticKey, eI)
            let m1 = CryptoCore.mixKey(chainingKey: ck, input: es, transcript: transcript.hash)
            ck = m1.chainingKey

            let staticStart = base + keyLength
            let sealedStatic = Data(message[staticStart..<(staticStart + sealedStaticLen)])
            let sIBytes = try NoiseIK.openRaw(sealedStatic, key: m1.messageKey)
            guard let sI = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: sIBytes) else {
                throw HandshakeError.malformedMessage
            }
            // Reject unpinned initiators before doing any further work or
            // releasing transport keys. This closes the unknown-key-share /
            // spoofed-initiator gap that raw IK leaves open on the responder.
            guard authorize(sI) else { throw HandshakeError.unauthorizedPeer }
            transcript.mix(sealedStatic)

            // ss = DH(s_R, s_I) -> payload key.
            let ss = try CryptoCore.dh(staticKey, sI)
            let m2 = CryptoCore.mixKey(chainingKey: ck, input: ss, transcript: transcript.hash)
            ck = m2.chainingKey

            let payloadStart = staticStart + sealedStaticLen
            let sealedPayload = Data(message[payloadStart...])
            let payload = try NoiseIK.openRaw(sealedPayload, key: m2.messageKey)
            transcript.mix(sealedPayload)

            return Responder(
                staticKey: staticKey,
                initiatorStatic: sI,
                initiatorPayload: payload,
                ephemeral: Curve25519.KeyAgreement.PrivateKey(),
                initiatorEphemeral: eI,
                transcript: transcript,
                chainingKey: ck
            )
        }

        /// Build msg2 and derive the final transport keys.
        func respond(payload: Data = Data()) throws -> (keys: TransportKeys, message: Data) {
            var transcript = transcript
            var ck = chainingKey

            let ePub = ephemeral.publicKey.rawRepresentation
            transcript.mix(ePub)

            // ee = DH(e_R, e_I).
            let ee = try CryptoCore.dh(ephemeral, initiatorEphemeral)
            let m1 = CryptoCore.mixKey(chainingKey: ck, input: ee, transcript: transcript.hash)
            ck = m1.chainingKey

            // se = DH(e_R, s_I).
            let se = try CryptoCore.dh(ephemeral, initiatorStatic)
            let m2 = CryptoCore.mixKey(chainingKey: ck, input: se, transcript: transcript.hash)
            ck = m2.chainingKey

            let sealed = try NoiseIK.sealRaw(payload, key: m2.messageKey)
            transcript.mix(sealed)

            var message = Data()
            message.append(ePub)
            message.append(sealed)

            let keys = CryptoCore.splitTransport(
                chainingKey: ck,
                transcript: transcript.hash,
                initiatorStatic: initiatorStatic,
                responderStatic: staticKey.publicKey
            )
            return (keys, message)
        }
    }
}
