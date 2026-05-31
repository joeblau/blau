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
    /// Bonjour service type advertised by ``FrameSender`` and browsed for by
    /// ``FrameReceiver``.
    public static let serviceType = "_blau-frames._tcp"

    /// Size, in bytes, of the big-endian length prefix that precedes each packet.
    static let headerSize = 4

    public struct H264Configuration: Sendable {
        public let width: Int
        public let height: Int
        public let sps: Data
        public let pps: Data

        public init(width: Int, height: Int, sps: Data, pps: Data) {
            self.width = width
            self.height = height
            self.sps = sps
            self.pps = pps
        }
    }

    public struct H264Sample: Sendable {
        public let data: Data
        public let isKeyFrame: Bool

        public init(data: Data, isKeyFrame: Bool) {
            self.data = data
            self.isKeyFrame = isKeyFrame
        }
    }

    public enum Packet: Sendable {
        case h264Configuration(H264Configuration)
        case h264Sample(H264Sample)
        /// An annotation update from a client (Plotter), tagged with a
        /// monotonically increasing sequence number so the sender can be
        /// acknowledged once Pilot has accepted it.
        case annotation(seq: UInt32, message: AnnotationMessage)
        /// Pilot → client acknowledgement that the annotation with this
        /// sequence number has been accepted and is now being rendered.
        case annotationAck(seq: UInt32)
        case jpeg(Data)
    }

    private enum PacketKind: UInt8 {
        case h264Configuration = 1
        case h264Sample = 2
        case annotation = 3
        case annotationAck = 4
    }

    /// Encodes a length-prefixed packet ready for the wire.
    static func encode(_ packet: Packet) -> Data {
        let payload = encodePayload(packet)
        var length = UInt32(payload.count).bigEndian
        var packet = Data(bytes: &length, count: headerSize)
        packet.append(payload)
        return packet
    }

    static func decodePayload(_ payload: Data) -> Packet? {
        guard let kind = payload.first.flatMap(PacketKind.init(rawValue:)) else {
            // Backward compatibility for older Pilot builds that sent raw JPEGs.
            return payload.isEmpty ? nil : .jpeg(payload)
        }

        switch kind {
        case .h264Configuration:
            guard payload.count >= 21 else { return nil }
            let width = Int(readUInt32(from: payload, offset: 2))
            let height = Int(readUInt32(from: payload, offset: 6))
            let spsLength = Int(readUInt32(from: payload, offset: 10))
            let ppsLength = Int(readUInt32(from: payload, offset: 14))
            let spsStart = 18
            let spsEnd = spsStart + spsLength
            let ppsEnd = spsEnd + ppsLength
            guard width > 0,
                  height > 0,
                  spsLength > 0,
                  ppsLength > 0,
                  ppsEnd == payload.count else { return nil }

            return .h264Configuration(H264Configuration(
                width: width,
                height: height,
                sps: payload.subdata(in: spsStart ..< spsEnd),
                pps: payload.subdata(in: spsEnd ..< ppsEnd)
            ))
        case .h264Sample:
            guard payload.count >= 3 else { return nil }
            let flags = payload[payload.index(payload.startIndex, offsetBy: 1)]
            return .h264Sample(H264Sample(
                data: payload.subdata(in: payload.index(payload.startIndex, offsetBy: 2) ..< payload.endIndex),
                isKeyFrame: (flags & 0x1) != 0
            ))
        case .annotation:
            guard payload.count >= 2 else { return nil }
            let version = payload[payload.index(payload.startIndex, offsetBy: 1)]
            // Version 1 carried no sequence number; version 2 inserts a
            // 4-byte big-endian seq between the version byte and the JSON.
            let jsonOffset: Int
            let seq: UInt32
            if version >= 2 {
                guard payload.count >= 6 else { return nil }
                seq = readUInt32(from: payload, offset: 2)
                jsonOffset = 6
            } else {
                seq = 0
                jsonOffset = 2
            }
            guard let message = try? JSONDecoder().decode(
                AnnotationMessage.self,
                from: payload.subdata(in: payload.index(payload.startIndex, offsetBy: jsonOffset) ..< payload.endIndex)
            ) else { return nil }
            return .annotation(seq: seq, message: message)
        case .annotationAck:
            guard payload.count >= 6 else { return nil }
            return .annotationAck(seq: readUInt32(from: payload, offset: 2))
        }
    }

    private static func encodePayload(_ packet: Packet) -> Data {
        switch packet {
        case .h264Configuration(let config):
            var payload = Data()
            payload.append(PacketKind.h264Configuration.rawValue)
            payload.append(1) // protocol version
            appendUInt32(UInt32(config.width), to: &payload)
            appendUInt32(UInt32(config.height), to: &payload)
            appendUInt32(UInt32(config.sps.count), to: &payload)
            appendUInt32(UInt32(config.pps.count), to: &payload)
            payload.append(config.sps)
            payload.append(config.pps)
            return payload
        case .h264Sample(let sample):
            var payload = Data()
            payload.append(PacketKind.h264Sample.rawValue)
            payload.append(sample.isKeyFrame ? 0x1 : 0x0)
            payload.append(sample.data)
            return payload
        case .annotation(let seq, let message):
            var payload = Data()
            payload.append(PacketKind.annotation.rawValue)
            payload.append(2) // protocol version (2 = includes 4-byte seq)
            appendUInt32(seq, to: &payload)
            if let encoded = try? JSONEncoder().encode(message) {
                payload.append(encoded)
            }
            return payload
        case .annotationAck(let seq):
            var payload = Data()
            payload.append(PacketKind.annotationAck.rawValue)
            payload.append(2) // protocol version
            appendUInt32(seq, to: &payload)
            return payload
        case .jpeg(let jpeg):
            return jpeg
        }
    }

    private static func appendUInt32(_ value: UInt32, to data: inout Data) {
        var bigEndian = value.bigEndian
        data.append(Data(bytes: &bigEndian, count: MemoryLayout<UInt32>.size))
    }

    private static func readUInt32(from data: Data, offset: Int) -> UInt32 {
        data.dropFirst(offset).prefix(4).reduce(UInt32(0)) {
            ($0 << 8) | UInt32($1)
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

    public init() {}

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
        }
    }

    /// Sends one media packet to every connected client.
    public func send(_ mediaPacket: FrameLink.Packet) {
        let packet = FrameLink.encode(mediaPacket)
        queue.async { [weak self] in
            guard let self else { return }
            var delivered = false
            for state in self.connections.values where state.connection.state == .ready {
                state.connection.send(content: packet, completion: .contentProcessed { _ in })
                delivered = true
            }
            if delivered {
                self.framesSent += 1
                if self.framesSent == 1 {
                    frameLinkLog.log("FrameSender: first frame sent to a client")
                }
                self.onFrameSent?(self.framesSent)
            }
        }
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
            for state in self.connections.values where state.connection.state == .ready {
                state.connection.send(content: packet, completion: .contentProcessed { _ in })
            }
        }
    }

    // MARK: Private (always called on `queue`)

    private func startListenerLocked() {
        guard running, listener == nil else { return }

        let parameters = NWParameters.tcp

        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
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
        let id = ObjectIdentifier(connection)
        connections[id] = ConnectionState(connection: connection)
        frameLinkLog.log("FrameSender: client connection accepted (\(self.connections.count, privacy: .public) total)")
        onClientCountChanged?(connections.count)

        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
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

            guard case .annotation(let seq, let message) = FrameLink.decodePayload(payload) else {
                continue
            }

            frameLinkLog.log("FrameSender: annotation packet received (seq \(seq, privacy: .public))")
            onAnnotationMessage?(seq, message)
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
    private var buffer = Data()
    private var running = false
    private var framesReceived = 0
    private var pendingOutbound: [Data] = []

    /// Called on an internal queue for every complete JPEG frame received.
    public var onFrame: ((Data) -> Void)?
    /// Called on an internal queue for every decoded media packet received.
    public var onPacket: ((FrameLink.Packet) -> Void)?
    public var onStatusChanged: ((String) -> Void)?
    public var onFrameCountChanged: ((Int) -> Void)?

    public init() {}

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
            self.buffer.removeAll()
            self.pendingOutbound.removeAll()
        }
    }

    public func sendAnnotation(_ message: AnnotationMessage, seq: UInt32) {
        let packet = FrameLink.encode(.annotation(seq: seq, message: message))
        queue.async { [weak self] in
            guard let self else { return }
            guard self.connection?.state == .ready else {
                self.pendingOutbound.append(packet)
                if self.pendingOutbound.count > 8 {
                    self.pendingOutbound.removeFirst(self.pendingOutbound.count - 8)
                }
                return
            }

            self.connection?.send(content: packet, completion: .contentProcessed { _ in })
        }
    }

    // MARK: Private (always called on `queue`)

    private func startBrowserLocked() {
        guard running, browser == nil else { return }

        let parameters = NWParameters.tcp

        let browser = NWBrowser(
            for: .bonjour(type: FrameLink.serviceType, domain: nil),
            using: parameters
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
        let parameters = NWParameters.tcp

        let connection = NWConnection(to: endpoint, using: parameters)
        updateStatus("Connecting to Pilot frame stream")
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.updateStatus("Frame stream connected")
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

    private func teardownConnection() {
        connection?.cancel()
        connection = nil
        buffer.removeAll(keepingCapacity: true)
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
    /// currently available.
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

            if case .h264Sample = packet {
                framesReceived += 1
                if framesReceived == 1 {
                    updateStatus("Receiving Pilot frames")
                }
                onFrameCountChanged?(framesReceived)
            }

            if case .jpeg(let frame) = packet {
                framesReceived += 1
                if framesReceived == 1 {
                    updateStatus("Receiving Pilot frames")
                }
                onFrameCountChanged?(framesReceived)
                onFrame?(frame)
            }

            if case .annotation = packet {
                continue
            }

            onPacket?(packet)
        }
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
