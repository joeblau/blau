import Foundation
import MultipeerConnectivity

@MainActor
@Observable
final class PeerSyncService: NSObject, @unchecked Sendable {
    enum Role { case advertiser, browser }

    private(set) var isConnected = false

    var onReceive: ((SyncMessage) -> Void)?

    private let role: Role
    private nonisolated(unsafe) let peerID: MCPeerID
    private nonisolated(unsafe) let session: MCSession
    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?

    private static let serviceType = "blau-sync"

    init(role: Role, displayName: String) {
        self.role = role
        self.peerID = MCPeerID(displayName: displayName)
        self.session = MCSession(peer: peerID, securityIdentity: nil, encryptionPreference: .required)
        super.init()
        session.delegate = self
    }

    func start() {
        stop()
        switch role {
        case .advertiser:
            let adv = MCNearbyServiceAdvertiser(peer: peerID, discoveryInfo: nil, serviceType: Self.serviceType)
            adv.delegate = self
            adv.startAdvertisingPeer()
            advertiser = adv

        case .browser:
            let br = MCNearbyServiceBrowser(peer: peerID, serviceType: Self.serviceType)
            br.delegate = self
            br.startBrowsingForPeers()
            browser = br
        }
    }

    func stop() {
        advertiser?.stopAdvertisingPeer()
        advertiser = nil
        browser?.stopBrowsingForPeers()
        browser = nil
        session.disconnect()
        isConnected = false
    }

    func send(_ message: SyncMessage, reliable: Bool = true) {
        guard !session.connectedPeers.isEmpty else { return }
        guard let data = try? JSONEncoder().encode(message) else { return }
        try? session.send(data, toPeers: session.connectedPeers, with: reliable ? .reliable : .unreliable)
    }

    private func restartBrowsingAfterDelay() {
        guard role == .browser else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self else { return }
            let br = MCNearbyServiceBrowser(peer: self.peerID, serviceType: Self.serviceType)
            br.delegate = self
            br.startBrowsingForPeers()
            self.browser = br
        }
    }
}

// MARK: - MCSessionDelegate

extension PeerSyncService: MCSessionDelegate {
    nonisolated func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        let connected = !session.connectedPeers.isEmpty
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.isConnected = connected
            if state == .notConnected {
                self.restartBrowsingAfterDelay()
            }
        }
    }

    nonisolated func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        guard let message = try? JSONDecoder().decode(SyncMessage.self, from: data) else { return }
        Task { @MainActor [weak self] in
            self?.onReceive?(message)
        }
    }

    nonisolated func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    nonisolated func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
    nonisolated func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}

// MARK: - MCNearbyServiceAdvertiserDelegate

extension PeerSyncService: MCNearbyServiceAdvertiserDelegate {
    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID, withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        let sess = self.session
        invitationHandler(true, sess)
    }
}

// MARK: - MCNearbyServiceBrowserDelegate

extension PeerSyncService: MCNearbyServiceBrowserDelegate {
    nonisolated func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        let sess = self.session
        browser.invitePeer(peerID, to: sess, withContext: nil, timeout: 10)
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {}
}
