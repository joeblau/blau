import Foundation
import ScreenCaptureKit
import CoreMedia
import CoreVideo
import VideoToolbox

/// Captures Pilot's own main window with ScreenCaptureKit, encodes each frame
/// to H.264 off the main thread, and hands it to a ``FrameSender`` for delivery
/// to the Plotter (iPad) app.
@MainActor
@Observable
final class ScreenMirror {
    /// True once a capture stream is actively running.
    private(set) var isRunning = false

    private let sender: FrameSender
    private var stream: SCStream?
    /// Non-isolated handler that owns the SCStream delegate + output callbacks,
    /// which the framework requires to run off the main actor.
    private let output: StreamOutput
    private let outputQueue = DispatchQueue(label: "app.blau.screenmirror.output")

    /// Target width in pixels; the stream downscales to this and `scalesToFit`
    /// preserves aspect ratio for the height.
    private let targetWidth = 1920

    init(sender: FrameSender) {
        self.sender = sender
        self.output = StreamOutput(sender: sender)
        self.output.onStop = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.isRunning = false
                self.stream = nil
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                self.start()
            }
        }
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        Task { await self.beginCapture() }
    }

    func stop() {
        isRunning = false
        let stream = self.stream
        self.stream = nil
        Task {
            try? await stream?.stopCapture()
        }
    }

    // MARK: - Capture setup

    private func beginCapture() async {
        do {
            // Requesting shareable content implicitly prompts for Screen
            // Recording permission the first time.
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )

            guard let window = pickPilotWindow(from: content.windows) else {
                // No suitable window yet (app may still be launching). Retry.
                isRunning = false
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if !Task.isCancelled { start() }
                return
            }

            let filter = SCContentFilter(desktopIndependentWindow: window)

            let config = SCStreamConfiguration()
            let frame = window.frame
            let aspect = frame.height > 0 ? frame.width / frame.height : 16.0 / 9.0
            let width = targetWidth
            let height = max(1, Int((Double(width) / aspect).rounded()))
            config.width = width
            config.height = height
            config.scalesToFit = true
            config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
            config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            config.showsCursor = true
            config.queueDepth = 3

            let stream = SCStream(filter: filter, configuration: config, delegate: output)
            try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: outputQueue)
            try await stream.startCapture()
            self.stream = stream
        } catch {
            isRunning = false
            // Permission denied or transient failure — retry after a delay.
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if !Task.isCancelled { start() }
        }
    }

    /// Picks the SCWindow belonging to Pilot itself. Prefers an exact bundle
    /// identifier match; falls back to the app's frontmost on-screen window.
    private func pickPilotWindow(from windows: [SCWindow]) -> SCWindow? {
        let bundleID = Bundle.main.bundleIdentifier

        let ownWindows = windows.filter { window in
            guard window.isOnScreen, window.frame.width > 1, window.frame.height > 1 else {
                return false
            }
            return window.owningApplication?.bundleIdentifier == bundleID
        }

        // Prefer a titled, layer-0 (normal) window; otherwise the largest one.
        if let titled = ownWindows
            .filter({ ($0.title?.isEmpty == false) && $0.windowLayer == 0 })
            .max(by: { $0.frame.area < $1.frame.area }) {
            return titled
        }

        return ownWindows.max(by: { $0.frame.area < $1.frame.area })
    }
}

// MARK: - Stream output handler

/// Off-main-actor object that receives SCStream frames, encodes them to H.264,
/// and forwards them to the ``FrameSender``. Kept separate from
/// ``ScreenMirror`` because ScreenCaptureKit requires `nonisolated` delegate
/// conformances, which a `@MainActor` type cannot provide.
fileprivate final class StreamOutput: NSObject, SCStreamDelegate, SCStreamOutput, @unchecked Sendable {
    private let sender: FrameSender
    private var compressionSession: VTCompressionSession?
    private var encodedWidth = 0
    private var encodedHeight = 0
    private var frameIndex: Int64 = 0

    /// Invoked when the stream stops unexpectedly so the owner can recover.
    var onStop: (() -> Void)?

    init(sender: FrameSender) {
        self.sender = sender
        super.init()
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onStop?()
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .screen,
              sampleBuffer.isValid,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        // Only forward complete, displayed frames.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
           let statusRaw = attachments.first?[.status] as? Int,
           let status = SCFrameStatus(rawValue: statusRaw),
           status != .complete {
            return
        }

        encode(pixelBuffer, presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
    }

    private func encode(_ pixelBuffer: CVPixelBuffer, presentationTimeStamp: CMTime) {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        if compressionSession == nil || encodedWidth != width || encodedHeight != height {
            resetCompressionSession(width: width, height: height)
        }

        guard let compressionSession else { return }
        let pts = presentationTimeStamp.isValid
            ? presentationTimeStamp
            : CMTime(value: frameIndex, timescale: 30)
        frameIndex += 1

        VTCompressionSessionEncodeFrame(
            compressionSession,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: pts,
            duration: CMTime(value: 1, timescale: 30),
            frameProperties: nil,
            sourceFrameRefcon: nil,
            infoFlagsOut: nil
        )
    }

    private func resetCompressionSession(width: Int, height: Int) {
        if let compressionSession {
            VTCompressionSessionCompleteFrames(compressionSession, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(compressionSession)
        }

        compressionSession = nil
        encodedWidth = width
        encodedHeight = height
        frameIndex = 0

        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(width),
            height: Int32(height),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: screenMirrorCompressionOutputCallback,
            refcon: Unmanaged.passUnretained(self).toOpaque(),
            compressionSessionOut: &session
        )
        guard status == noErr, let session else { return }

        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_Baseline_AutoLevel)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: 30 as CFTypeRef)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: 8_000_000 as CFTypeRef)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: 60 as CFTypeRef)
        VTCompressionSessionPrepareToEncodeFrames(session)

        compressionSession = session
    }

    fileprivate func handleEncodedSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard let data = Self.copySampleData(from: sampleBuffer) else { return }

        let keyFrame = Self.isKeyFrame(sampleBuffer)
        if keyFrame,
           let config = Self.h264Configuration(from: sampleBuffer) {
            sender.send(.h264Configuration(config))
        }

        sender.send(.h264Sample(FrameLink.H264Sample(data: data, isKeyFrame: keyFrame)))
    }

    private static func isKeyFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: false
        ) as? [[CFString: Any]],
            let first = attachments.first else {
            return true
        }

        return !(first[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
    }

    private static func h264Configuration(from sampleBuffer: CMSampleBuffer) -> FrameLink.H264Configuration? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            return nil
        }

        var spsPointer: UnsafePointer<UInt8>?
        var ppsPointer: UnsafePointer<UInt8>?
        var spsSize = 0
        var ppsSize = 0
        var parameterSetCount = 0
        var nalUnitHeaderLength: Int32 = 0

        let spsStatus = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            formatDescription,
            parameterSetIndex: 0,
            parameterSetPointerOut: &spsPointer,
            parameterSetSizeOut: &spsSize,
            parameterSetCountOut: &parameterSetCount,
            nalUnitHeaderLengthOut: &nalUnitHeaderLength
        )
        let ppsStatus = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            formatDescription,
            parameterSetIndex: 1,
            parameterSetPointerOut: &ppsPointer,
            parameterSetSizeOut: &ppsSize,
            parameterSetCountOut: &parameterSetCount,
            nalUnitHeaderLengthOut: &nalUnitHeaderLength
        )

        guard spsStatus == noErr,
              ppsStatus == noErr,
              let spsPointer,
              let ppsPointer,
              spsSize > 0,
              ppsSize > 0 else { return nil }

        let dimensions = CMVideoFormatDescriptionGetDimensions(formatDescription)
        return FrameLink.H264Configuration(
            width: Int(dimensions.width),
            height: Int(dimensions.height),
            sps: Data(bytes: spsPointer, count: spsSize),
            pps: Data(bytes: ppsPointer, count: ppsSize)
        )
    }

    private static func copySampleData(from sampleBuffer: CMSampleBuffer) -> Data? {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return nil }
        let length = CMBlockBufferGetDataLength(blockBuffer)
        guard length > 0 else { return nil }

        var data = Data(count: length)
        let status = data.withUnsafeMutableBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return kCMBlockBufferNoErr }
            return CMBlockBufferCopyDataBytes(
                blockBuffer,
                atOffset: 0,
                dataLength: length,
                destination: baseAddress
            )
        }

        return status == kCMBlockBufferNoErr ? data : nil
    }
}

private func screenMirrorCompressionOutputCallback(
    outputCallbackRefCon: UnsafeMutableRawPointer?,
    sourceFrameRefCon: UnsafeMutableRawPointer?,
    status: OSStatus,
    infoFlags: VTEncodeInfoFlags,
    sampleBuffer: CMSampleBuffer?
) {
    guard status == noErr,
          let outputCallbackRefCon,
          let sampleBuffer,
          sampleBuffer.isValid else { return }

    let output = Unmanaged<StreamOutput>.fromOpaque(outputCallbackRefCon).takeUnretainedValue()
    output.handleEncodedSampleBuffer(sampleBuffer)
}

private extension CGRect {
    var area: CGFloat { width * height }
}
