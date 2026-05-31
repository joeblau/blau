import AVFoundation
import CoreMedia
import SwiftUI
import UIKit

/// Receives H.264 media packets from Pilot over the ``FrameReceiver`` channel
/// and forwards them to an `AVSampleBufferDisplayLayer` for low-latency render.
@MainActor
@Observable
final class MirrorModel {
    private(set) var statusText = "Idle"
    private(set) var annotationStatusText = "Annotation idle"
    private(set) var frameCount = 0
    private(set) var videoSize: CGSize = .zero

    private var lastSentAnnotationSeq: UInt32 = 0

    private let receiver = FrameReceiver()
    private let renderer = H264MirrorRenderer()

    init() {
        receiver.onPacket = { [weak self] packet in
            self?.handle(packet)
        }
        receiver.onFrame = { [weak self] data in
            self?.handleLegacyJPEG(data)
        }
        receiver.onStatusChanged = { [weak self] status in
            Task { @MainActor in
                self?.statusText = status
            }
        }
        receiver.onFrameCountChanged = { [weak self] count in
            Task { @MainActor in
                self?.frameCount = count
            }
        }
    }

    func start() {
        receiver.start()
    }

    func stop() {
        receiver.stop()
    }

    func attach(_ displayLayer: AVSampleBufferDisplayLayer) {
        renderer.attach(displayLayer)
    }

    func sendAnnotation(_ message: AnnotationMessage) {
        lastSentAnnotationSeq &+= 1
        annotationStatusText = "Sending annotations over frame stream"
        receiver.sendAnnotation(message, seq: lastSentAnnotationSeq)
    }

    private func acknowledgeAnnotation(_ seq: UInt32) {
        annotationStatusText = "Pilot received your annotations"
    }

    /// Called on the receiver's internal queue.
    private nonisolated func handle(_ packet: FrameLink.Packet) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            switch packet {
            case .annotationAck(let seq):
                self.acknowledgeAnnotation(seq)
                return
            case .h264Configuration(let config):
                self.videoSize = CGSize(width: config.width, height: config.height)
            default:
                break
            }
            self.renderer.handle(packet)
        }
    }

    /// Compatibility with the original JPEG stream. New Pilot builds send
    /// H.264 packets, so this path only updates diagnostics.
    private nonisolated func handleLegacyJPEG(_ data: Data) {
        Task { @MainActor [weak self] in
            guard UIImage(data: data) != nil else { return }
            self?.statusText = "Receiving legacy JPEG frames"
        }
    }
}

@MainActor
private final class H264MirrorRenderer {
    private weak var displayLayer: AVSampleBufferDisplayLayer?
    private var formatDescription: CMVideoFormatDescription?
    private var sampleIndex: Int64 = 0

    func attach(_ displayLayer: AVSampleBufferDisplayLayer) {
        self.displayLayer = displayLayer
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = UIColor.black.cgColor
        displayLayer.preventsDisplaySleepDuringVideoPlayback = true
    }

    func handle(_ packet: FrameLink.Packet) {
        switch packet {
        case .h264Configuration(let config):
            formatDescription = Self.makeFormatDescription(from: config)
            sampleIndex = 0
            displayLayer?.flushAndRemoveImage()
        case .h264Sample(let sample):
            enqueue(sample)
        case .annotation:
            break
        case .annotationAck:
            break
        case .jpeg:
            break
        }
    }

    private func enqueue(_ sample: FrameLink.H264Sample) {
        guard let displayLayer,
              let sampleBuffer = makeSampleBuffer(from: sample) else { return }

        if displayLayer.status == .failed {
            displayLayer.flush()
        }

        guard displayLayer.isReadyForMoreMediaData else { return }
        displayLayer.enqueue(sampleBuffer)
    }

    private func makeSampleBuffer(from sample: FrameLink.H264Sample) -> CMSampleBuffer? {
        guard let formatDescription else { return nil }

        var blockBuffer: CMBlockBuffer?
        let blockStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: sample.data.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: sample.data.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard blockStatus == kCMBlockBufferNoErr, let blockBuffer else { return nil }

        let copyStatus = sample.data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return kCMBlockBufferNoErr }
            return CMBlockBufferReplaceDataBytes(
                with: baseAddress,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: sample.data.count
            )
        }
        guard copyStatus == kCMBlockBufferNoErr else { return nil }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: CMTime(value: sampleIndex, timescale: 30),
            decodeTimeStamp: .invalid
        )
        var sampleSize = sample.data.count
        var sampleBuffer: CMSampleBuffer?
        let sampleStatus = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard sampleStatus == noErr, let sampleBuffer else { return nil }

        sampleIndex += 1
        Self.setDisplayImmediatelyAttachment(on: sampleBuffer, isKeyFrame: sample.isKeyFrame)
        return sampleBuffer
    }

    private static func makeFormatDescription(from config: FrameLink.H264Configuration) -> CMVideoFormatDescription? {
        config.sps.withUnsafeBytes { spsRawBuffer in
            config.pps.withUnsafeBytes { ppsRawBuffer in
                guard let spsBaseAddress = spsRawBuffer.bindMemory(to: UInt8.self).baseAddress,
                      let ppsBaseAddress = ppsRawBuffer.bindMemory(to: UInt8.self).baseAddress else {
                    return nil
                }

                let parameterSetPointers = [spsBaseAddress, ppsBaseAddress]
                let parameterSetSizes = [config.sps.count, config.pps.count]
                var formatDescription: CMVideoFormatDescription?
                let status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: 2,
                    parameterSetPointers: parameterSetPointers,
                    parameterSetSizes: parameterSetSizes,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &formatDescription
                )

                return status == noErr ? formatDescription : nil
            }
        }
    }

    private static func setDisplayImmediatelyAttachment(on sampleBuffer: CMSampleBuffer, isKeyFrame: Bool) {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: true
        ) else { return }

        let attachment = unsafeBitCast(
            CFArrayGetValueAtIndex(attachments, 0),
            to: CFMutableDictionary.self
        )
        CFDictionarySetValue(
            attachment,
            Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
            Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
        )

        if !isKeyFrame {
            CFDictionarySetValue(
                attachment,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
            )
        }
    }
}
