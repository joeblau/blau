import Foundation
import XCTest

@testable import Copilot

/// Unit tests for the pure, socket-free ``FrameProtocol`` value layer:
/// packet roundtrips, HEVC configuration preservation, and stream budgets.
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

    func testAppearanceRoundtrips() {
        guard case .appearance(let dark)? = roundtrip(.appearance(isDark: true)),
              case .appearance(let light)? = roundtrip(.appearance(isDark: false)) else {
            return XCTFail("expected appearance")
        }
        XCTAssertTrue(dark)
        XCTAssertFalse(light)
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

    func testConfigurationRejectsImpossibleDimensionsAndParameterLengths() {
        let oversized = FrameProtocol.VideoConfiguration(
            width: FrameProtocol.maxVideoDimension + 1,
            height: 1080,
            chroma: .yuv420,
            vps: data([1]), sps: data([2]), pps: data([3])
        )
        XCTAssertTrue(FrameProtocol.encode(.configuration(oversized)).isEmpty)

        var malformed = Data([1, 0])
        appendUInt32(1_920, to: &malformed)
        appendUInt32(1_080, to: &malformed)
        appendUInt32(UInt32.max, to: &malformed)
        appendUInt32(UInt32.max, to: &malformed)
        appendUInt32(UInt32.max, to: &malformed)
        XCTAssertNil(FrameProtocol.decode(malformed), "length arithmetic must not overflow")
    }

    func testLengthPrefixedDecoderRejectsImpossiblePrefixImmediately() {
        var decoder = FrameLink.StreamDecoder(maxPayloadBytes: 1_024)
        let result = decoder.append(Data([0xFF, 0xFF, 0xFF, 0xFF]))
        XCTAssertEqual(try? result.get(), nil)
        guard case .failure(.invalidLength) = result else {
            return XCTFail("expected invalid-length violation")
        }
        XCTAssertTrue(decoder.buffer.isEmpty)
    }

    func testLengthPrefixedDecoderHandlesBoundariesAndSplitInput() throws {
        var decoder = FrameLink.StreamDecoder(maxPayloadBytes: 8, receiveSlack: 8)
        var packet = Data([0, 0, 0, 8])
        packet.append(Data(repeating: 0xAB, count: 8))
        XCTAssertEqual(try decoder.append(packet.prefix(3)).get(), [])
        let decoded = try decoder.append(packet.dropFirst(3)).get()
        XCTAssertEqual(decoded, [Data(repeating: 0xAB, count: 8)])
    }

    func testLengthPrefixedDecoderCapsBufferedBytes() {
        var decoder = FrameLink.StreamDecoder(maxPayloadBytes: 8, receiveSlack: 4)
        let result = decoder.append(Data(repeating: 0, count: 13))
        guard case .failure(.bufferLimit) = result else {
            return XCTFail("expected buffer-limit violation")
        }
    }

    func testMalformedStreamFuzzNeverExceedsTheConnectionBudget() {
        var seed: UInt64 = 0xB1A0_F00D
        var decoder = FrameLink.StreamDecoder(maxPayloadBytes: 4_096, receiveSlack: 256)
        for _ in 0 ..< 2_000 {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1
            let length = Int(seed % 96)
            var bytes = [UInt8](repeating: 0, count: length)
            for index in bytes.indices {
                seed = seed &* 2_862_933_555_777_941_757 &+ 3_037_000_493
                bytes[index] = UInt8(truncatingIfNeeded: seed >> 24)
            }
            if case .failure = decoder.append(Data(bytes)) {
                decoder.reset()
            }
            XCTAssertLessThanOrEqual(decoder.buffer.count, decoder.maxBufferedBytes)
        }
    }

    private func appendUInt32(_ value: UInt32, to data: inout Data) {
        var bigEndian = value.bigEndian
        data.append(Data(bytes: &bigEndian, count: 4))
    }
}
