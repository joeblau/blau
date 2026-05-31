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

    /// Bonjour service type for the unreliable UDP media channel: carries
    /// fragmented P-frame access units. Advertised/browsed alongside the TCP
    /// service. Running a parallel bonjour service (rather than tunnelling the
    /// UDP endpoint over TCP) keeps each side's discovery/reconnect logic
    /// symmetric and lets AWDL negotiate the peer link per service.
    public static let udpServiceType = "_blau-frames-udp._udp"

    /// Size, in bytes, of the big-endian length prefix that precedes each
    /// TCP packet. UDP datagrams are self-framing and carry no prefix.
    static let headerSize = 4

    /// The packets carried by the link. ``FrameProtocol`` owns the actual
    /// value types and wire format; ``FrameLink.Packet`` is a thin alias so the
    /// platform layers keep a single import surface.
    public typealias Packet = FrameProtocol.Packet
    public typealias VideoConfiguration = FrameProtocol.VideoConfiguration
    public typealias VideoSample = FrameProtocol.VideoSample
    public typealias VideoChroma = FrameProtocol.VideoChroma
    public typealias LinkFeedback = FrameProtocol.LinkFeedback
    public typealias Capability = FrameProtocol.Capability

    /// Encodes a length-prefixed TCP packet ready for the wire.
    static func encode(_ packet: Packet) -> Data {
        let payload = FrameProtocol.encode(packet)
        var length = UInt32(payload.count).bigEndian
        var framed = Data(bytes: &length, count: headerSize)
        framed.append(payload)
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

    /// Network parameters for the unreliable media channel. Peer-to-peer
    /// (AWDL) is enabled for the same high-bandwidth direct link.
    static func udpParameters() -> NWParameters {
        let parameters = NWParameters.udp
        parameters.includePeerToPeer = true
        return parameters
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
    private var udpListener: NWListener?
    private var connections: [ObjectIdentifier: ConnectionState] = [:]
    /// UDP client endpoints discovered as datagrams arrive (the receiver pokes
    /// the listener with a tiny hello so we learn where to send P-frames).
    private var udpConnections: [ObjectIdentifier: NWConnection] = [:]
    private var running = false
    private var framesSent = 0

    /// Diagnostics, invoked on `queue`. Lets the UI surface whether the
    /// listener is up, how many clients are connected, and how many frames
    /// have been pushed to the wire.
    public var onListenerReady: (() -> Void)?
    public var onClientCountChanged: ((Int) -> Void)?
    public var onFrameSent: ((Int) -> Void)?
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

    public init() {}

    deinit { stop() }

    public func start() {
        queue.async { [weak self] in
            self?.running = true
            self?.startListenerLocked()
            self?.startUDPListenerLocked()
        }
    }

    public func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.running = false
            self.listener?.cancel()
            self.listener = nil
            self.udpListener?.cancel()
            self.udpListener = nil
            for state in self.connections.values {
                state.connection.cancel()
            }
            self.connections.removeAll()
            for connection in self.udpConnections.values {
                connection.cancel()
            }
            self.udpConnections.removeAll()
        }
    }

    /// Sends one media packet to every connected client over the reliable TCP
    /// channel. The hybrid UDP P-frame path proved unreliable on real
    /// AWDL/Local-Network links (the receiver's UDP browse fails with NoAuth and
    /// the listener restart-loops), starving the stream of everything but
    /// keyframes. TCP carries 60fps HEVC comfortably on a LAN; the only cost is
    /// latency spikes under heavy loss, which is negligible here and far better
    /// than the freeze-every-2s the UDP split produced. UDP can return as an
    /// optimisation once discovery is sorted (see sendOverUDP, kept but unused).
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

    private func sendOverUDP(_ sample: FrameProtocol.VideoSample) {
        let datagrams = FrameProtocol.fragment(sample: sample)
        queue.async { [weak self] in
            guard let self else { return }
            var delivered = false
            for connection in self.udpConnections.values where connection.state == .ready {
                for datagram in datagrams {
                    connection.send(content: datagram, completion: .contentProcessed { _ in })
                }
                delivered = true
            }
            if delivered {
                self.countFrameSent()
            }
        }
    }

    @discardableResult
    private func broadcastTCP(_ packet: Data) -> Bool {
        var delivered = false
        for state in connections.values where state.connection.state == .ready {
            state.connection.send(content: packet, completion: .contentProcessed { _ in })
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

    private func startUDPListenerLocked() {
        guard running, udpListener == nil else { return }

        let listener: NWListener
        do {
            listener = try NWListener(using: FrameLink.udpParameters())
        } catch {
            queue.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.startUDPListenerLocked()
            }
            return
        }

        listener.service = NWListener.Service(type: FrameLink.udpServiceType)
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                frameLinkLog.log("FrameSender: UDP listener ready, advertising \(FrameLink.udpServiceType, privacy: .public)")
            case .failed, .cancelled:
                self.udpListener = nil
                guard self.running else { return }
                self.queue.asyncAfter(deadline: .now() + 1) { [weak self] in
                    self?.startUDPListenerLocked()
                }
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.adoptUDP(connection)
        }

        self.udpListener = listener
        listener.start(queue: queue)
    }

    private func scheduleListenerRestart() {
        guard running else { return }
        queue.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.startListenerLocked()
        }
    }

    private func adopt(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        connections[id] = ConnectionState(connection: connection)
        frameLinkLog.log("FrameSender: client connection accepted (\(self.connections.count, privacy: .public) total)")
        onClientCountChanged?(connections.count)

        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                // A fresh client needs a keyframe to begin decoding.
                self.onClientConnected?()
                self.receiveNext(from: id)
            case .failed, .cancelled:
                self.connections.removeValue(forKey: id)
                self.onClientCountChanged?(self.connections.count)
            default:
                break
            }
        }

        connection.start(queue: queue)
    }

    /// Adopts an inbound UDP "connection" (a datagram flow from one receiver)
    /// so we can address P-frame datagrams back to that endpoint.
    private func adoptUDP(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        udpConnections[id] = connection
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.receiveUDPHello(from: id)
            case .failed, .cancelled:
                self.udpConnections.removeValue(forKey: id)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    /// Drains (and discards) the receiver's UDP keep-alive/hello datagrams. We
    /// only need the flow to stay alive so our outbound P-frames have a route.
    private func receiveUDPHello(from id: ObjectIdentifier) {
        guard let connection = udpConnections[id] else { return }
        connection.receiveMessage { [weak self] _, _, isComplete, error in
            guard let self else { return }
            if error != nil || isComplete {
                self.udpConnections.removeValue(forKey: id)
                connection.cancel()
                return
            }
            self.receiveUDPHello(from: id)
        }
    }

    private func receiveNext(from id: ObjectIdentifier) {
        guard let state = connections[id] else { return }
        state.connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) {
            [weak self] data, _, isComplete, error in
            guard let self,
                  let state = self.connections[id] else { return }

            if let data, !data.isEmpty {
                state.buffer.append(data)
                self.drainInboundPackets(from: id)
            }

            if error != nil || isComplete {
                self.connections.removeValue(forKey: id)
                state.connection.cancel()
                self.onClientCountChanged?(self.connections.count)
                return
            }

            self.receiveNext(from: id)
        }
    }

    private func drainInboundPackets(from id: ObjectIdentifier) {
        guard let state = connections[id] else { return }
        while state.buffer.count >= FrameLink.headerSize {
            let length = state.buffer.prefix(FrameLink.headerSize).reduce(UInt32(0)) {
                ($0 << 8) | UInt32($1)
            }
            let packetLength = Int(length)
            let total = FrameLink.headerSize + packetLength
            guard state.buffer.count >= total else { break }

            let payload = state.buffer.subdata(in: FrameLink.headerSize ..< total)
            state.buffer.removeSubrange(0 ..< total)

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
                continue
            }
        }
    }

    private final class ConnectionState {
        let connection: NWConnection
        var buffer = Data()

        init(connection: NWConnection) {
            self.connection = connection
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
    private var udpBrowser: NWBrowser?
    private var udpConnection: NWConnection?
    private var buffer = Data()
    private var running = false
    private var framesReceived = 0
    private var pendingOutbound: [Data] = []

    /// Reassembles fragmented P-frames arriving over UDP.
    private let reassembler = FrameProtocol.Reassembler()
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
    /// Both TCP packets and fully reassembled UDP samples are delivered here.
    public var onPacket: ((FrameLink.Packet) -> Void)?
    public var onStatusChanged: ((String) -> Void)?
    public var onFrameCountChanged: ((Int) -> Void)?
    /// Fired with `true` when the frame connection becomes ready and `false`
    /// when it tears down, so the UI can match Pilot's appearance only while
    /// actually connected.
    public var onConnectedChanged: ((Bool) -> Void)?

    public init() {}

    deinit { stop() }

    public func start() {
        queue.async { [weak self] in
            self?.running = true
            self?.startBrowserLocked()
            self?.startUDPBrowserLocked()
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
            self.udpBrowser?.cancel()
            self.udpBrowser = nil
            self.udpConnection?.cancel()
            self.udpConnection = nil
            self.buffer.removeAll()
            self.pendingOutbound.removeAll()
            self.reassembler.reset()
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
        if connection?.state == .ready {
            connection?.send(content: packet, completion: .contentProcessed { _ in })
        } else {
            enqueueOutboundLocked(packet)
        }
    }

    private func enqueueOutbound(_ packet: Data) {
        queue.async { [weak self] in
            self?.enqueueOutboundLocked(packet)
        }
    }

    private func enqueueOutboundLocked(_ packet: Data) {
        guard connection?.state == .ready else {
            pendingOutbound.append(packet)
            if pendingOutbound.count > 16 {
                pendingOutbound.removeFirst(pendingOutbound.count - 16)
            }
            return
        }
        connection?.send(content: packet, completion: .contentProcessed { _ in })
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

    private func startUDPBrowserLocked() {
        guard running, udpBrowser == nil else { return }

        let browser = NWBrowser(
            for: .bonjour(type: FrameLink.udpServiceType, domain: nil),
            using: FrameLink.udpParameters()
        )
        browser.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .failed, .cancelled:
                self.udpBrowser = nil
                guard self.running else { return }
                self.queue.asyncAfter(deadline: .now() + 1) { [weak self] in
                    self?.startUDPBrowserLocked()
                }
            default:
                break
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self,
                  self.udpConnection == nil,
                  let first = results.first else { return }
            self.connectUDP(to: first.endpoint)
        }

        self.udpBrowser = browser
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
                self.updateStatus("Frame stream connected")
                self.onConnectedChanged?(true)
                self.flushPendingOutbound()
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
        buffer.removeAll(keepingCapacity: true)
        connection.start(queue: queue)
    }

    private func connectUDP(to endpoint: NWEndpoint) {
        let connection = NWConnection(to: endpoint, using: FrameLink.udpParameters())
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                // Poke the sender so it learns our endpoint and can route
                // P-frame datagrams back to us. Repeated periodically to keep
                // the NAT/flow alive.
                self.sendUDPHello()
                self.receiveUDP()
            case .failed, .cancelled:
                self.udpConnection = nil
                self.reassembler.reset()
                guard self.running, self.udpBrowser == nil else { return }
                self.queue.asyncAfter(deadline: .now() + 1) { [weak self] in
                    self?.startUDPBrowserLocked()
                }
            default:
                break
            }
        }
        self.udpConnection = connection
        connection.start(queue: queue)
    }

    private func sendUDPHello() {
        guard udpConnection?.state == .ready else { return }
        udpConnection?.send(content: Data([0x0]), completion: .contentProcessed { _ in })
        // Keep the flow alive so the sender's route to us doesn't expire.
        queue.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.sendUDPHello()
        }
    }

    private func receiveUDP() {
        udpConnection?.receiveMessage { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.ingestUDP(data)
            }
            if error != nil || isComplete {
                self.udpConnection?.cancel()
                self.udpConnection = nil
                self.reassembler.reset()
                if self.running, self.udpBrowser == nil {
                    self.queue.asyncAfter(deadline: .now() + 1) { [weak self] in
                        self?.startUDPBrowserLocked()
                    }
                }
                return
            }
            self.receiveUDP()
        }
    }

    private func ingestUDP(_ datagram: Data) {
        let result = reassembler.ingest(datagram)
        if result.needsKeyframe {
            requestKeyframeLocked()
        }
        if let sample = result.sample {
            countReceivedFrame()
            onPacket?(.sample(sample))
        }
    }

    private func teardownConnection() {
        connection?.cancel()
        connection = nil
        buffer.removeAll(keepingCapacity: true)
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
                self.buffer.append(data)
                self.drainFrames()
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

    /// Pulls as many complete length-prefixed packets out of `buffer` as are
    /// currently available. The TCP channel carries configuration, keyframe
    /// samples, control packets and the annotation ACK.
    private func drainFrames() {
        while buffer.count >= FrameLink.headerSize {
            let length = buffer.prefix(FrameLink.headerSize).reduce(UInt32(0)) {
                ($0 << 8) | UInt32($1)
            }
            let frameLength = Int(length)
            let total = FrameLink.headerSize + frameLength
            guard buffer.count >= total else { break }

            let payload = buffer.subdata(in: FrameLink.headerSize ..< total)
            buffer.removeSubrange(0 ..< total)

            guard frameLength > 0, let packet = FrameLink.decodePayload(payload) else {
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
                // New stream geometry/parameter sets: reset reassembly so we
                // don't splice fragments across a codec change.
                reassembler.reset()
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

    private func countReceivedFrame() {
        framesReceived += 1
        if framesReceived == 1 {
            updateStatus("Receiving Pilot frames")
        }
        onFrameCountChanged?(framesReceived)
    }

    private func flushPendingOutbound() {
        guard connection?.state == .ready else { return }
        let packets = pendingOutbound
        pendingOutbound.removeAll()
        for packet in packets {
            connection?.send(content: packet, completion: .contentProcessed { _ in })
        }
    }

    private func updateStatus(_ status: String) {
        frameLinkLog.log("FrameReceiver: \(status, privacy: .public)")
        onStatusChanged?(status)
    }
}

// MARK: - Annotation Control Channel (iPad / Plotter -> macOS / Pilot)

enum AnnotationLink {
    static let serviceType = "_blau-annotate._tcp"

    static func encode(_ message: AnnotationMessage) throws -> Data {
        let payload = try JSONEncoder().encode(message)
        var length = UInt32(payload.count).bigEndian
        var packet = Data(bytes: &length, count: FrameLink.headerSize)
        packet.append(payload)
        return packet
    }

    static func decode(_ payload: Data) -> AnnotationMessage? {
        try? JSONDecoder().decode(AnnotationMessage.self, from: payload)
    }
}

final class AnnotationReceiver: @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.blau.annotation.receiver")
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: ConnectionState] = [:]
    private var running = false

    var onMessage: ((AnnotationMessage) -> Void)?

    init() {}

    deinit { stop() }

    func start() {
        queue.async { [weak self] in
            self?.running = true
            self?.startListenerLocked()
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.running = false
            self.listener?.cancel()
            self.listener = nil
            for state in self.connections.values {
                state.connection.cancel()
            }
            self.connections.removeAll()
        }
    }

    private func startListenerLocked() {
        guard running, listener == nil else { return }

        let listener: NWListener
        do {
            listener = try NWListener(using: .tcp)
        } catch {
            scheduleListenerRestart()
            return
        }

        listener.service = NWListener.Service(type: AnnotationLink.serviceType)
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                frameLinkLog.log("AnnotationReceiver: listener ready, advertising \(AnnotationLink.serviceType, privacy: .public)")
            case .failed(let error):
                frameLinkLog.error("AnnotationReceiver: listener failed: \(error.localizedDescription, privacy: .public)")
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
        let id = ObjectIdentifier(connection)
        connections[id] = ConnectionState(connection: connection)
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.receiveNext(from: id)
            case .failed, .cancelled:
                self.connections.removeValue(forKey: id)
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
            guard let self else { return }
            guard let state = self.connections[id] else { return }

            if let data, !data.isEmpty {
                state.buffer.append(data)
                self.drainMessages(from: id)
            }

            if error != nil || isComplete {
                self.connections.removeValue(forKey: id)
                state.connection.cancel()
                return
            }

            self.receiveNext(from: id)
        }
    }

    private func drainMessages(from id: ObjectIdentifier) {
        guard let state = connections[id] else { return }
        while state.buffer.count >= FrameLink.headerSize {
            let length = state.buffer.prefix(FrameLink.headerSize).reduce(UInt32(0)) {
                ($0 << 8) | UInt32($1)
            }
            let messageLength = Int(length)
            let total = FrameLink.headerSize + messageLength
            guard state.buffer.count >= total else { break }

            let payload = state.buffer.subdata(in: FrameLink.headerSize ..< total)
            state.buffer.removeSubrange(0 ..< total)

            if let message = AnnotationLink.decode(payload) {
                onMessage?(message)
            }
        }
    }

    private final class ConnectionState {
        let connection: NWConnection
        var buffer = Data()

        init(connection: NWConnection) {
            self.connection = connection
        }
    }
}

final class AnnotationSender: @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.blau.annotation.sender")
    private var browser: NWBrowser?
    private var connection: NWConnection?
    private var pending: [Data] = []
    private var running = false

    var onStatusChanged: ((String) -> Void)?

    init() {}

    deinit { stop() }

    func start() {
        queue.async { [weak self] in
            self?.running = true
            self?.startBrowserLocked()
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.running = false
            self.browser?.cancel()
            self.browser = nil
            self.connection?.cancel()
            self.connection = nil
            self.pending.removeAll()
        }
    }

    func send(_ message: AnnotationMessage) {
        queue.async { [weak self] in
            guard let self,
                  let packet = try? AnnotationLink.encode(message) else { return }

            if self.connection?.state == .ready {
                self.connection?.send(content: packet, completion: .contentProcessed { _ in })
            } else {
                self.pending.append(packet)
                if self.pending.count > 8 {
                    self.pending.removeFirst(self.pending.count - 8)
                }
                self.startBrowserLocked()
            }
        }
    }

    private func startBrowserLocked() {
        guard running, browser == nil else { return }

        let browser = NWBrowser(
            for: .bonjour(type: AnnotationLink.serviceType, domain: nil),
            using: .tcp
        )
        browser.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.updateStatus("Browsing for Pilot annotation channel")
            case .failed, .cancelled:
                self.updateStatus("Annotation browser stopped")
                self.browser = nil
                self.scheduleBrowserRestart()
            case .waiting(let error):
                self.updateStatus("Annotation browser waiting: \(error.localizedDescription)")
            default:
                break
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self,
                  self.connection == nil,
                  let first = results.first else { return }
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
        let connection = NWConnection(to: endpoint, using: .tcp)
        updateStatus("Connecting to Pilot annotation channel")
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.updateStatus("Annotation channel connected")
                self.flushPending()
            case .failed, .cancelled:
                self.updateStatus("Annotation channel disconnected")
                self.connection = nil
            case .waiting(let error):
                self.updateStatus("Annotation channel waiting: \(error.localizedDescription)")
            default:
                break
            }
        }
        self.connection = connection
        connection.start(queue: queue)
    }

    private func flushPending() {
        guard connection?.state == .ready else { return }
        let packets = pending
        pending.removeAll()
        for packet in packets {
            connection?.send(content: packet, completion: .contentProcessed { _ in })
        }
    }

    private func updateStatus(_ status: String) {
        frameLinkLog.log("AnnotationSender: \(status, privacy: .public)")
        onStatusChanged?(status)
    }
}
