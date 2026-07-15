import CryptoKit
import Foundation
import XCTest

@testable import Copilot

final class PeerSyncAuthenticationTests: XCTestCase {
    func testUnknownAndChangedAdvertisersRequireExplicitApproval() {
        let trusted = Curve25519.KeyAgreement.PrivateKey()
            .publicKey.rawRepresentation.base64EncodedString()
        let candidate = Curve25519.KeyAgreement.PrivateKey()
            .publicKey.rawRepresentation.base64EncodedString()

        XCTAssertEqual(
            PeerSyncService.pairingDecision(candidate: candidate, trusted: nil),
            .approvalRequired(isKeyChange: false)
        )
        XCTAssertEqual(
            PeerSyncService.pairingDecision(candidate: candidate, trusted: trusted),
            .approvalRequired(isKeyChange: true)
        )
        XCTAssertEqual(
            PeerSyncService.pairingDecision(candidate: trusted, trusted: trusted),
            .trusted
        )
        XCTAssertEqual(
            PeerSyncService.pairingDecision(candidate: "not-a-key", trusted: trusted),
            .reject
        )
        XCTAssertEqual(
            PeerSyncAuthenticator.pairingCode(local: trusted, peer: candidate),
            PeerSyncAuthenticator.pairingCode(local: candidate, peer: trusted)
        )
    }

    func testMutualIdentityAuthenticationAndReplayRejection() throws {
        let keys = makeAuthenticators()
        var pilot = keys.pilot
        var copilot = keys.copilot
        try authenticate(&pilot, &copilot)

        let payload = try JSONEncoder().encode(SyncMessage.mouseClick(MouseClick(button: 0)))
        let envelope = try XCTUnwrap(copilot.sealMessage(payload))
        XCTAssertEqual(copilot.isAuthenticated, true)
        XCTAssertEqual(pilot.open(envelope), .message(payload))
        XCTAssertNil(pilot.open(envelope), "the same control command must not replay")
    }

    func testRogueIdentityCannotAuthenticateControlOrKeyAnnouncement() throws {
        let pilotKey = Curve25519.KeyAgreement.PrivateKey()
        let copilotKey = Curve25519.KeyAgreement.PrivateKey()
        let rogueKey = Curve25519.KeyAgreement.PrivateKey()
        let pilotPublic = pilotKey.publicKey.rawRepresentation.base64EncodedString()
        let copilotPublic = copilotKey.publicKey.rawRepresentation.base64EncodedString()

        var pilot = PeerSyncAuthenticator(
            localKey: pilotKey,
            peerPublicKeyBase64: copilotPublic
        )
        var rogue = PeerSyncAuthenticator(
            localKey: rogueKey,
            peerPublicKeyBase64: pilotPublic
        )
        _ = pilot.beginSession(random: { Data(repeating: 1, count: $0) })
        let rogueHello = try XCTUnwrap(rogue.beginSession(random: { Data(repeating: 9, count: $0) }))
        XCTAssertNil(pilot.open(rogueHello), "a copied service name cannot prove the pinned identity")

        let control = try JSONEncoder().encode(SyncMessage.terminalInput(.enter))
        let keyChange = try JSONEncoder().encode(SyncMessage.deviceKey(.init(
            role: .copilot,
            publicKey: rogueKey.publicKey.rawRepresentation.base64EncodedString()
        )))
        XCTAssertNil(rogue.sealMessage(control))
        XCTAssertNil(rogue.sealMessage(keyChange))
    }

    func testTamperingAndPriorSessionPacketsAreRejectedAfterReconnect() throws {
        let keys = makeAuthenticators()
        var pilot = keys.pilot
        var copilot = keys.copilot
        try authenticate(&pilot, &copilot)

        let oldEnvelope = try XCTUnwrap(copilot.sealMessage(Data("old".utf8)))
        var tampered = oldEnvelope
        tampered[tampered.index(before: tampered.endIndex)] ^= 0x01
        XCTAssertNil(pilot.open(tampered))

        try authenticate(
            &pilot,
            &copilot,
            pilotNonce: 0x31,
            copilotNonce: 0x42
        )
        XCTAssertNil(pilot.open(oldEnvelope), "a packet from a prior session must not authorize")
        let fresh = try XCTUnwrap(copilot.sealMessage(Data("fresh".utf8)))
        XCTAssertEqual(pilot.open(fresh), .message(Data("fresh".utf8)))
    }

    private func makeAuthenticators() -> (
        pilot: PeerSyncAuthenticator,
        copilot: PeerSyncAuthenticator
    ) {
        let pilotKey = Curve25519.KeyAgreement.PrivateKey()
        let copilotKey = Curve25519.KeyAgreement.PrivateKey()
        return (
            PeerSyncAuthenticator(
                localKey: pilotKey,
                peerPublicKeyBase64: copilotKey.publicKey.rawRepresentation.base64EncodedString()
            ),
            PeerSyncAuthenticator(
                localKey: copilotKey,
                peerPublicKeyBase64: pilotKey.publicKey.rawRepresentation.base64EncodedString()
            )
        )
    }

    private func authenticate(
        _ pilot: inout PeerSyncAuthenticator,
        _ copilot: inout PeerSyncAuthenticator,
        pilotNonce: UInt8 = 0x11,
        copilotNonce: UInt8 = 0x22
    ) throws {
        let pilotHello = try XCTUnwrap(pilot.beginSession(
            random: { Data(repeating: pilotNonce, count: $0) }
        ))
        let copilotHello = try XCTUnwrap(copilot.beginSession(
            random: { Data(repeating: copilotNonce, count: $0) }
        ))

        guard case .helloResponse(let readyForPilot)? = copilot.open(pilotHello),
              case .helloResponse(let readyForCopilot)? = pilot.open(copilotHello) else {
            return XCTFail("expected mutual hello responses")
        }
        XCTAssertEqual(pilot.open(readyForPilot), .authenticated)
        XCTAssertEqual(copilot.open(readyForCopilot), .authenticated)
        XCTAssertTrue(pilot.isAuthenticated)
        XCTAssertTrue(copilot.isAuthenticated)
    }
}
