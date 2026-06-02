import Foundation
import CryptoKit

/// Wire format + AEAD seal/open for the encrypted transport.
///
/// Packet layout (all multi-byte integers big-endian):
///
///     version(1, =0x01) | type(1) | counter(UInt64 BE) | ciphertext | tag(16)
///
/// The 10-byte header (`version|type|counter`) is authenticated as ChaChaPoly
/// AAD but sent in the clear. The per-packet nonce is `baseNonce XOR counter`,
/// where `counter` is a per-direction monotonic sequence number. The base nonce
/// is derived once by the handshake (see `CryptoCore.splitTransport`).
enum PacketCodec {

    static let version: UInt8 = 0x01
    static let tagLength = 16
    static let headerLength = 10  // 1 + 1 + 8

    /// Logical packet kinds carried on the channel.
    enum PacketType: UInt8 {
        case handshake = 0x01      // Noise IK handshake messages
        case reliableControl = 0x02 // JSON utf8 control message, ACK-tracked
        case ack = 0x03            // acknowledges a reliable message by msgID
        case bestEffortBlob = 0x04  // fire-and-forget blob / video chunk
    }

    enum CodecError: Error, Equatable {
        case shortPacket
        case badVersion(UInt8)
        case unknownType(UInt8)
        case openFailed
    }

    /// A decoded-but-still-sealed packet: header fields plus the encrypted body.
    struct SealedPacket {
        let type: PacketType
        let counter: UInt64
        let ciphertextAndTag: Data
    }

    // MARK: - Header

    static func encodeHeader(type: PacketType, counter: UInt64) -> Data {
        var data = Data(capacity: headerLength)
        data.append(version)
        data.append(type.rawValue)
        var be = counter.bigEndian
        withUnsafeBytes(of: &be) { data.append(contentsOf: $0) }
        return data
    }

    // MARK: - Nonce

    /// `nonce = baseNonce XOR counter`. The 8-byte big-endian counter is XORed
    /// into the low 8 bytes of the 12-byte base nonce, guaranteeing a unique
    /// nonce per (direction, counter) for the lifetime of the key.
    static func nonce(baseNonce: Data, counter: UInt64) -> Data {
        precondition(baseNonce.count == 12, "base nonce must be 12 bytes")
        var bytes = [UInt8](baseNonce)
        var be = counter.bigEndian
        withUnsafeBytes(of: &be) { ctr in
            for i in 0..<8 {
                bytes[4 + i] ^= ctr[i]
            }
        }
        return Data(bytes)
    }

    // MARK: - Seal / Open

    /// Seal a plaintext into a complete on-wire packet.
    static func seal(
        type: PacketType,
        counter: UInt64,
        plaintext: Data,
        key: SymmetricKey,
        baseNonce: Data
    ) throws -> Data {
        let header = encodeHeader(type: type, counter: counter)
        let nonceData = nonce(baseNonce: baseNonce, counter: counter)
        let box = try ChaChaPoly.seal(
            plaintext,
            using: key,
            nonce: try ChaChaPoly.Nonce(data: nonceData),
            authenticating: header
        )
        var packet = header
        packet.append(box.ciphertext)
        packet.append(box.tag)
        return packet
    }

    /// Parse the clear header of an on-wire packet without decrypting.
    static func parse(_ packet: Data) throws -> SealedPacket {
        guard packet.count >= headerLength + tagLength else { throw CodecError.shortPacket }
        let base = packet.startIndex
        let ver = packet[base]
        guard ver == version else { throw CodecError.badVersion(ver) }
        guard let type = PacketType(rawValue: packet[base + 1]) else {
            throw CodecError.unknownType(packet[base + 1])
        }
        var counter: UInt64 = 0
        for i in 0..<8 {
            counter = (counter << 8) | UInt64(packet[base + 2 + i])
        }
        let body = packet[(base + headerLength)...]
        return SealedPacket(type: type, counter: counter, ciphertextAndTag: Data(body))
    }

    /// Open a sealed packet, authenticating the clear header as AAD. Throws
    /// `openFailed` on any tampering (header, ciphertext, or tag).
    static func open(
        _ packet: Data,
        key: SymmetricKey,
        baseNonce: Data
    ) throws -> (type: PacketType, counter: UInt64, plaintext: Data) {
        let sealed = try parse(packet)
        let header = encodeHeader(type: sealed.type, counter: sealed.counter)
        let nonceData = nonce(baseNonce: baseNonce, counter: sealed.counter)

        let cipher = sealed.ciphertextAndTag
        guard cipher.count >= tagLength else { throw CodecError.shortPacket }
        let split = cipher.index(cipher.endIndex, offsetBy: -tagLength)
        let ciphertext = cipher[cipher.startIndex..<split]
        let tag = cipher[split...]

        do {
            let box = try ChaChaPoly.SealedBox(
                nonce: try ChaChaPoly.Nonce(data: nonceData),
                ciphertext: ciphertext,
                tag: tag
            )
            let plaintext = try ChaChaPoly.open(box, using: key, authenticating: header)
            return (sealed.type, sealed.counter, plaintext)
        } catch {
            throw CodecError.openFailed
        }
    }
}
