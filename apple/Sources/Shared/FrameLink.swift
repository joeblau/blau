import CryptoKit
import Foundation
import Network
import os

/// Shared logger for the mirroring frame channel. Visible in Console.app by
/// filtering on subsystem `app.blau.framelink`.
let frameLinkLog = Logger(subsystem: "app.blau.framelink", category: "FrameLink")

/// High-bandwidth, one-way media channel used to live-mirror the Pilot (macOS)
/// window to the Plotter (iPad) app.
///
/// Wire protocol: each packet is a 4-byte big-endian `UInt32` length prefix
/// followed by a typed media payload. The channel only carries opaque `Data`,
/// so this file compiles cleanly on both macOS and iOS.
public enum FrameLink {
    /// Bonjour service type for the reliable TCP control channel: carries
    /// configuration (VPS/SPS/PPS), keyframe access units, control packets
    /// (keyframe requests, link feedback, capability handshake) and the
    /// annotation channel.
    public static let serviceType = "_blau-frames._tcp"

    /// Size, in bytes, of the big-endian length prefix that precedes each
    /// TCP packet.
    static let headerSize = 4
    static let maxTCPPayloadBytes = FrameProtocol.maxSampleBytes + 6
    static let maxControlPayloadBytes = FrameProtocol.maxAnnotationBytes + 5
    static let maxSecureRecordBytes = maxTCPPayloadBytes + FrameLinkSecureSession.encryptedOverhead

    /// The packets carried by the link. ``FrameProtocol`` owns the actual
    /// value types and wire format; ``FrameLink.Packet`` is a thin alias so the
    /// platform layers keep a single import surface.
    public typealias Packet = FrameProtocol.Packet
    public typealias VideoConfiguration = FrameProtocol.VideoConfiguration
    public typealias VideoSample = FrameProtocol.VideoSample
    public typealias VideoChroma = FrameProtocol.VideoChroma
    public typealias LinkFeedback = FrameProtocol.LinkFeedback
    public typealias Capability = FrameProtocol.Capability

    /// Encodes the typed plaintext that is then sealed by the per-connection
    /// secure session. Plain media/control bytes are never written directly.
    static func encode(_ packet: Packet) -> Data {
        FrameProtocol.encode(packet)
    }

    /// Applies the outer TCP length prefix to a handshake or AEAD record.
    static func frame(_ record: Data) -> Data {
        guard !record.isEmpty,
              record.count <= maxSecureRecordBytes,
              let recordLength = UInt32(exactly: record.count) else { return Data() }
        var length = recordLength.bigEndian
        var framed = Data(bytes: &length, count: headerSize)
        framed.append(record)
        return framed
    }

    /// Decodes a TCP packet payload (without the length prefix).
    static func decodePayload(_ payload: Data) -> Packet? {
        FrameProtocol.decode(payload)
    }

    /// Network parameters for the reliable control channel. Peer-to-peer
    /// (AWDL) is enabled to get a high-bandwidth direct link when available.
    static func tcpParameters() -> NWParameters {
        // Disable Nagle's algorithm: it coalesces small writes and, combined with
        // delayed ACKs, adds tens of milliseconds of latency to a per-frame video
        // stream. We want each encoded frame on the wire immediately.
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.noDelay = true
        let parameters = NWParameters(tls: nil, tcp: tcpOptions)
        parameters.includePeerToPeer = true
        return parameters
    }

    /// Incremental, overflow-safe decoder for the TCP length prefix. A bad
    /// prefix poisons the connection immediately; callers must disconnect
    /// rather than wait for an attacker-selected allocation size.
    struct StreamDecoder {
        enum Violation: Error, Equatable {
            case bufferLimit
            case invalidLength
        }

        private(set) var buffer = Data()
        let maxPayloadBytes: Int
        let maxBufferedBytes: Int

        init(maxPayloadBytes: Int, receiveSlack: Int = 1 << 16) {
            self.maxPayloadBytes = max(1, maxPayloadBytes)
            let (sum, overflow) = self.maxPayloadBytes.addingReportingOverflow(receiveSlack)
            self.maxBufferedBytes = overflow ? self.maxPayloadBytes : sum
        }

        mutating func append(_ incoming: Data) -> Result<[Data], Violation> {
            let (newCount, overflow) = buffer.count.addingReportingOverflow(incoming.count)
            guard !overflow, newCount <= maxBufferedBytes else {
                buffer.removeAll(keepingCapacity: false)
                return .failure(.bufferLimit)
            }
            buffer.append(incoming)

            var packets: [Data] = []
            while buffer.count >= FrameLink.headerSize {
                let rawLength = buffer.prefix(FrameLink.headerSize).reduce(UInt32(0)) {
                    ($0 << 8) | UInt32($1)
                }
                guard rawLength > 0,
                      let length = Int(exactly: rawLength),
                      length <= maxPayloadBytes else {
                    buffer.removeAll(keepingCapacity: false)
                    return .failure(.invalidLength)
                }
                let (total, totalOverflow) = FrameLink.headerSize.addingReportingOverflow(length)
                guard !totalOverflow else {
                    buffer.removeAll(keepingCapacity: false)
                    return .failure(.invalidLength)
                }
                guard buffer.count >= total else { break }
                packets.append(buffer.subdata(in: FrameLink.headerSize ..< total))
                buffer.removeSubrange(0 ..< total)
            }
            return .success(packets)
        }

        mutating func reset() {
            buffer.removeAll(keepingCapacity: true)
        }
    }
}

// MARK: - Sender (macOS / Pilot)

/// Advertises an `NWListener` over Bonjour and writes length-prefixed media
/// packets to every connected client. Robust to clients connecting and
/// disconnecting at any time; the listener keeps running and restarts itself if
/// it ever fails.
public final class FrameSender: @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.blau.framelink.sender")
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: ConnectionState] = [:]
    private var running = false
    private var framesSent = 0
    private var invalidPacketCount = 0
    private let localKey: Curve25519.KeyAgreement.PrivateKey
    private let pairingStore = FrameLinkPairingStore()
    private var trustedPeerPublicKey: String?
    private var pendingPairing: (id: ObjectIdentifier, request: FrameLinkPairingRequest)?

    /// Diagnostics, invoked on `queue`. Lets the UI surface whether the
    /// listener is up, how many clients are connected, and how many frames
    /// have been pushed to the wire.
    public var onListenerReady: (() -> Void)?
    public var onClientCountChanged: ((Int) -> Void)?
    public var onFrameSent: ((Int) -> Void)?
    public var onInvalidPacketCountChanged: ((Int) -> Void)?
    var onPairingRequestChanged: ((FrameLinkPairingRequest?) -> Void)?
    /// Invoked for every annotation update received from a client, carrying
    /// the update's sequence number so the handler can acknowledge it via
    /// ``sendAnnotationAck(_:)`` once accepted.
    public var onAnnotationMessage: ((UInt32, AnnotationMessage) -> Void)?
    /// Invoked (on `queue`) when a new client finishes connecting on the TCP
    /// control channel. The encoder should force a keyframe so the freshly
    /// connected receiver can start decoding immediately.
    public var onClientConnected: (() -> Void)?
    /// Invoked when a client requests a keyframe (e.g. after detecting loss).
    public var onKeyframeRequested: (() -> Void)?
    /// Invoked when a client reports link quality, to drive adaptive bitrate.
    public var onLinkFeedback: ((FrameLink.LinkFeedback) -> Void)?
    /// Invoked when a client advertises its decode capabilities (handshake).
    public var onCapability: ((FrameLink.Capability) -> Void)?

    public init() {
        let isTesting = ProcessInfo.processInfo.environment.keys.contains("XCTestConfigurationFilePath")
        localKey = isTesting
            ? Curve25519.KeyAgreement.PrivateKey()
            : ((try? DeviceIdentity.loadOrCreate()) ?? Curve25519.KeyAgreement.PrivateKey())
        trustedPeerPublicKey = isTesting ? nil : pairingStore.loadPeerPublicKey()
    }

    deinit { stop() }

    public func start() {
        queue.async { [weak self] in
            self?.running = true
            self?.startListenerLocked()
        }
    }

    public func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.running = false
            self.listener?.cancel()
            self.listener = nil
            for state in self.connections.values {
                state.connection.cancel()
            }
            self.connections.removeAll()
            self.pendingPairing = nil
            self.onPairingRequestChanged?(nil)
        }
    }

    public func resolvePairingRequest(approved: Bool) {
        queue.async { [weak self] in
            self?.resolvePairingRequestLocked(approved: approved)
        }
    }

    public func revokePairing() {
        queue.async { [weak self] in
            guard let self else { return }
            self.trustedPeerPublicKey = nil
            try? self.pairingStore.revoke()
            for state in self.connections.values {
                state.security.revokePeer()
                state.connection.cancel()
            }
            self.connections.removeAll()
            self.onClientCountChanged?(0)
        }
    }

    /// Sends one media packet to every connected client over the reliable TCP
    /// channel. TCP is the only supported production media transport.
    public func send(_ mediaPacket: FrameLink.Packet) {
        sendOverTCP(mediaPacket)
    }

    /// Compatibility path for the original JPEG mirror.
    public func send(_ jpeg: Data) {
        send(.jpeg(jpeg))
    }

    /// Acknowledges an accepted annotation update to every connected client.
    /// Kept off the `send(_:)` path so it doesn't inflate the frame counter.
    public func sendAnnotationAck(_ seq: UInt32) {
        let packet = FrameLink.encode(.annotationAck(seq: seq))
        queue.async { [weak self] in
            guard let self else { return }
            self.broadcastTCP(packet)
        }
    }

    /// Sends an annotation command/update from Pilot to every connected client
    /// (e.g. undo/clear). Off the frame-counter path. The seq is unused by the
    /// client (no ack expected for sender-originated commands).
    public func sendAnnotation(_ message: AnnotationMessage) {
        let packet = FrameLink.encode(.annotation(seq: 0, message: message))
        queue.async { [weak self] in
            guard let self else { return }
            self.broadcastTCP(packet)
        }
    }

    // MARK: Private (always called on `queue`)

    private func sendOverTCP(_ mediaPacket: FrameLink.Packet) {
        let packet = FrameLink.encode(mediaPacket)
        queue.async { [weak self] in
            guard let self else { return }
            let delivered = self.broadcastTCP(packet)
            if delivered {
                self.countFrameSent()
            }
        }
    }

    @discardableResult
    private func broadcastTCP(_ packet: Data) -> Bool {
        guard !packet.isEmpty else { return false }
        var delivered = false
        for state in connections.values
            where state.connection.state == .ready && state.security.isAuthenticated {
            guard let record = state.security.seal(packet) else { continue }
            state.connection.send(
                content: FrameLink.frame(record),
                completion: .contentProcessed { _ in }
            )
            delivered = true
        }
        return delivered
    }

    private func countFrameSent() {
        framesSent += 1
        if framesSent == 1 {
            frameLinkLog.log("FrameSender: first frame sent to a client")
        }
        onFrameSent?(framesSent)
    }

    private func startListenerLocked() {
        guard running, listener == nil else { return }

        let listener: NWListener
        do {
            listener = try NWListener(using: FrameLink.tcpParameters())
        } catch {
            // Retry shortly; the port may be momentarily unavailable.
            scheduleListenerRestart()
            return
        }

        listener.service = NWListener.Service(type: FrameLink.serviceType)

        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                frameLinkLog.log("FrameSender: listener ready, advertising \(FrameLink.serviceType, privacy: .public)")
                self.onListenerReady?()
            case .failed(let error):
                frameLinkLog.error("FrameSender: listener failed: \(error.localizedDescription, privacy: .public)")
                self.listener = nil
                self.scheduleListenerRestart()
            case .cancelled:
                self.listener = nil
                self.scheduleListenerRestart()
            default:
                break
            }
        }

        listener.newConnectionHandler = { [weak self] connection in
            self?.adopt(connection)
        }

        self.listener = listener
        listener.start(queue: queue)
    }

    private func scheduleListenerRestart() {
        guard running else { return }
        queue.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.startListenerLocked()
        }
    }

    private func adopt(_ connection: NWConnection) {
        guard connections.isEmpty else {
            // FrameLink is intentionally one-to-one: surplus clients never see
            // a handshake, let alone a mirrored frame.
            connection.cancel()
            return
        }
        let id = ObjectIdentifier(connection)
        connections[id] = ConnectionState(
            connection: connection,
            security: FrameLinkSecureSession(
                localKey: localKey,
                trustedPeerPublicKey: trustedPeerPublicKey
            )
        )
        frameLinkLog.log("FrameSender: candidate connection accepted for authentication")

        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                guard let connectionState = self.connections[id],
                      let hello = connectionState.security.begin() else {
                    connection.cancel()
                    return
                }
                self.sendRecord(hello, using: connectionState)
                self.receiveNext(from: id)
            case .failed, .cancelled:
                let wasAuthenticated = self.connections[id]?.security.isAuthenticated == true
                self.connections.removeValue(forKey: id)
                if self.pendingPairing?.id == id {
                    self.pendingPairing = nil
                    self.onPairingRequestChanged?(nil)
                }
                if wasAuthenticated { self.onClientCountChanged?(0) }
            default:
                break
            }
        }

        connection.start(queue: queue)
    }

    private func receiveNext(from id: ObjectIdentifier) {
        guard let state = connections[id] else { return }
        state.connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) {
            [weak self] data, _, isComplete, error in
            guard let self,
                  let state = self.connections[id] else { return }

            if let data, !data.isEmpty {
                switch state.decoder.append(data) {
                case .success(let payloads):
                    self.processSecureRecords(payloads, from: id, state: state)
                case .failure:
                    self.rejectConnection(id, state: state)
                    return
                }
            }

            if error != nil || isComplete {
                let wasAuthenticated = state.security.isAuthenticated
                self.connections.removeValue(forKey: id)
                state.connection.cancel()
                if wasAuthenticated { self.onClientCountChanged?(0) }
                return
            }

            self.receiveNext(from: id)
        }
    }

    private func processSecureRecords(
        _ records: [Data],
        from id: ObjectIdentifier,
        state: ConnectionState
    ) {
        for record in records {
            guard let opened = state.security.receive(record, displayName: "Plotter") else {
                rejectConnection(id, state: state)
                return
            }
            switch opened {
            case .send(let response):
                sendRecord(response, using: state)

            case .pairingRequired(let request):
                guard pendingPairing == nil else {
                    rejectConnection(id, state: state)
                    return
                }
                pendingPairing = (id, request)
                onPairingRequestChanged?(request)

            case .waiting:
                break

            case .authenticated:
                didAuthenticateClient()

            case .plaintext(let payload):
                processInboundPacket(payload)
            }
        }
    }

    private func processInboundPacket(_ payload: Data) {
        switch FrameLink.decodePayload(payload) {
            case .annotation(let seq, let message):
                frameLinkLog.log("FrameSender: annotation packet received (seq \(seq, privacy: .public))")
                onAnnotationMessage?(seq, message)
            case .keyframeRequest:
                onKeyframeRequested?()
            case .linkFeedback(let feedback):
                onLinkFeedback?(feedback)
            case .capability(let capability):
                onCapability?(capability)
            default:
                recordInvalidPacket()
        }
    }

    private func sendRecord(_ record: Data, using state: ConnectionState) {
        let framed = FrameLink.frame(record)
        guard !framed.isEmpty else { return }
        state.connection.send(content: framed, completion: .contentProcessed { _ in })
    }

    private func resolvePairingRequestLocked(approved: Bool) {
        guard let pending = pendingPairing,
              let state = connections[pending.id] else { return }
        pendingPairing = nil
        onPairingRequestChanged?(nil)
        guard approved,
              let approval = state.security.approvePending(publicKey: pending.request.publicKey) else {
            state.security.rejectPending()
            rejectConnection(pending.id, state: state)
            return
        }
        trustedPeerPublicKey = pending.request.publicKey
        if !ProcessInfo.processInfo.environment.keys.contains("XCTestConfigurationFilePath") {
            try? pairingStore.setPeerPublicKey(pending.request.publicKey)
        }
        sendRecord(approval.proof, using: state)
        if approval.authenticated { didAuthenticateClient() }
    }

    private func didAuthenticateClient() {
        frameLinkLog.log("FrameSender: Plotter identity authenticated")
        onClientCountChanged?(1)
        // A freshly authenticated client needs a keyframe to decode.
        onClientConnected?()
    }

    private func rejectConnection(_ id: ObjectIdentifier, state: ConnectionState) {
        let wasAuthenticated = state.security.isAuthenticated
        connections.removeValue(forKey: id)
        state.connection.cancel()
        if pendingPairing?.id == id {
            pendingPairing = nil
            onPairingRequestChanged?(nil)
        }
        if wasAuthenticated { onClientCountChanged?(0) }
        recordInvalidPacket()
    }

    private func recordInvalidPacket() {
        invalidPacketCount += 1
        onInvalidPacketCountChanged?(invalidPacketCount)
    }

    private final class ConnectionState {
        let connection: NWConnection
        var decoder = FrameLink.StreamDecoder(maxPayloadBytes: FrameLink.maxSecureRecordBytes)
        var security: FrameLinkSecureSession

        init(connection: NWConnection, security: FrameLinkSecureSession) {
            self.connection = connection
            self.security = security
        }
    }
}

// MARK: - Receiver (iOS / Plotter)

/// Browses for a ``FrameLink`` Bonjour service, connects to the first result,
/// and reassembles the length-prefixed media stream. Recovers automatically
/// from disconnects by restarting the browser.
public final class FrameReceiver: @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.blau.framelink.receiver")
    private var browser: NWBrowser?
    private var connection: NWConnection?
    private var decoder = FrameLink.StreamDecoder(maxPayloadBytes: FrameLink.maxSecureRecordBytes)
    private var running = false
    private var framesReceived = 0
    private var pendingOutbound: [Data] = []
    private var invalidPacketCount = 0
    private let pairingStore = FrameLinkPairingStore()
    private var security: FrameLinkSecureSession
    private var pairingRequest: FrameLinkPairingRequest?

    /// True while a keyframe request is outstanding (single-outstanding
    /// recovery): suppresses a storm of requests until the next keyframe.
    private var keyframeRequestOutstanding = false
    /// Floor between keyframe requests even if the prior one was satisfied,
    /// so transient loss doesn't hammer the encoder.
    private var lastKeyframeRequest: TimeInterval = 0
    private let keyframeRequestThrottle: TimeInterval = 0.5

    /// Called on an internal queue for every complete JPEG frame received.
    public var onFrame: ((Data) -> Void)?
    /// Called on an internal queue for every decoded media packet received.
    /// All production packets arrive over the authenticated TCP stream.
    public var onPacket: ((FrameLink.Packet) -> Void)?
    public var onStatusChanged: ((String) -> Void)?
    public var onFrameCountChanged: ((Int) -> Void)?
    public var onInvalidPacketCountChanged: ((Int) -> Void)?
    var onPairingRequestChanged: ((FrameLinkPairingRequest?) -> Void)?
    /// Fired with `true` when the frame connection becomes ready and `false`
    /// when it tears down, so the UI can match Pilot's appearance only while
    /// actually connected.
    public var onConnectedChanged: ((Bool) -> Void)?

    public init() {
        let isTesting = ProcessInfo.processInfo.environment.keys.contains("XCTestConfigurationFilePath")
        let key = isTesting
            ? Curve25519.KeyAgreement.PrivateKey()
            : ((try? DeviceIdentity.loadOrCreate()) ?? Curve25519.KeyAgreement.PrivateKey())
        security = FrameLinkSecureSession(
            localKey: key,
            trustedPeerPublicKey: isTesting ? nil : pairingStore.loadPeerPublicKey()
        )
    }

    deinit { stop() }

    public func start() {
        queue.async { [weak self] in
            self?.running = true
            self?.startBrowserLocked()
        }
    }

    public func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.running = false
            self.browser?.cancel()
            self.browser = nil
            self.connection?.cancel()
            self.connection = nil
            self.decoder.reset()
            self.pendingOutbound.removeAll()
            self.security.resetSession()
            self.pairingRequest = nil
            self.onPairingRequestChanged?(nil)
        }
    }

    public func resolvePairingRequest(approved: Bool) {
        queue.async { [weak self] in
            self?.resolvePairingRequestLocked(approved: approved)
        }
    }

    public func revokePairing() {
        queue.async { [weak self] in
            guard let self else { return }
            try? self.pairingStore.revoke()
            self.security.revokePeer()
            self.teardownConnection()
        }
    }

    public func sendAnnotation(_ message: AnnotationMessage, seq: UInt32) {
        enqueueOutbound(FrameLink.encode(.annotation(seq: seq, message: message)))
    }

    /// Reports current link quality back to the sender over TCP, driving the
    /// sender's adaptive bitrate controller.
    public func sendLinkFeedback(lossPct: Double, rttMs: Double, queueDepth: Int) {
        enqueueOutbound(FrameLink.encode(.linkFeedback(
            FrameProtocol.LinkFeedback(lossPct: lossPct, rttMs: rttMs, queueDepth: queueDepth)
        )))
    }

    /// Advertises this receiver's decode capabilities to the sender (handshake).
    public func sendCapability(supports444: Bool) {
        enqueueOutbound(FrameLink.encode(.capability(
            FrameProtocol.Capability(supports444: supports444)
        )))
    }

    /// Asks the sender for a fresh keyframe over TCP, with single-outstanding
    /// + time-throttled semantics so a burst of loss yields at most one
    /// in-flight request.
    public func requestKeyframe() {
        queue.async { [weak self] in
            self?.requestKeyframeLocked()
        }
    }

    // MARK: Private (always called on `queue`)

    private func requestKeyframeLocked() {
        let now = Date().timeIntervalSinceReferenceDate
        guard !keyframeRequestOutstanding,
              now - lastKeyframeRequest >= keyframeRequestThrottle else { return }
        keyframeRequestOutstanding = true
        lastKeyframeRequest = now
        let packet = FrameLink.encode(.keyframeRequest)
        enqueueOutboundLocked(packet)
    }

    private func enqueueOutbound(_ packet: Data) {
        queue.async { [weak self] in
            self?.enqueueOutboundLocked(packet)
        }
    }

    private func enqueueOutboundLocked(_ packet: Data) {
        guard !packet.isEmpty,
              connection?.state == .ready,
              let record = security.seal(packet) else {
            pendingOutbound.append(packet)
            if pendingOutbound.count > 16 {
                pendingOutbound.removeFirst(pendingOutbound.count - 16)
            }
            return
        }
        connection?.send(
            content: FrameLink.frame(record),
            completion: .contentProcessed { _ in }
        )
    }

    private func startBrowserLocked() {
        guard running, browser == nil else { return }

        let browser = NWBrowser(
            for: .bonjour(type: FrameLink.serviceType, domain: nil),
            using: FrameLink.tcpParameters()
        )

        browser.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.updateStatus("Browsing for Pilot frame stream")
            case .failed, .cancelled:
                self.updateStatus("Frame browser stopped")
                self.browser = nil
                self.scheduleBrowserRestart()
            case .waiting(let error):
                self.updateStatus("Frame browser waiting: \(error.localizedDescription)")
            default:
                break
            }
        }

        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            if results.isEmpty {
                self.updateStatus("No Pilot frame stream found")
                return
            }
            // Only connect to the first result if we don't already have a link.
            guard self.connection == nil, let first = results.first else { return }
            self.updateStatus("Found Pilot frame stream")
            self.connect(to: first.endpoint)
        }

        self.browser = browser
        browser.start(queue: queue)
    }

    private func scheduleBrowserRestart() {
        guard running else { return }
        queue.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.startBrowserLocked()
        }
    }

    private func connect(to endpoint: NWEndpoint) {
        let connection = NWConnection(to: endpoint, using: FrameLink.tcpParameters())
        updateStatus("Connecting to Pilot frame stream")
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                guard let hello = self.security.begin() else {
                    self.teardownConnection()
                    return
                }
                self.updateStatus("Authenticating Pilot frame stream")
                self.sendRecord(hello)
                self.receiveNext()
            case .failed, .cancelled:
                self.updateStatus("Frame stream disconnected")
                self.teardownConnection()
            case .waiting(let error):
                self.updateStatus("Frame stream waiting: \(error.localizedDescription)")
            default:
                break
            }
        }

        self.connection = connection
        decoder.reset()
        connection.start(queue: queue)
    }

    private func teardownConnection() {
        connection?.cancel()
        connection = nil
        decoder.reset()
        security.resetSession()
        pairingRequest = nil
        onPairingRequestChanged?(nil)
        onConnectedChanged?(false)
        // Browser may still be alive; if not, restart browsing to find a peer.
        if running, browser == nil {
            scheduleBrowserRestart()
        }
    }

    private func receiveNext() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }

            if let data, !data.isEmpty {
                switch self.decoder.append(data) {
                case .success(let records):
                    self.processSecureRecords(records)
                case .failure:
                    self.recordInvalidPacket()
                    self.updateStatus("Rejected invalid frame stream")
                    self.teardownConnection()
                    return
                }
            }

            if error != nil || isComplete {
                if let error {
                    self.updateStatus("Frame receive failed: \(error.localizedDescription)")
                } else {
                    self.updateStatus("Frame stream closed")
                }
                self.teardownConnection()
                return
            }

            self.receiveNext()
        }
    }

    private func processSecureRecords(_ records: [Data]) {
        for record in records {
            guard let opened = security.receive(record, displayName: "Pilot") else {
                recordInvalidPacket()
                updateStatus("Rejected unauthenticated frame stream")
                teardownConnection()
                return
            }
            switch opened {
            case .send(let response):
                sendRecord(response)

            case .pairingRequired(let request):
                guard pairingRequest == nil else {
                    teardownConnection()
                    return
                }
                pairingRequest = request
                onPairingRequestChanged?(request)
                updateStatus("Approval required to pair Pilot")

            case .waiting:
                break

            case .authenticated:
                didAuthenticatePilot()

            case .plaintext(let payload):
                processFrames([payload])
            }
        }
    }

    private func resolvePairingRequestLocked(approved: Bool) {
        guard let request = pairingRequest else { return }
        pairingRequest = nil
        onPairingRequestChanged?(nil)
        guard approved,
              let approval = security.approvePending(publicKey: request.publicKey) else {
            security.rejectPending()
            updateStatus("Pilot pairing rejected")
            teardownConnection()
            return
        }
        if !ProcessInfo.processInfo.environment.keys.contains("XCTestConfigurationFilePath") {
            try? pairingStore.setPeerPublicKey(request.publicKey)
        }
        sendRecord(approval.proof)
        if approval.authenticated { didAuthenticatePilot() }
    }

    private func didAuthenticatePilot() {
        updateStatus("Frame stream authenticated")
        onConnectedChanged?(true)
        flushPendingOutbound()
    }

    private func sendRecord(_ record: Data) {
        let framed = FrameLink.frame(record)
        guard !framed.isEmpty else { return }
        connection?.send(content: framed, completion: .contentProcessed { _ in })
    }

    /// Delivers complete, authenticated plaintext packets.
    private func processFrames(_ payloads: [Data]) {
        for payload in payloads {
            guard let packet = FrameLink.decodePayload(payload) else {
                recordInvalidPacket()
                continue
            }

            switch packet {
            case .sample(let sample):
                if sample.isKeyFrame {
                    // A delivered keyframe clears the recovery latch.
                    keyframeRequestOutstanding = false
                }
                countReceivedFrame()
            case .configuration:
                keyframeRequestOutstanding = false
            case .jpeg(let frame):
                countReceivedFrame()
                onFrame?(frame)
            case .annotation:
                // Sender -> client annotation commands (undo/clear). Forward to
                // onPacket so the client can apply them to its source canvas.
                break
            default:
                break
            }

            onPacket?(packet)
        }
    }

    private func recordInvalidPacket() {
        invalidPacketCount += 1
        onInvalidPacketCountChanged?(invalidPacketCount)
    }

    private func countReceivedFrame() {
        framesReceived += 1
        if framesReceived == 1 {
            updateStatus("Receiving Pilot frames")
        }
        onFrameCountChanged?(framesReceived)
    }

    private func flushPendingOutbound() {
        guard connection?.state == .ready, security.isAuthenticated else { return }
        let packets = pendingOutbound
        pendingOutbound.removeAll()
        for packet in packets {
            guard let record = security.seal(packet) else { continue }
            connection?.send(
                content: FrameLink.frame(record),
                completion: .contentProcessed { _ in }
            )
        }
    }

    private func updateStatus(_ status: String) {
        frameLinkLog.log("FrameReceiver: \(status, privacy: .public)")
        onStatusChanged?(status)
    }
}
