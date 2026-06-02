import Foundation
import XCTest
import CryptoKit

@testable import Copilot

/// Unit tests for the pure, socket-free secure-channel value layer (issue #51):
/// the Noise IK handshake, packet AEAD codec, replay window, connection state
/// machine, and reliable-delivery bookkeeping.
final class SecureChannelTests: XCTestCase {

    // MARK: - Handshake

    /// A full IK handshake completes and BOTH sides derive identical directional
    /// transport keys and base nonces.
    func testFullHandshakeDerivesIdenticalDirectionalKeys() throws {
        let initiatorStatic = Curve25519.KeyAgreement.PrivateKey()
        let responderStatic = Curve25519.KeyAgreement.PrivateKey()

        let (initiatorState, msg1) = try NoiseIK.Initiator.start(
            staticKey: initiatorStatic,
            responderStatic: responderStatic.publicKey,
            payload: Data("hello".utf8)
        )

        let responder = try NoiseIK.Responder.receive(
            staticKey: responderStatic,
            message: msg1
        )
        // Responder recovers and authenticates the initiator's static key + payload.
        XCTAssertEqual(responder.initiatorPayload, Data("hello".utf8))
        XCTAssertEqual(
            responder.initiatorStatic.rawRepresentation,
            initiatorStatic.publicKey.rawRepresentation
        )

        let (responderKeys, msg2) = try responder.respond(payload: Data("world".utf8))
        let (initiatorKeys, responderPayload) = try initiatorState.receive(msg2)
        XCTAssertEqual(responderPayload, Data("world".utf8))

        // Both sides MUST agree on both directional keys + base nonces.
        XCTAssertEqual(initiatorKeys, responderKeys)

        // Sanity: the two directions are distinct from each other.
        XCTAssertNotEqual(
            initiatorKeys.initiatorToResponderKey,
            initiatorKeys.responderToInitiatorKey
        )
        XCTAssertNotEqual(
            initiatorKeys.initiatorToResponderBaseNonce,
            initiatorKeys.responderToInitiatorBaseNonce
        )
    }

    /// The derived keys actually work end-to-end through the packet codec in
    /// both directions.
    func testTransportRoundtripBothDirections() throws {
        let keys = try completeHandshake().initiator

        // Initiator -> Responder.
        let p1 = try PacketCodec.seal(
            type: .reliableControl, counter: 0,
            plaintext: Data("i2r".utf8),
            key: keys.initiatorToResponderKey,
            baseNonce: keys.initiatorToResponderBaseNonce
        )
        let opened1 = try PacketCodec.open(
            p1, key: keys.initiatorToResponderKey,
            baseNonce: keys.initiatorToResponderBaseNonce
        )
        XCTAssertEqual(opened1.plaintext, Data("i2r".utf8))
        XCTAssertEqual(opened1.type, .reliableControl)

        // Responder -> Initiator.
        let p2 = try PacketCodec.seal(
            type: .bestEffortBlob, counter: 0,
            plaintext: Data("r2i".utf8),
            key: keys.responderToInitiatorKey,
            baseNonce: keys.responderToInitiatorBaseNonce
        )
        let opened2 = try PacketCodec.open(
            p2, key: keys.responderToInitiatorKey,
            baseNonce: keys.responderToInitiatorBaseNonce
        )
        XCTAssertEqual(opened2.plaintext, Data("r2i".utf8))
        XCTAssertEqual(opened2.type, .bestEffortBlob)
    }

    /// A WRONG responder static key (the authentication guarantee) must make the
    /// handshake fail to open — the initiator believed it was talking to one
    /// device, but the responder holds a different static key.
    func testWrongResponderStaticKeyFailsHandshake() throws {
        let initiatorStatic = Curve25519.KeyAgreement.PrivateKey()
        let realResponder = Curve25519.KeyAgreement.PrivateKey()
        let wrongResponder = Curve25519.KeyAgreement.PrivateKey()

        // Initiator addresses the WRONG responder public key.
        let (_, msg1) = try NoiseIK.Initiator.start(
            staticKey: initiatorStatic,
            responderStatic: wrongResponder.publicKey
        )

        // The real responder (different static key) can't open msg1: DH(e,s)
        // differs, so the AEAD key differs and the open fails.
        XCTAssertThrowsError(
            try NoiseIK.Responder.receive(staticKey: realResponder, message: msg1)
        ) { error in
            XCTAssertEqual(error as? NoiseIK.HandshakeError, .decryptFailed)
        }
    }

    /// Even when msg1 is accepted, a responder whose static key the initiator
    /// did NOT pin will produce mismatched transport keys; the first transport
    /// packet then fails to open. (Belt-and-suspenders authentication.)
    func testMismatchedStaticKeyProducesUndecryptableTransport() throws {
        // Initiator pins responderA, but msg2 is produced by responderB.
        let initiatorStatic = Curve25519.KeyAgreement.PrivateKey()
        let responderA = Curve25519.KeyAgreement.PrivateKey()
        let responderB = Curve25519.KeyAgreement.PrivateKey()

        let (initiatorState, msg1) = try NoiseIK.Initiator.start(
            staticKey: initiatorStatic,
            responderStatic: responderA.publicKey
        )
        // responderB happens to also receive msg1 — but it was sealed to A, so
        // it cannot even open it.
        XCTAssertThrowsError(
            try NoiseIK.Responder.receive(staticKey: responderB, message: msg1)
        )
        // And the legitimate A completes fine (control).
        let respA = try NoiseIK.Responder.receive(staticKey: responderA, message: msg1)
        let (_, msg2) = try respA.respond()
        XCTAssertNoThrow(try initiatorState.receive(msg2))
    }

    // MARK: - Packet codec / tampering

    func testTamperedCiphertextFailsToOpen() throws {
        let keys = try completeHandshake().initiator
        var packet = try PacketCodec.seal(
            type: .reliableControl, counter: 7,
            plaintext: Data("secret".utf8),
            key: keys.initiatorToResponderKey,
            baseNonce: keys.initiatorToResponderBaseNonce
        )
        // Flip a bit in the ciphertext body.
        let flipIndex = PacketCodec.headerLength
        packet[flipIndex] ^= 0x01
        XCTAssertThrowsError(
            try PacketCodec.open(
                packet, key: keys.initiatorToResponderKey,
                baseNonce: keys.initiatorToResponderBaseNonce
            )
        ) { error in
            XCTAssertEqual(error as? PacketCodec.CodecError, .openFailed)
        }
    }

    func testTamperedHeaderFailsToOpen() throws {
        let keys = try completeHandshake().initiator
        var packet = try PacketCodec.seal(
            type: .reliableControl, counter: 3,
            plaintext: Data("secret".utf8),
            key: keys.initiatorToResponderKey,
            baseNonce: keys.initiatorToResponderBaseNonce
        )
        // Flip the type byte: header is AAD, so the tag check must fail.
        packet[1] = PacketCodec.PacketType.bestEffortBlob.rawValue
        XCTAssertThrowsError(
            try PacketCodec.open(
                packet, key: keys.initiatorToResponderKey,
                baseNonce: keys.initiatorToResponderBaseNonce
            )
        ) { error in
            XCTAssertEqual(error as? PacketCodec.CodecError, .openFailed)
        }
    }

    func testBadVersionRejected() throws {
        let keys = try completeHandshake().initiator
        var packet = try PacketCodec.seal(
            type: .ack, counter: 1, plaintext: Data(),
            key: keys.initiatorToResponderKey,
            baseNonce: keys.initiatorToResponderBaseNonce
        )
        packet[0] = 0x02
        XCTAssertThrowsError(try PacketCodec.parse(packet)) { error in
            XCTAssertEqual(error as? PacketCodec.CodecError, .badVersion(0x02))
        }
    }

    func testNonceXorIsUniquePerCounter() {
        let base = Data(repeating: 0xAB, count: 12)
        let n0 = PacketCodec.nonce(baseNonce: base, counter: 0)
        let n1 = PacketCodec.nonce(baseNonce: base, counter: 1)
        XCTAssertEqual(n0, base)            // counter 0 leaves base unchanged
        XCTAssertNotEqual(n0, n1)
        XCTAssertEqual(n1.count, 12)
        // Low byte should be base ^ 1.
        XCTAssertEqual(n1[11], base[11] ^ 0x01)
    }

    // MARK: - Replay window

    func testReplayWindowRejectsReplayedAndOldCounters() {
        var window = ReplayWindow()
        XCTAssertTrue(window.accept(0))
        XCTAssertTrue(window.accept(1))
        XCTAssertTrue(window.accept(2))

        // Replays of already-seen counters are rejected.
        XCTAssertFalse(window.accept(1))
        XCTAssertFalse(window.accept(2))

        // Out-of-order but fresh within the window is accepted...
        XCTAssertTrue(window.accept(5))
        // ...then a replay of it is rejected.
        XCTAssertFalse(window.accept(5))

        // Advance far past the window, then an ancient counter is too old.
        XCTAssertTrue(window.accept(5000))
        XCTAssertFalse(window.accept(1))     // below window bottom
        XCTAssertFalse(window.accept(5000))  // replay of current highest
    }

    func testReplayWindowAcceptsFreshWithinWindow() {
        var window = ReplayWindow(size: 1024)
        XCTAssertTrue(window.accept(1023))
        // Still within [0, 1023]: fresh, accept.
        XCTAssertTrue(window.accept(0))
        XCTAssertTrue(window.accept(512))
        // Replay rejected.
        XCTAssertFalse(window.accept(512))
    }

    // MARK: - Connection state machine

    func testStateMachineHappyPath() {
        var sm = ConnectionStateMachine()
        XCTAssertEqual(sm.state, .signaling)
        XCTAssertTrue(sm.transition(to: .holePunching))
        XCTAssertTrue(sm.transition(to: .handshake))
        XCTAssertTrue(sm.transition(to: .connected))
        XCTAssertTrue(sm.state.isConnected)
    }

    func testStateMachineRejectsIllegalTransition() {
        var sm = ConnectionStateMachine()
        // Can't skip straight to connected.
        XCTAssertFalse(sm.transition(to: .connected))
        XCTAssertEqual(sm.state, .signaling)
        // Can't skip the handshake.
        XCTAssertTrue(sm.transition(to: .holePunching))
        XCTAssertFalse(sm.transition(to: .connected))
        XCTAssertEqual(sm.state, .holePunching)
    }

    func testStateMachineCanFailFromAnyStage() {
        var sm = ConnectionStateMachine()
        sm.fail("signaling timeout")
        XCTAssertTrue(sm.state.isFailed)
        XCTAssertEqual(sm.state, .failed(reason: "signaling timeout"))
    }

    // MARK: - Reliable delivery / ACK bookkeeping

    func testReliableMessengerAckClearsInFlight() {
        var sender = ReliableMessenger()
        let m = sender.enqueue(Data("ctrl".utf8), now: 0)
        XCTAssertTrue(sender.isOutstanding(m.id))
        XCTAssertEqual(sender.outstandingCount, 1)

        XCTAssertTrue(sender.acknowledge(m.id))
        XCTAssertFalse(sender.isOutstanding(m.id))
        XCTAssertEqual(sender.outstandingCount, 0)

        // Duplicate/late ACK is a no-op.
        XCTAssertFalse(sender.acknowledge(m.id))
    }

    func testReliableMessengerRetransmitsWithBackoffUntilAcked() {
        var sender = ReliableMessenger(maxAttempts: 8, baseBackoff: 1.0, maxBackoff: 100)
        let m = sender.enqueue(Data("ctrl".utf8), now: 0)

        // First send is due immediately.
        guard case .send(let first) = sender.due(now: 0) else {
            return XCTFail("expected initial send")
        }
        XCTAssertEqual(first.map(\.id), [m.id])

        // Nothing due before the first backoff (1.0s) elapses.
        guard case .waitUntil(let t) = sender.due(now: 0.5) else {
            return XCTFail("expected waitUntil")
        }
        XCTAssertEqual(t, 1.0, accuracy: 0.0001)

        // At 1.0s a retransmit fires; next backoff doubles to 2.0s.
        guard case .send(let second) = sender.due(now: 1.0) else {
            return XCTFail("expected retransmit")
        }
        XCTAssertEqual(second.map(\.id), [m.id])
        guard case .waitUntil(let t2) = sender.due(now: 1.5) else {
            return XCTFail("expected waitUntil after retransmit")
        }
        XCTAssertEqual(t2, 3.0, accuracy: 0.0001)  // 1.0 + 2.0

        // Once ACK'd, it goes idle.
        XCTAssertTrue(sender.acknowledge(m.id))
        XCTAssertEqual(sender.due(now: 100), .idle)
    }

    func testReliableMessengerAbandonsAfterMaxAttempts() {
        var sender = ReliableMessenger(maxAttempts: 3, baseBackoff: 1.0, maxBackoff: 100)
        let m = sender.enqueue(Data("ctrl".utf8), now: 0)

        // Drive the clock forward well past every backoff window so each call
        // fires the next attempt. After maxAttempts sends, it's abandoned.
        var now: TimeInterval = 0
        for _ in 0..<10 {
            _ = sender.due(now: now)
            now += 1000
        }
        XCTAssertFalse(sender.isOutstanding(m.id))
        XCTAssertTrue(sender.abandoned.contains(m.id))
        XCTAssertEqual(sender.due(now: now), .idle)
    }

    func testAckTrackerDeliversOnceDedupesRetransmits() {
        var tracker = AckTracker()
        XCTAssertTrue(tracker.receive(42))   // first delivery
        XCTAssertFalse(tracker.receive(42))  // retransmit: ack again, don't redeliver
        XCTAssertTrue(tracker.hasDelivered(42))
        XCTAssertTrue(tracker.receive(43))
    }

    // MARK: - Helpers

    private func completeHandshake() throws -> (initiator: TransportKeys, responder: TransportKeys) {
        let initiatorStatic = Curve25519.KeyAgreement.PrivateKey()
        let responderStatic = Curve25519.KeyAgreement.PrivateKey()
        let (initiatorState, msg1) = try NoiseIK.Initiator.start(
            staticKey: initiatorStatic,
            responderStatic: responderStatic.publicKey
        )
        let responder = try NoiseIK.Responder.receive(staticKey: responderStatic, message: msg1)
        let (responderKeys, msg2) = try responder.respond()
        let (initiatorKeys, _) = try initiatorState.receive(msg2)
        return (initiatorKeys, responderKeys)
    }
}
