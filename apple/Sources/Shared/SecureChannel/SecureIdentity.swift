import SwiftUI

/// Owns this device's long-term identity key and auto-exchanges public keys
/// with the paired device over the encrypted Multipeer sync channel — the user
/// never types or pastes anything (issue #51).
///
/// Each app creates one (`role: .copilot` / `.pilot`), wires `send` to its
/// `PeerSyncService.send`, calls `announce()` whenever the channel connects,
/// and feeds incoming `.deviceKey` messages to `receive(_:)`. The settings UI
/// reads `localPublicKey` / `peerPublicKey` from the environment and offers a
/// single "Regenerate & re-sync" action.
@MainActor
@Observable
final class SecureIdentity {
    let role: ConnectedDeviceAppRole

    /// This device's public key (base64). Generated automatically on first use.
    private(set) var localPublicKey: String?
    /// The paired peer's public key (base64) once it has synced over the channel.
    private(set) var peerPublicKey: String?

    /// Wired by the app to `PeerSyncService.send`.
    var send: ((SyncMessage) -> Void)?

    var isSynced: Bool { peerPublicKey != nil }

    init(role: ConnectedDeviceAppRole) {
        self.role = role
        guard !ProcessInfo.processInfo.environment.keys.contains("XCTestConfigurationFilePath") else {
            // Hosted test apps must not touch the developer's Keychain. Besides
            // mutating real trust state, a locked Keychain can block test launch
            // before XCTest has a chance to execute the bundle.
            self.localPublicKey = nil
            self.peerPublicKey = nil
            return
        }
        // Auto-generate (or load) our key, and recall any previously synced peer.
        self.localPublicKey = DeviceIdentity.publicKeyBase64()
        self.peerPublicKey = DeviceIdentity.peerPublicKeyBase64()
    }

    /// Broadcast our public key to the connected peer. Safe to call repeatedly
    /// (e.g. on every reconnect).
    func announce() {
        guard let localPublicKey else { return }
        send?(.deviceKey(DeviceKeyAnnounce(role: role, publicKey: localPublicKey)))
    }

    /// Handle a peer's key announcement: trust + persist it, and — if this is a
    /// newly-learned key — reciprocate so the sender also has ours. The
    /// "changed" guard makes the exchange converge instead of ping-ponging.
    func receive(_ announce: DeviceKeyAnnounce) {
        guard announce.role != role else { return }
        let changed = announce.publicKey != peerPublicKey
        peerPublicKey = announce.publicKey
        DeviceIdentity.storePeerPublicKey(announce.publicKey)
        if changed { self.announce() }
    }

    /// Generate a fresh identity key and push it to the peer.
    func regenerate() {
        try? DeviceIdentity.regenerate()
        localPublicKey = DeviceIdentity.publicKeyBase64()
        announce()
    }
}
