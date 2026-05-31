import Foundation

/// Pure, socket-free value layer for the HEVC mirroring link.
///
/// Nothing in this file touches `Network.framework`; it is a deterministic
/// value/codec layer so the wire format and the UDP reassembler can be unit
/// tested on any platform. ``FrameLink`` (which *does* own the sockets) builds
/// on top of these types.
///
/// Wire model: every packet serialises to a single `Data` blob whose first byte
/// is a ``FrameProtocol/Kind`` tag. ``FrameLink`` wraps each blob in its
/// existing 4-byte big-endian length prefix when it goes over the reliable TCP
/// control channel. P-frame samples instead travel as UDP datagrams produced by
/// ``FrameProtocol/fragment(sample:)`` and rebuilt by a ``Reassembler``.
public enum FrameProtocol {
    /// Maximum app-layer UDP datagram **payload** size (after our fragment
    /// header) chosen to stay comfortably under a typical 1500-byte MTU once
    /// IP/UDP headers are accounted for.
    public static let maxFragmentPayload = 1200

    // MARK: - Models

    /// Chroma subsampling negotiated for the HEVC stream. `yuv444` keeps text
    /// and terminal output crisp; `yuv420` is the universally safe fallback.
    public enum VideoChroma: UInt8, Sendable, Codable, Equatable {
        case yuv420 = 0
        case yuv444 = 1
    }

    /// HEVC stream configuration. Generalises the old H.264 configuration which
    /// only carried SPS/PPS; HEVC adds a VPS parameter set.
    public struct VideoConfiguration: Sendable, Equatable {
        public let width: Int
        public let height: Int
        public let chroma: VideoChroma
        public let vps: Data
        public let sps: Data
        public let pps: Data

        public init(width: Int, height: Int, chroma: VideoChroma, vps: Data, sps: Data, pps: Data) {
            self.width = width
            self.height = height
            self.chroma = chroma
            self.vps = vps
            self.sps = sps
            self.pps = pps
        }
    }

    /// A single compressed HEVC access unit.
    ///
    /// `frameID` increases monotonically across the whole stream so the
    /// receiver can detect loss/reordering on the unreliable UDP path.
    public struct VideoSample: Sendable, Equatable {
        public let frameID: UInt32
        public let isKeyFrame: Bool
        public let data: Data

        public init(frameID: UInt32, isKeyFrame: Bool, data: Data) {
            self.frameID = frameID
            self.isKeyFrame = isKeyFrame
            self.data = data
        }
    }

    /// Receiver -> sender link-quality report used to drive adaptive bitrate.
    public struct LinkFeedback: Sendable, Equatable {
        public let lossPct: Double
        public let rttMs: Double
        public let queueDepth: Int

        public init(lossPct: Double, rttMs: Double, queueDepth: Int) {
            self.lossPct = lossPct
            self.rttMs = rttMs
            self.queueDepth = queueDepth
        }
    }

    /// Decoder capability advertised by the receiver during the handshake.
    public struct Capability: Sendable, Equatable {
        public let supports444: Bool

        public init(supports444: Bool) {
            self.supports444 = supports444
        }
    }

    /// Every logical message that can travel over the link, independent of
    /// whether it ends up on the TCP or UDP path.
    public enum Packet: Sendable, Equatable {
        /// HEVC parameter sets + geometry. Always sent over TCP.
        case configuration(VideoConfiguration)
        /// A compressed access unit. Keyframes go over TCP; P-frames are
        /// fragmented over UDP. Both decode to this case.
        case sample(VideoSample)
        /// Receiver -> sender: please emit an IDR/keyframe now.
        case keyframeRequest
        /// Receiver -> sender: current link quality.
        case linkFeedback(LinkFeedback)
        /// Receiver -> sender: decode capabilities (handshake).
        case capability(Capability)
        /// Client (Plotter) -> sender annotation update, sequence-tagged.
        case annotation(seq: UInt32, message: AnnotationMessage)
        /// Sender -> client acknowledgement of an accepted annotation.
        case annotationAck(seq: UInt32)
        /// Sender -> client: Pilot's current appearance, so a connected Plotter
        /// can match the Mac's light/dark mode instead of its own.
        case appearance(isDark: Bool)
        /// Legacy JPEG frame. Decoded for backward compatibility only.
        case jpeg(Data)
    }

    // MARK: - Packet wire tags

    enum Kind: UInt8 {
        case configuration = 1
        case sample = 2
        case keyframeRequest = 3
        case linkFeedback = 4
        case capability = 5
        case annotation = 6
        case annotationAck = 7
        case appearance = 8
        // Note: there is no tag for jpeg. A tagless / unknown-tag payload is
        // treated as a legacy raw JPEG by ``decode(_:)``.
    }

    // MARK: - Packet encode / decode

    /// Serialises a packet to a single tagged `Data` blob (no length prefix).
    public static func encode(_ packet: Packet) -> Data {
        switch packet {
        case .configuration(let config):
            var payload = Data()
            payload.append(Kind.configuration.rawValue)
            payload.append(config.chroma.rawValue)
            appendUInt32(UInt32(config.width), to: &payload)
            appendUInt32(UInt32(config.height), to: &payload)
            appendUInt32(UInt32(config.vps.count), to: &payload)
            appendUInt32(UInt32(config.sps.count), to: &payload)
            appendUInt32(UInt32(config.pps.count), to: &payload)
            payload.append(config.vps)
            payload.append(config.sps)
            payload.append(config.pps)
            return payload
        case .sample(let sample):
            var payload = Data()
            payload.append(Kind.sample.rawValue)
            payload.append(sample.isKeyFrame ? 0x1 : 0x0)
            appendUInt32(sample.frameID, to: &payload)
            payload.append(sample.data)
            return payload
        case .keyframeRequest:
            return Data([Kind.keyframeRequest.rawValue])
        case .linkFeedback(let feedback):
            var payload = Data()
            payload.append(Kind.linkFeedback.rawValue)
            appendUInt64(feedback.lossPct.bitPattern, to: &payload)
            appendUInt64(feedback.rttMs.bitPattern, to: &payload)
            appendUInt32(UInt32(max(0, feedback.queueDepth)), to: &payload)
            return payload
        case .capability(let capability):
            var payload = Data()
            payload.append(Kind.capability.rawValue)
            payload.append(capability.supports444 ? 0x1 : 0x0)
            return payload
        case .annotation(let seq, let message):
            var payload = Data()
            payload.append(Kind.annotation.rawValue)
            appendUInt32(seq, to: &payload)
            if let encoded = try? JSONEncoder().encode(message) {
                payload.append(encoded)
            }
            return payload
        case .annotationAck(let seq):
            var payload = Data()
            payload.append(Kind.annotationAck.rawValue)
            appendUInt32(seq, to: &payload)
            return payload
        case .appearance(let isDark):
            return Data([Kind.appearance.rawValue, isDark ? 0x1 : 0x0])
        case .jpeg(let jpeg):
            return jpeg
        }
    }

    /// Parses a tagged `Data` blob back into a ``Packet``. Returns `nil` only
    /// when the payload is empty or structurally invalid for its tag. An
    /// unrecognised first byte is interpreted as a legacy raw JPEG so older
    /// Pilot builds keep working.
    public static func decode(_ payload: Data) -> Packet? {
        guard let first = payload.first else { return nil }
        guard let kind = Kind(rawValue: first) else {
            return .jpeg(payload)
        }

        switch kind {
        case .configuration:
            // tag(1) + chroma(1) + width(4) + height(4) + vps(4) + sps(4) + pps(4) = 22
            guard payload.count >= 22 else { return nil }
            guard let chroma = VideoChroma(rawValue: payload[payload.startIndex + 1]) else { return nil }
            let width = Int(readUInt32(from: payload, offset: 2))
            let height = Int(readUInt32(from: payload, offset: 6))
            let vpsLength = Int(readUInt32(from: payload, offset: 10))
            let spsLength = Int(readUInt32(from: payload, offset: 14))
            let ppsLength = Int(readUInt32(from: payload, offset: 18))
            let vpsStart = 22
            let spsStart = vpsStart + vpsLength
            let ppsStart = spsStart + spsLength
            let end = ppsStart + ppsLength
            guard width > 0, height > 0,
                  vpsLength > 0, spsLength > 0, ppsLength > 0,
                  end == payload.count else { return nil }
            return .configuration(VideoConfiguration(
                width: width,
                height: height,
                chroma: chroma,
                vps: slice(payload, vpsStart, spsStart),
                sps: slice(payload, spsStart, ppsStart),
                pps: slice(payload, ppsStart, end)
            ))
        case .sample:
            // tag(1) + flags(1) + frameID(4) = 6
            guard payload.count >= 6 else { return nil }
            let flags = payload[payload.startIndex + 1]
            let frameID = readUInt32(from: payload, offset: 2)
            return .sample(VideoSample(
                frameID: frameID,
                isKeyFrame: (flags & 0x1) != 0,
                data: slice(payload, 6, payload.count)
            ))
        case .keyframeRequest:
            return .keyframeRequest
        case .linkFeedback:
            // tag(1) + loss(8) + rtt(8) + queue(4) = 21
            guard payload.count >= 21 else { return nil }
            let loss = Double(bitPattern: readUInt64(from: payload, offset: 1))
            let rtt = Double(bitPattern: readUInt64(from: payload, offset: 9))
            let queue = Int(readUInt32(from: payload, offset: 17))
            return .linkFeedback(LinkFeedback(lossPct: loss, rttMs: rtt, queueDepth: queue))
        case .capability:
            guard payload.count >= 2 else { return nil }
            return .capability(Capability(supports444: payload[payload.startIndex + 1] != 0))
        case .annotation:
            guard payload.count >= 5 else { return nil }
            let seq = readUInt32(from: payload, offset: 1)
            guard let message = try? JSONDecoder().decode(
                AnnotationMessage.self,
                from: slice(payload, 5, payload.count)
            ) else { return nil }
            return .annotation(seq: seq, message: message)
        case .annotationAck:
            guard payload.count >= 5 else { return nil }
            return .annotationAck(seq: readUInt32(from: payload, offset: 1))
        case .appearance:
            guard payload.count >= 2 else { return nil }
            return .appearance(isDark: payload[payload.startIndex + 1] != 0)
        }
    }

    // MARK: - UDP fragmentation

    /// Size, in bytes, of the per-datagram fragment header that prefixes each
    /// UDP payload chunk: frameID(4) + fragmentIndex(2) + fragmentCount(2) +
    /// flags(1).
    static let fragmentHeaderSize = 9

    /// Splits a sample's compressed `Data` into UDP-sized datagrams. Each
    /// datagram is self-describing: it carries the `frameID`, its own
    /// `fragmentIndex`, the total `fragmentCount`, and the keyframe flag so the
    /// ``Reassembler`` can rebuild the access unit without any side channel.
    ///
    /// A zero-length sample still produces exactly one (empty-payload)
    /// datagram so an empty access unit is representable.
    public static func fragment(sample: VideoSample) -> [Data] {
        let body = sample.data
        let chunkSize = maxFragmentPayload
        let fragmentCount = max(1, Int((body.count + chunkSize - 1) / chunkSize))
        precondition(fragmentCount <= Int(UInt16.max), "sample too large to fragment")

        var datagrams: [Data] = []
        datagrams.reserveCapacity(fragmentCount)
        for index in 0 ..< fragmentCount {
            let start = index * chunkSize
            let end = min(start + chunkSize, body.count)

            var datagram = Data()
            appendUInt32(sample.frameID, to: &datagram)
            appendUInt16(UInt16(index), to: &datagram)
            appendUInt16(UInt16(fragmentCount), to: &datagram)
            datagram.append(sample.isKeyFrame ? 0x1 : 0x0)
            if start < end {
                datagram.append(body.subdata(in: (body.startIndex + start) ..< (body.startIndex + end)))
            }
            datagrams.append(datagram)
        }
        return datagrams
    }

    /// A single parsed UDP fragment. Exposed for testing and reuse.
    public struct Fragment: Sendable, Equatable {
        public let frameID: UInt32
        public let index: UInt16
        public let count: UInt16
        public let isKeyFrame: Bool
        public let payload: Data
    }

    /// Parses a raw UDP datagram into a ``Fragment``; `nil` if too short.
    public static func parseFragment(_ datagram: Data) -> Fragment? {
        guard datagram.count >= fragmentHeaderSize else { return nil }
        let frameID = readUInt32(from: datagram, offset: 0)
        let index = readUInt16(from: datagram, offset: 4)
        let count = readUInt16(from: datagram, offset: 6)
        let flags = datagram[datagram.startIndex + 8]
        guard count > 0, index < count else { return nil }
        return Fragment(
            frameID: frameID,
            index: index,
            count: count,
            isKeyFrame: (flags & 0x1) != 0,
            payload: slice(datagram, fragmentHeaderSize, datagram.count)
        )
    }

    // MARK: - Reassembler

    /// Rebuilds ``VideoSample`` access units from out-of-order, possibly
    /// lossy/duplicated UDP fragments.
    ///
    /// Behaviour:
    /// - Tolerates fragments arriving in any order within a bounded window.
    /// - Deduplicates repeated fragments (same frameID + index).
    /// - Drops partial frames older than ``windowSize`` frames behind the
    ///   newest seen frame, bounding memory.
    /// - Discards any P-frame fragment that arrives before the first keyframe
    ///   has been completed (a decoder cannot use P-frames without a reference).
    /// - Detects gaps in the completed-frame sequence and flags that a keyframe
    ///   should be requested.
    ///
    /// Not thread-safe by itself; ``FrameLink`` confines it to its receive
    /// queue.
    public final class Reassembler {
        /// How many distinct frameIDs of partial state to keep before evicting
        /// the oldest. Also the out-of-order tolerance window.
        public let windowSize: Int

        private struct Partial {
            let count: UInt16
            let isKeyFrame: Bool
            var fragments: [UInt16: Data]
        }

        private var partials: [UInt32: Partial] = [:]
        /// Highest frameID we have ever observed a fragment for.
        private var highestSeenFrameID: UInt32?
        /// frameID of the last access unit we successfully completed.
        private var lastCompletedFrameID: UInt32?
        /// True once at least one keyframe access unit has been completed.
        private var hasKeyframe = false

        public init(windowSize: Int = 30) {
            self.windowSize = max(1, windowSize)
        }

        /// Result of ingesting one datagram.
        public struct Ingest {
            /// A fully reassembled access unit, if this datagram completed one.
            public let sample: VideoSample?
            /// True when the reassembler observed a sequence gap (lost or
            /// evicted frame) and recommends requesting a fresh keyframe.
            public let needsKeyframe: Bool
        }

        /// Resets all state. Call when the configuration changes (new stream).
        public func reset() {
            partials.removeAll()
            highestSeenFrameID = nil
            lastCompletedFrameID = nil
            hasKeyframe = false
        }

        /// Ingests one raw UDP datagram. Returns the completed sample (if any)
        /// and whether a keyframe should now be requested.
        public func ingest(_ datagram: Data) -> Ingest {
            guard let fragment = FrameProtocol.parseFragment(datagram) else {
                return Ingest(sample: nil, needsKeyframe: false)
            }
            return ingest(fragment)
        }

        /// Fragment-level ingest, useful for tests.
        public func ingest(_ fragment: Fragment) -> Ingest {
            // Discard P-frame fragments that arrive before we have any keyframe;
            // a decoder cannot use them and they would only waste memory.
            if !fragment.isKeyFrame, !hasKeyframe {
                return Ingest(sample: nil, needsKeyframe: false)
            }

            // Ignore fragments for a frame we have already completed/passed.
            if let last = lastCompletedFrameID,
               isOlderOrEqual(fragment.frameID, last) {
                return Ingest(sample: nil, needsKeyframe: false)
            }

            var needsKeyframe = false
            if let highest = highestSeenFrameID {
                if isNewer(fragment.frameID, highest) {
                    highestSeenFrameID = fragment.frameID
                }
            } else {
                highestSeenFrameID = fragment.frameID
            }

            // Accumulate.
            if var partial = partials[fragment.frameID] {
                // Dedup: ignore a fragment index we already hold.
                if partial.fragments[fragment.index] == nil {
                    partial.fragments[fragment.index] = fragment.payload
                    partials[fragment.frameID] = partial
                }
            } else {
                partials[fragment.frameID] = Partial(
                    count: fragment.count,
                    isKeyFrame: fragment.isKeyFrame,
                    fragments: [fragment.index: fragment.payload]
                )
            }

            // Evict frames that fall outside the window; their loss is a gap.
            if evictStalePartials() {
                needsKeyframe = true
            }

            // Try to complete the frame this fragment belongs to.
            var completed: VideoSample?
            if let partial = partials[fragment.frameID],
               partial.fragments.count == Int(partial.count) {
                let data = assemble(partial)
                completed = VideoSample(
                    frameID: fragment.frameID,
                    isKeyFrame: partial.isKeyFrame,
                    data: data
                )
                partials.removeValue(forKey: fragment.frameID)

                if partial.isKeyFrame {
                    hasKeyframe = true
                }

                // Gap detection on the completed-frame sequence: if the new
                // completed frameID is not exactly one past the last completed,
                // we lost at least one frame in between.
                if !partial.isKeyFrame,
                   let last = lastCompletedFrameID,
                   fragment.frameID != last &+ 1 {
                    needsKeyframe = true
                }

                lastCompletedFrameID = fragment.frameID
            }

            return Ingest(sample: completed, needsKeyframe: needsKeyframe)
        }

        private func assemble(_ partial: Partial) -> Data {
            var data = Data()
            for index in 0 ..< partial.count {
                if let chunk = partial.fragments[index] {
                    data.append(chunk)
                }
            }
            return data
        }

        /// Drops partial frames older than ``windowSize`` behind the newest
        /// fragment seen. Returns true if any incomplete frame was evicted
        /// (i.e. permanently lost), which is a gap worth a keyframe.
        private func evictStalePartials() -> Bool {
            guard let highest = highestSeenFrameID, highest >= UInt32(windowSize) else {
                return false
            }
            // Frames more than windowSize behind the newest are unrecoverable.
            let cutoff = highest - UInt32(windowSize)
            var evicted = false
            for frameID in partials.keys where frameID < cutoff {
                partials.removeValue(forKey: frameID)
                evicted = true
            }
            return evicted
        }

        // Monotonic comparisons that tolerate the (very distant) UInt32 wrap.
        private func isNewer(_ a: UInt32, _ b: UInt32) -> Bool {
            a &- b < UInt32(1) << 31 && a != b
        }

        private func isOlderOrEqual(_ a: UInt32, _ b: UInt32) -> Bool {
            !isNewer(a, b)
        }
    }

    // MARK: - Byte helpers

    private static func slice(_ data: Data, _ start: Int, _ end: Int) -> Data {
        data.subdata(in: (data.startIndex + start) ..< (data.startIndex + end))
    }

    private static func appendUInt16(_ value: UInt16, to data: inout Data) {
        var bigEndian = value.bigEndian
        data.append(Data(bytes: &bigEndian, count: MemoryLayout<UInt16>.size))
    }

    private static func appendUInt32(_ value: UInt32, to data: inout Data) {
        var bigEndian = value.bigEndian
        data.append(Data(bytes: &bigEndian, count: MemoryLayout<UInt32>.size))
    }

    private static func appendUInt64(_ value: UInt64, to data: inout Data) {
        var bigEndian = value.bigEndian
        data.append(Data(bytes: &bigEndian, count: MemoryLayout<UInt64>.size))
    }

    private static func readUInt16(from data: Data, offset: Int) -> UInt16 {
        data.dropFirst(offset).prefix(2).reduce(UInt16(0)) {
            ($0 << 8) | UInt16($1)
        }
    }

    private static func readUInt32(from data: Data, offset: Int) -> UInt32 {
        data.dropFirst(offset).prefix(4).reduce(UInt32(0)) {
            ($0 << 8) | UInt32($1)
        }
    }

    private static func readUInt64(from data: Data, offset: Int) -> UInt64 {
        data.dropFirst(offset).prefix(8).reduce(UInt64(0)) {
            ($0 << 8) | UInt64($1)
        }
    }
}
