import Foundation
@preconcurrency import MultipeerConnectivity

@Observable
final class PeerSyncService: NSObject, @unchecked Sendable {
    enum Role { case advertiser, browser }

    private(set) var isConnected = false

    var onReceive: (@MainActor (SyncMessage) -> Void)?

    private let role: Role
    private let peerID: MCPeerID
    private let session: MCSession
    private let transportQueue = DispatchQueue(
        label: "app.blau.peersync.transport",
        qos: .userInitiated
    )
    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?
    private var reconnectWork: DispatchWorkItem?

    private static let serviceType = "blau-sync"

    init(role: Role, displayName: String) {
        self.role = role
        self.peerID = MCPeerID(displayName: displayName)
        self.session = MCSession(peer: peerID, securityIdentity: nil, encryptionPreference: .required)
        super.init()
        session.delegate = self
    }

    func start() {
        transportQueue.async { [weak self] in
            self?.startTransport()
        }
    }

    func stop() {
        transportQueue.async { [weak self] in
            self?.stopTransport()
        }
    }

    func send(_ message: SyncMessage, reliable: Bool = true) {
        guard let data = try? JSONEncoder().encode(message) else { return }
        transportQueue.async { [weak self] in
            self?.send(data, mode: reliable ? .reliable : .unreliable)
        }
    }

    private func startTransport() {
        stopTransport()
        switch role {
        case .advertiser:
            let adv = MCNearbyServiceAdvertiser(
                peer: peerID,
                discoveryInfo: nil,
                serviceType: Self.serviceType
            )
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

    private func stopTransport() {
        reconnectWork?.cancel()
        reconnectWork = nil
        advertiser?.stopAdvertisingPeer()
        advertiser = nil
        browser?.stopBrowsingForPeers()
        browser = nil
        session.disconnect()
        Task { @MainActor [weak self] in
            self?.isConnected = false
        }
    }

    /// Debounced reconnection — cancels any pending restart before scheduling a new one.
    /// Both roles restart their respective transport so either side can recover.
    private func scheduleReconnect() {
        reconnectWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.reconnectWork = nil
            // Don't reconnect if we already have peers
            guard self.session.connectedPeers.isEmpty else { return }
            switch self.role {
            case .advertiser:
                self.advertiser?.stopAdvertisingPeer()
                let adv = MCNearbyServiceAdvertiser(
                    peer: self.peerID,
                    discoveryInfo: nil,
                    serviceType: Self.serviceType
                )
                adv.delegate = self
                adv.startAdvertisingPeer()
                self.advertiser = adv
            case .browser:
                self.browser?.stopBrowsingForPeers()
                let br = MCNearbyServiceBrowser(peer: self.peerID, serviceType: Self.serviceType)
                br.delegate = self
                br.startBrowsingForPeers()
                self.browser = br
            }
        }
        reconnectWork = work
        transportQueue.asyncAfter(deadline: .now() + 2, execute: work)
    }

    private func send(_ data: Data, mode: MCSessionSendDataMode) {
        guard !session.connectedPeers.isEmpty else { return }
        try? session.send(data, toPeers: session.connectedPeers, with: mode)
    }
}

// MARK: - MCSessionDelegate

extension PeerSyncService: MCSessionDelegate {
    nonisolated func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        let connected = !session.connectedPeers.isEmpty
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.isConnected = connected
        }
        if state == .notConnected {
            transportQueue.async { [weak self] in
                self?.scheduleReconnect()
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
        transportQueue.async { [weak self] in
            guard let self else { return }
            browser.invitePeer(peerID, to: self.session, withContext: nil, timeout: 10)
        }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {}
}
