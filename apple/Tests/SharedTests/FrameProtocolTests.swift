import Foundation
import XCTest

@testable import Copilot

/// Unit tests for the pure, socket-free ``FrameProtocol`` value layer:
/// packet roundtrips, HEVC configuration preservation, UDP fragmentation, and
/// the loss/reorder/dedup behaviour of the reassembler.
final class FrameProtocolTests: XCTestCase {

    // MARK: - Helpers

    private func roundtrip(_ packet: FrameProtocol.Packet) -> FrameProtocol.Packet? {
        FrameProtocol.decode(FrameProtocol.encode(packet))
    }

    private func data(_ bytes: [UInt8]) -> Data { Data(bytes) }

    private func makeSample(id: UInt32, key: Bool, length: Int) -> FrameProtocol.VideoSample {
        var bytes = [UInt8]()
        bytes.reserveCapacity(length)
        for i in 0 ..< length {
            bytes.append(UInt8((Int(id) &+ i) & 0xFF))
        }
        return FrameProtocol.VideoSample(frameID: id, isKeyFrame: key, data: Data(bytes))
    }

    // MARK: - Packet roundtrips

    func testConfigurationRoundtripPreservesVpsSpsPps() {
        let config = FrameProtocol.VideoConfiguration(
            width: 3840,
            height: 2160,
            chroma: .yuv444,
            vps: data([0xAA, 0xBB]),
            sps: data([0x01, 0x02, 0x03]),
            pps: data([0x09])
        )
        guard case .configuration(let decoded)? = roundtrip(.configuration(config)) else {
            return XCTFail("expected configuration")
        }
        XCTAssertEqual(decoded.width, 3840)
        XCTAssertEqual(decoded.height, 2160)
        XCTAssertEqual(decoded.chroma, .yuv444)
        XCTAssertEqual(decoded.vps, data([0xAA, 0xBB]))
        XCTAssertEqual(decoded.sps, data([0x01, 0x02, 0x03]))
        XCTAssertEqual(decoded.pps, data([0x09]))
    }

    func testConfigurationChroma420Roundtrips() {
        let config = FrameProtocol.VideoConfiguration(
            width: 1920, height: 1080, chroma: .yuv420,
            vps: data([0x1]), sps: data([0x2]), pps: data([0x3])
        )
        guard case .configuration(let decoded)? = roundtrip(.configuration(config)) else {
            return XCTFail("expected configuration")
        }
        XCTAssertEqual(decoded.chroma, .yuv420)
    }

    func testSampleRoundtripPreservesFrameIDAndKeyFlag() {
        let sample = makeSample(id: 12_345, key: true, length: 64)
        guard case .sample(let decoded)? = roundtrip(.sample(sample)) else {
            return XCTFail("expected sample")
        }
        XCTAssertEqual(decoded.frameID, 12_345)
        XCTAssertTrue(decoded.isKeyFrame)
        XCTAssertEqual(decoded.data, sample.data)
    }

    func testKeyframeRequestRoundtrips() {
        XCTAssertEqual(roundtrip(.keyframeRequest), .keyframeRequest)
    }

    func testLinkFeedbackRoundtrips() {
        let feedback = FrameProtocol.LinkFeedback(lossPct: 3.5, rttMs: 42.25, queueDepth: 7)
        guard case .linkFeedback(let decoded)? = roundtrip(.linkFeedback(feedback)) else {
            return XCTFail("expected linkFeedback")
        }
        XCTAssertEqual(decoded.lossPct, 3.5, accuracy: 0.0001)
        XCTAssertEqual(decoded.rttMs, 42.25, accuracy: 0.0001)
        XCTAssertEqual(decoded.queueDepth, 7)
    }

    func testCapabilityRoundtrips() {
        guard case .capability(let yes)? = roundtrip(.capability(.init(supports444: true))),
              case .capability(let no)? = roundtrip(.capability(.init(supports444: false))) else {
            return XCTFail("expected capability")
        }
        XCTAssertTrue(yes.supports444)
        XCTAssertFalse(no.supports444)
    }

    func testAnnotationRoundtrips() {
        let drawing = AnnotationDrawing(strokes: [
            AnnotationStroke(
                color: AnnotationColor(red: 1, green: 0, blue: 0, alpha: 1),
                width: 4,
                points: [AnnotationPoint(x: 0.1, y: 0.2), AnnotationPoint(x: 0.3, y: 0.4)]
            )
        ])
        guard case .annotation(let seq, let message)? =
                roundtrip(.annotation(seq: 99, message: .replaceDrawing(drawing))) else {
            return XCTFail("expected annotation")
        }
        XCTAssertEqual(seq, 99)
        XCTAssertEqual(message, .replaceDrawing(drawing))
    }

    func testAnnotationAckRoundtrips() {
        guard case .annotationAck(let seq)? = roundtrip(.annotationAck(seq: 4_242)) else {
            return XCTFail("expected annotationAck")
        }
        XCTAssertEqual(seq, 4_242)
    }

    func testLegacyJpegPayloadDecodesAsJpeg() {
        // A raw blob whose first byte is not a known tag is treated as legacy
        // JPEG. 0xFF (JPEG SOI marker start) is well outside our tag range.
        let blob = data([0xFF, 0xD8, 0xFF, 0xE0, 0x00])
        guard case .jpeg(let decoded)? = FrameProtocol.decode(blob) else {
            return XCTFail("expected jpeg")
        }
        XCTAssertEqual(decoded, blob)
    }

    func testEmptyPayloadDecodesToNil() {
        XCTAssertNil(FrameProtocol.decode(Data()))
    }

    // MARK: - Fragmentation

    func testLargeFrameFragmentsIntoMultipleDatagrams() {
        let length = FrameProtocol.maxFragmentPayload * 2 + 100
        let sample = makeSample(id: 5, key: false, length: length)
        let datagrams = FrameProtocol.fragment(sample: sample)
        XCTAssertEqual(datagrams.count, 3)
        for datagram in datagrams {
            let payload = datagram.count - FrameProtocol.fragmentHeaderSize
            XCTAssertLessThanOrEqual(payload, FrameProtocol.maxFragmentPayload)
        }
    }

    func testSmallFrameProducesSingleDatagram() {
        let sample = makeSample(id: 1, key: true, length: 10)
        XCTAssertEqual(FrameProtocol.fragment(sample: sample).count, 1)
    }

    func testInOrderReassemblyReconstructsSample() {
        let sample = makeSample(id: 1, key: true, length: FrameProtocol.maxFragmentPayload * 2 + 7)
        let reassembler = FrameProtocol.Reassembler()
        var completed: FrameProtocol.VideoSample?
        for datagram in FrameProtocol.fragment(sample: sample) {
            if let s = reassembler.ingest(datagram).sample { completed = s }
        }
        XCTAssertEqual(completed?.data, sample.data)
        XCTAssertEqual(completed?.frameID, 1)
        XCTAssertTrue(completed?.isKeyFrame ?? false)
    }

    func testOutOfOrderFragmentsStillReassemble() {
        let sample = makeSample(id: 7, key: true, length: FrameProtocol.maxFragmentPayload * 3 + 1)
        let datagrams = FrameProtocol.fragment(sample: sample).reversed()
        let reassembler = FrameProtocol.Reassembler()
        var completed: FrameProtocol.VideoSample?
        for datagram in datagrams {
            if let s = reassembler.ingest(datagram).sample { completed = s }
        }
        XCTAssertEqual(completed?.data, sample.data)
    }

    func testMissingFragmentNeverCompletesAndGapIsFlaggedLater() {
        // Keyframe 0 completes; P-frame 1 loses a fragment and never completes;
        // P-frame 2 completes -> gap (frame 1 missing) should be flagged.
        let reassembler = FrameProtocol.Reassembler()

        let key = makeSample(id: 0, key: true, length: 10)
        XCTAssertNotNil(reassembler.ingest(FrameProtocol.fragment(sample: key)[0]).sample)

        let lossy = makeSample(id: 1, key: false, length: FrameProtocol.maxFragmentPayload * 2 + 5)
        let lossyDatagrams = FrameProtocol.fragment(sample: lossy)
        // Deliver only the first fragment of frame 1; it can never complete.
        XCTAssertNil(reassembler.ingest(lossyDatagrams[0]).sample)

        let next = makeSample(id: 2, key: false, length: 10)
        let result = reassembler.ingest(FrameProtocol.fragment(sample: next)[0])
        XCTAssertNotNil(result.sample)
        XCTAssertTrue(result.needsKeyframe, "non-contiguous completed frame should flag a gap")
    }

    func testDuplicateDatagramIsIgnored() {
        let sample = makeSample(id: 3, key: true, length: FrameProtocol.maxFragmentPayload + 50)
        let datagrams = FrameProtocol.fragment(sample: sample)
        XCTAssertEqual(datagrams.count, 2)
        let reassembler = FrameProtocol.Reassembler()

        // Feed fragment 0 twice, then fragment 1. The duplicate must not
        // prematurely "complete" the frame nor corrupt the assembled data.
        XCTAssertNil(reassembler.ingest(datagrams[0]).sample)
        XCTAssertNil(reassembler.ingest(datagrams[0]).sample)
        let completed = reassembler.ingest(datagrams[1]).sample
        XCTAssertEqual(completed?.data, sample.data)
    }

    func testPFrameBeforeAnyKeyframeIsDiscarded() {
        let reassembler = FrameProtocol.Reassembler()
        let pframe = makeSample(id: 0, key: false, length: 10)
        let result = reassembler.ingest(FrameProtocol.fragment(sample: pframe)[0])
        XCTAssertNil(result.sample, "P-frame arriving before any keyframe must be dropped")

        // Once a keyframe arrives and completes, later P-frames flow normally.
        let key = makeSample(id: 1, key: true, length: 10)
        XCTAssertNotNil(reassembler.ingest(FrameProtocol.fragment(sample: key)[0]).sample)
        let p2 = makeSample(id: 2, key: false, length: 10)
        XCTAssertNotNil(reassembler.ingest(FrameProtocol.fragment(sample: p2)[0]).sample)
    }

    func testStalePartialEvictedBeyondWindowFlagsKeyframe() {
        let reassembler = FrameProtocol.Reassembler(windowSize: 4)
        // Complete a keyframe so P-frames are accepted.
        let key = makeSample(id: 0, key: true, length: 10)
        XCTAssertNotNil(reassembler.ingest(FrameProtocol.fragment(sample: key)[0]).sample)

        // Start (but never finish) frame 1 with a multi-fragment sample.
        let stuck = makeSample(id: 1, key: false, length: FrameProtocol.maxFragmentPayload * 2 + 1)
        XCTAssertNil(reassembler.ingest(FrameProtocol.fragment(sample: stuck)[0]).sample)

        // Advance well past the window with a far-future single-fragment frame.
        // Frame 1 is now older than windowSize behind and must be evicted,
        // which flags a keyframe request.
        let future = makeSample(id: 20, key: false, length: 10)
        let result = reassembler.ingest(FrameProtocol.fragment(sample: future)[0])
        XCTAssertTrue(result.needsKeyframe)
    }
}
