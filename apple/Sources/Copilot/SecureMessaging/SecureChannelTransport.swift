import Foundation
import Network
import CryptoKit
import Observation

/// End-to-end UDP transport for the peer-to-peer secure channel (issue #51),
/// Copilot's initiator side.
///
/// Lifecycle (see ``ConnectionState``):
///
///   1. **signaling** — register this device + the chosen UDP port with the
///      rendezvous worker and learn the peer's `{ ip, port }`.
///   2. **holePunching** — fire a few cleartext UDP probes at the peer's
///      endpoint so both NATs open a mapping for the path.
///   3. **handshake** — run the Noise IK handshake (this device is the
///      initiator; it already knows the peer's pinned static key).
///   4. **connected** — exchange ChaChaPoly-sealed packets. Reliable JSON
///      messages are ACK'd + retransmitted; best-effort blobs are fire-and-forget.
///
/// All mutable state is confined to the main actor so the SwiftUI screen can
/// observe it directly; the socket callbacks hop back here before touching state.
@MainActor
@Observable
final class SecureChannelTransport {

    // MARK: - Observable state

    private(set) var state: ConnectionState = .signaling
    /// Human-readable transcript of the session for the UI log.
    private(set) var log: [LogEntry] = []
    /// Decrypted text messages received from the peer.
    private(set) var received: [String] = []

    struct LogEntry: Identifiable {
        let id = UUID()
        let date = Date()
        let text: String
    }

    // MARK: - Configuration

    /// Wire envelope for a reliable text message (JSON, type 0x02).
    private struct TextEnvelope: Codable {
        let msgID: UInt64
        let text: String
    }

    private let signaling: SignalingClient
    private let token: String
    private let staticKey: Curve25519.KeyAgreement.PrivateKey
    private let peerStatic: Curve25519.KeyAgreement.PublicKey
    private let localPort: UInt16

    // MARK: - Runtime

    private var connection: NWConnection?
    private var handshakeState: NoiseIK.Initiator?
    private var transportKeys: TransportKeys?
    /// Pending continuation resumed once the UDP socket reaches `.ready`/fails.
    private var socketReady: CheckedContinuation<Void, Error>?

    /// Per-direction send counters. Copilot is the initiator, so it *sends* on
    /// I->R and *receives* on R->I.
    private var sendCounter: UInt64 = 0
    private var replay = ReplayWindow()

    private var messenger = ReliableMessenger()
    private var ackTracker = AckTracker()
    private var retransmitTask: Task<Void, Never>?
    private var lifecycleTask: Task<Void, Never>?

    /// Monotonic clock origin; the ReliableMessenger only needs relative seconds.
    private let clockOrigin = ContinuousClock.now
    private var nowSeconds: Double {
        clockOrigin.duration(to: ContinuousClock.now).seconds
    }

    init(
        signaling: SignalingClient,
        token: String,
        staticKey: Curve25519.KeyAgreement.PrivateKey,
        peerStatic: Curve25519.KeyAgreement.PublicKey,
        localPort: UInt16 = SecureChannelTransport.randomEphemeralPort()
    ) {
        self.signaling = signaling
        self.token = token
        self.staticKey = staticKey
        self.peerStatic = peerStatic
        self.localPort = localPort
    }

    /// A random high port for the local UDP socket / NAT mapping.
    static func randomEphemeralPort() -> UInt16 {
        UInt16.random(in: 20_000...60_000)
    }

    // MARK: - Public API

    /// Begin the signaling -> hole-punch -> handshake -> connected walk.
    func connect() {
        guard lifecycleTask == nil else { return }
        appendLog("Connecting (local UDP port \(localPort))…")
        lifecycleTask = Task { [weak self] in
            await self?.runLifecycle()
        }
    }

    /// Tear everything down and reset to a fresh signaling state.
    func disconnect() {
        lifecycleTask?.cancel()
        lifecycleTask = nil
        retransmitTask?.cancel()
        retransmitTask = nil
        connection?.cancel()
        connection = nil
        handshakeState = nil
        transportKeys = nil
        sendCounter = 0
        replay = ReplayWindow()
        messenger = ReliableMessenger()
        ackTracker = AckTracker()
        state = .signaling
        appendLog("Disconnected.")
    }

    /// Send a reliable, ACK-tracked text message to the peer.
    func sendText(_ text: String) {
        guard state.isConnected, let keys = transportKeys else {
            appendLog("Not connected; can't send.")
            return
        }
        let id = messenger.enqueue(Data(), now: nowSeconds).id
        let envelope = TextEnvelope(msgID: id, text: text)
        guard let json = try? JSONEncoder().encode(envelope) else { return }
        // Re-enqueue with the actual JSON payload so retransmits resend it.
        messenger.replacePayload(id: id, payload: json)
        appendLog("→ text #\(id): \(text)")
        transmit(type: .reliableControl, plaintext: json, keys: keys)
        scheduleRetransmit()
    }

    /// Send a best-effort (unreliable, type 0x04) test blob.
    func sendTestBlob() {
        guard state.isConnected, let keys = transportKeys else {
            appendLog("Not connected; can't send blob.")
            return
        }
        let blob = Data((0..<256).map { UInt8($0 & 0xFF) })
        appendLog("→ best-effort blob (\(blob.count) bytes)")
        transmit(type: .bestEffortBlob, plaintext: blob, keys: keys)
    }

    // MARK: - Lifecycle

    private func runLifecycle() async {
        do {
            // 1. Signaling.
            let myKey = staticKey.publicKey.rawRepresentation.base64EncodedString()
            appendLog("Registering with rendezvous…")
            var peer = try await signaling.register(
                token: token, publicKeyBase64: myKey, port: localPort
            )
            if peer == nil {
                appendLog("Waiting for peer to register…")
                peer = try await signaling.waitForPeer(token: token, publicKeyBase64: myKey)
            }
            guard let peer else {
                fail("Peer never registered.")
                return
            }
            appendLog("Peer endpoint: \(peer.ip):\(peer.port)")

            transition(to: .holePunching)
            try await openSocket(to: peer)

            // 2. Hole punching: a burst of cleartext probes.
            appendLog("Hole punching…")
            for _ in 0..<5 {
                sendRaw(Data([0x00]))  // probe; receiver ignores non-handshake clear bytes
                try? await Task.sleep(for: .milliseconds(150))
            }

            // 3. Handshake.
            transition(to: .handshake)
            try startHandshake()
        } catch is CancellationError {
            // Disconnect requested.
        } catch {
            fail(error.localizedDescription)
        }
    }

    // MARK: - Socket

    private func openSocket(to peer: SignalingClient.PeerEndpoint) async throws {
        let host = NWEndpoint.Host(peer.ip)
        guard let port = NWEndpoint.Port(rawValue: peer.port) else {
            throw SignalingClient.SignalingError.decode
        }

        let params = NWParameters.udp
        // Bind to our advertised local port so the NAT mapping matches what we
        // registered with the rendezvous worker.
        if let localPort = NWEndpoint.Port(rawValue: localPort) {
            params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "0.0.0.0", port: localPort)
        }
        params.allowLocalEndpointReuse = true

        let conn = NWConnection(host: host, port: port, using: params)
        self.connection = conn

        conn.stateUpdateHandler = { [weak self] nwState in
            guard let self else { return }
            Task { @MainActor in self.handleSocketState(nwState) }
        }

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            self.socketReady = cont
            conn.start(queue: .global(qos: .userInitiated))
        }

        startReceiveLoop(on: conn)
    }

    /// Resolve the one-shot `socketReady` continuation on the first terminal
    /// socket event; after it has fired, later failures abort the session.
    private func handleSocketState(_ nwState: NWConnection.State) {
        switch nwState {
        case .ready:
            socketReady?.resume()
            socketReady = nil
        case .failed(let err):
            if let cont = socketReady { socketReady = nil; cont.resume(throwing: err) }
            else { fail("Socket failed: \(err.localizedDescription)") }
        case .cancelled:
            if let cont = socketReady { socketReady = nil; cont.resume(throwing: CancellationError()) }
        default:
            break
        }
    }

    private func startReceiveLoop(on conn: NWConnection) {
        conn.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            Task { @MainActor in
                if let data, !data.isEmpty {
                    self.handleInbound(data)
                }
                if error == nil {
                    if let conn = self.connection { self.startReceiveLoop(on: conn) }
                }
            }
        }
    }

    private func sendRaw(_ data: Data) {
        connection?.send(content: data, completion: .contentProcessed { _ in })
    }

    // MARK: - Handshake

    private func startHandshake() throws {
        let (st, msg1) = try NoiseIK.Initiator.start(
            staticKey: staticKey,
            responderStatic: peerStatic
        )
        handshakeState = st
        appendLog("→ handshake msg1 (\(msg1.count) bytes)")
        // Wrap the handshake message in a packet header (type 0x01) for framing
        // consistency; handshake bytes are not yet ChaChaPoly-sealed.
        var packet = PacketCodec.encodeHeader(type: .handshake, counter: 0)
        packet.append(msg1)
        sendRaw(packet)
    }

    private func handleHandshakeReply(_ body: Data) {
        guard let st = handshakeState else { return }
        do {
            let result = try st.receive(body)
            transportKeys = result.keys
            handshakeState = nil
            transition(to: .connected)
            appendLog("Handshake complete — channel encrypted.")
        } catch {
            fail("Handshake failed: \(error)")
        }
    }

    // MARK: - Inbound

    private func handleInbound(_ data: Data) {
        // Ignore bare hole-punch probes (a single 0x00 byte).
        if data.count == 1 { return }

        guard let sealed = try? PacketCodec.parse(data) else { return }

        switch sealed.type {
        case .handshake:
            handleHandshakeReply(sealed.ciphertextAndTag)

        case .reliableControl, .ack, .bestEffortBlob:
            guard let keys = transportKeys else { return }
            guard let opened = try? PacketCodec.open(
                data,
                key: keys.responderToInitiatorKey,
                baseNonce: keys.responderToInitiatorBaseNonce
            ) else {
                appendLog("Dropped undecryptable packet.")
                return
            }
            // Replay protection over the per-direction counter.
            guard replay.accept(opened.counter) else {
                appendLog("Dropped replayed packet (counter \(opened.counter)).")
                return
            }
            dispatch(type: opened.type, plaintext: opened.plaintext, keys: keys)
        }
    }

    private func dispatch(type: PacketCodec.PacketType, plaintext: Data, keys: TransportKeys) {
        switch type {
        case .reliableControl:
            guard let envelope = try? JSONDecoder().decode(TextEnvelope.self, from: plaintext) else {
                return
            }
            // Always ACK (so the sender stops retransmitting), deliver once.
            sendAck(msgID: envelope.msgID, keys: keys)
            if ackTracker.receive(envelope.msgID) {
                received.append(envelope.text)
                appendLog("← text #\(envelope.msgID): \(envelope.text)")
            } else {
                appendLog("← duplicate text #\(envelope.msgID) (re-ACK'd).")
            }

        case .ack:
            guard plaintext.count == 8 else { return }
            var id: UInt64 = 0
            for b in plaintext { id = (id << 8) | UInt64(b) }
            if messenger.acknowledge(id) {
                appendLog("✓ ACK #\(id)")
            }

        case .bestEffortBlob:
            appendLog("← best-effort blob (\(plaintext.count) bytes)")

        case .handshake:
            break
        }
    }

    // MARK: - Outbound

    private func transmit(type: PacketCodec.PacketType, plaintext: Data, keys: TransportKeys) {
        let counter = sendCounter
        sendCounter &+= 1
        guard let packet = try? PacketCodec.seal(
            type: type,
            counter: counter,
            plaintext: plaintext,
            key: keys.initiatorToResponderKey,
            baseNonce: keys.initiatorToResponderBaseNonce
        ) else { return }
        sendRaw(packet)
    }

    private func sendAck(msgID: UInt64, keys: TransportKeys) {
        var payload = Data(capacity: 8)
        var be = msgID.bigEndian
        withUnsafeBytes(of: &be) { payload.append(contentsOf: $0) }
        transmit(type: .ack, plaintext: payload, keys: keys)
    }

    // MARK: - Retransmission

    private func scheduleRetransmit() {
        guard retransmitTask == nil else { return }
        retransmitTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let sleepFor = await self.pumpRetransmit()
                guard let sleepFor else { return }  // idle: stop the loop
                try? await Task.sleep(for: .seconds(max(0.05, sleepFor)))
            }
        }
    }

    /// One retransmit tick. Returns the seconds to sleep before the next tick,
    /// or `nil` when there is nothing left in flight (loop should stop).
    private func pumpRetransmit() -> Double? {
        guard let keys = transportKeys else { retransmitTask = nil; return nil }
        let now = nowSeconds
        switch messenger.due(now: now) {
        case .send(let messages):
            for m in messages {
                appendLog("↻ retransmit #\(m.id)")
                transmit(type: .reliableControl, plaintext: m.payload, keys: keys)
            }
            return 0.1
        case .waitUntil(let when):
            return max(0.05, when - now)
        case .idle:
            retransmitTask = nil
            return nil
        }
    }

    // MARK: - State helpers

    private func transition(to next: ConnectionState) {
        guard state.canTransition(to: next) else { return }
        state = next
        appendLog("State → \(next.label)")
    }

    private func fail(_ reason: String) {
        guard !state.isFailed else { return }
        state = .failed(reason: reason)
        appendLog("Failed: \(reason)")
    }

    private func appendLog(_ text: String) {
        log.append(LogEntry(text: text))
        if log.count > 200 { log.removeFirst(log.count - 200) }
    }
}

// MARK: - Helpers

private extension Duration {
    var seconds: Double {
        let (s, attos) = components
        return Double(s) + Double(attos) / 1e18
    }
}

private extension ConnectionState {
    var label: String {
        switch self {
        case .signaling: return "signaling"
        case .holePunching: return "hole punching"
        case .handshake: return "handshake"
        case .connected: return "connected"
        case .failed(let reason): return "failed (\(reason))"
        }
    }
}
