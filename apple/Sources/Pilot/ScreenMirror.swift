import Foundation
import ScreenCaptureKit
import CoreMedia
import CoreVideo
import VideoToolbox

/// Captures Pilot's own main window with ScreenCaptureKit, encodes each frame
/// to HEVC off the main thread, and hands it to a ``FrameSender`` for delivery
/// to the Plotter (iPad) app.
///
/// The encoder default-safes to 4:2:0 chroma and only attempts 4:4:4 when the
/// connected receiver advertises support via ``FrameSender/onCapability``. Any
/// failure creating or configuring a 4:4:4 session falls back to 4:2:0 so the
/// stream never crashes the app.
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
    /// preserves aspect ratio for the height. Capped at 4K wide.
    private let targetWidth = 3840
    /// Capture/encode frame rate.
    private let frameRate: Int32 = 60

    /// Pixel format the capture stream is configured with. ScreenCaptureKit has
    /// no native 4:4:4 YCbCr format, so 4:4:4 captures full-colour BGRA (no
    /// chroma subsampling at the source); 4:2:0 uses the lighter bi-planar
    /// video-range format. Capturing 4:2:0 and asking the encoder for 4:4:4 only
    /// upconverts already-subsampled chroma, so the capture format must track the
    /// negotiated chroma for 4:4:4 to mean anything.
    private var captureChroma: FrameProtocol.VideoChroma = .yuv420
    private var captureWidth = 0
    private var captureHeight = 0

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

        // Wire the sender's control callbacks into the encoder. These fire on
        // the FrameSender's private queue; StreamOutput hops to its own
        // serial queue internally where needed.
        sender.onClientConnected = { [weak output] in
            output?.requestForceKeyframe()
        }
        sender.onKeyframeRequested = { [weak output] in
            output?.requestForceKeyframe()
        }
        sender.onLinkFeedback = { [weak output] feedback in
            output?.applyLinkFeedback(feedback)
        }
        sender.onCapability = { [weak self, weak output] capability in
            output?.applyCapability(capability)
            Task { @MainActor in
                self?.applyCaptureChroma(capability.supports444 ? .yuv444 : .yuv420)
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

            let frame = window.frame
            let aspect = frame.height > 0 ? frame.width / frame.height : 16.0 / 9.0
            // Capture at native window resolution, capped at 4K wide.
            let nativeWidth = max(1, Int((frame.width).rounded()))
            let width = min(targetWidth, nativeWidth)
            let height = max(1, Int((Double(width) / aspect).rounded()))
            captureWidth = width
            captureHeight = height
            let config = makeConfiguration(width: width, height: height)

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

    /// Builds a capture configuration for the current ``captureChroma``. 4:4:4
    /// captures full-colour BGRA so the 4:4:4 encoder has real chroma to keep;
    /// 4:2:0 uses the lighter bi-planar video-range format.
    private func makeConfiguration(width: Int, height: Int) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        config.scalesToFit = true
        config.minimumFrameInterval = CMTime(value: 1, timescale: frameRate)
        config.pixelFormat = captureChroma == .yuv444
            ? kCVPixelFormatType_32BGRA
            : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.showsCursor = true
        // Shallow queue: fewer buffered frames = lower capture-to-wire latency.
        config.queueDepth = 3
        return config
    }

    /// Re-points the live capture at the pixel format matching the chroma the
    /// receiver negotiated. Without this, a 4:4:4 encode would only ever see
    /// 4:2:0-subsampled capture buffers and could not recover colour detail
    /// (crisp terminal/code text). The encoder recreates its session on the next
    /// frame because its `requestedChroma` changed, emitting a fresh keyframe.
    func applyCaptureChroma(_ chroma: FrameProtocol.VideoChroma) {
        guard chroma != captureChroma else { return }
        captureChroma = chroma
        guard isRunning, let stream, captureWidth > 0 else { return }
        let config = makeConfiguration(width: captureWidth, height: captureHeight)
        Task {
            do {
                try await stream.updateConfiguration(config)
            } catch {
                frameLinkLog.error("ScreenMirror: failed to switch capture pixel format: \(error.localizedDescription, privacy: .public)")
            }
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

/// Off-main-actor object that receives SCStream frames, encodes them to HEVC,
/// and forwards them to the ``FrameSender``. Kept separate from
/// ``ScreenMirror`` because ScreenCaptureKit requires `nonisolated` delegate
/// conformances, which a `@MainActor` type cannot provide.
///
/// All encoder state (the `VTCompressionSession`, chroma mode, bitrate,
/// force-keyframe latch, and frame counter) is confined to ``stateQueue`` so
/// the SCStream output callback and the FrameSender control callbacks can poke
/// it from different threads safely.
fileprivate final class StreamOutput: NSObject, SCStreamDelegate, SCStreamOutput, @unchecked Sendable {
    private let sender: FrameSender

    /// Serializes all mutable encoder state.
    private let stateQueue = DispatchQueue(label: "app.blau.screenmirror.state")

    private var compressionSession: VTCompressionSession?
    private var encodedWidth = 0
    private var encodedHeight = 0
    /// Monotonic ID stamped on every emitted ``FrameProtocol/VideoSample``.
    private var frameID: UInt32 = 0
    /// presentationTimeStamp fallback counter.
    private var ptsIndex: Int64 = 0

    /// Chroma the receiver is known to support. Defaults to safe 4:2:0; only
    /// becomes `.yuv444` after a capability handshake advertising support.
    private var requestedChroma: FrameProtocol.VideoChroma = .yuv420
    /// Chroma the *current* session was actually created with. Drives the
    /// configuration packet and dictates whether we must recreate the session
    /// when `requestedChroma` changes.
    private var activeChroma: FrameProtocol.VideoChroma = .yuv420

    /// Set when a keyframe must be forced on the next encoded frame (new
    /// client connected, or a keyframe was explicitly requested).
    private var forceKeyframe = false

    // Adaptive bitrate. Start conservative; ramp up when loss is low. Floor is
    // kept high so terminal/code text stays crisp.
    private static let minBitrate = 12_000_000
    private static let maxBitrate = 35_000_000
    private static let startBitrate = 11_000_000
    private var currentBitrate = StreamOutput.startBitrate
    /// Throttles bitrate changes so we don't thrash the encoder on every report.
    private var lastBitrateChange: TimeInterval = 0

    private let frameRate: Int32 = 60
    /// ~2 seconds at 60fps.
    private let maxKeyFrameInterval = 120

    /// Invoked when the stream stops unexpectedly so the owner can recover.
    var onStop: (() -> Void)?

    init(sender: FrameSender) {
        self.sender = sender
        super.init()
    }

    // MARK: - Control hooks (called from FrameSender's queue)

    /// Request a forced keyframe on the next encoded frame.
    func requestForceKeyframe() {
        stateQueue.async { [weak self] in
            self?.forceKeyframe = true
        }
    }

    /// Switch to 4:4:4 when the receiver supports it, otherwise stay/return to
    /// 4:2:0. The session is recreated lazily on the next encode if the active
    /// chroma no longer matches.
    func applyCapability(_ capability: FrameProtocol.Capability) {
        stateQueue.async { [weak self] in
            guard let self else { return }
            self.requestedChroma = capability.supports444 ? .yuv444 : .yuv420
        }
    }

    /// Adaptive bitrate controller. Steps `AverageBitRate` with hysteresis
    /// based on the receiver's reported loss / queue depth.
    func applyLinkFeedback(_ feedback: FrameProtocol.LinkFeedback) {
        stateQueue.async { [weak self] in
            self?.adjustBitrateLocked(for: feedback)
        }
    }

    // MARK: - SCStream delegate / output

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

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        stateQueue.async { [weak self] in
            self?.encodeLocked(pixelBuffer, presentationTimeStamp: pts)
        }
    }

    // MARK: - Encode (always on `stateQueue`)

    private func encodeLocked(_ pixelBuffer: CVPixelBuffer, presentationTimeStamp: CMTime) {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        if compressionSession == nil
            || encodedWidth != width
            || encodedHeight != height
            || activeChroma != requestedChroma {
            resetCompressionSessionLocked(width: width, height: height)
        }

        guard let compressionSession else { return }

        let pts = presentationTimeStamp.isValid
            ? presentationTimeStamp
            : CMTime(value: ptsIndex, timescale: frameRate)
        ptsIndex += 1

        var frameProperties: CFDictionary?
        if forceKeyframe {
            forceKeyframe = false
            frameProperties = [
                kVTEncodeFrameOptionKey_ForceKeyFrame as String: true
            ] as CFDictionary
        }

        VTCompressionSessionEncodeFrame(
            compressionSession,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: pts,
            duration: CMTime(value: 1, timescale: frameRate),
            frameProperties: frameProperties,
            sourceFrameRefcon: nil,
            infoFlagsOut: nil
        )
    }

    private func resetCompressionSessionLocked(width: Int, height: Int) {
        if let compressionSession {
            VTCompressionSessionCompleteFrames(compressionSession, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(compressionSession)
        }

        compressionSession = nil
        encodedWidth = width
        encodedHeight = height
        ptsIndex = 0

        // Try the requested chroma first; on any failure, default-safe to 4:2:0.
        if requestedChroma == .yuv444 {
            if let session = makeSessionLocked(width: width, height: height, chroma: .yuv444) {
                compressionSession = session
                activeChroma = .yuv444
                return
            }
            frameLinkLog.error("ScreenMirror: 4:4:4 HEVC session unavailable; falling back to 4:2:0")
        }

        if let session = makeSessionLocked(width: width, height: height, chroma: .yuv420) {
            compressionSession = session
            activeChroma = .yuv420
        } else {
            frameLinkLog.error("ScreenMirror: failed to create HEVC compression session")
        }
    }

    /// Creates and fully configures an HEVC ``VTCompressionSession`` for the
    /// given chroma, or returns `nil` if creation or any required property set
    /// fails (so the caller can fall back).
    private func makeSessionLocked(
        width: Int,
        height: Int,
        chroma: FrameProtocol.VideoChroma
    ) -> VTCompressionSession? {
        // 4:4:4 captures full-colour BGRA (see ScreenMirror.makeConfiguration),
        // so VideoToolbox has real chroma to preserve. We request a bi-planar
        // 4:4:4 video-range working format so the encoder keeps full chroma
        // instead of subsampling. 4:2:0 uses the capture format directly.
        var imageBufferAttributes: CFDictionary?
        if chroma == .yuv444 {
            let pixelFormat = kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange
            imageBufferAttributes = [
                kCVPixelBufferPixelFormatTypeKey as String: pixelFormat
            ] as CFDictionary
        }

        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(width),
            height: Int32(height),
            codecType: kCMVideoCodecType_HEVC,
            encoderSpecification: nil,
            imageBufferAttributes: imageBufferAttributes,
            compressedDataAllocator: nil,
            outputCallback: screenMirrorCompressionOutputCallback,
            refcon: Unmanaged.passUnretained(self).toOpaque(),
            compressionSessionOut: &session
        )
        guard status == noErr, let session else { return nil }

        // Any property failure invalidates the session and bails so the caller
        // can recreate in the safe 4:2:0 path.
        func set(_ key: CFString, _ value: CFTypeRef) -> Bool {
            VTSessionSetProperty(session, key: key, value: value) == noErr
        }

        var ok = set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
            && set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
            && set(kVTCompressionPropertyKey_ExpectedFrameRate, frameRate as CFNumber)
            && set(kVTCompressionPropertyKey_AverageBitRate, currentBitrate as CFNumber)
            && set(kVTCompressionPropertyKey_MaxKeyFrameInterval, maxKeyFrameInterval as CFNumber)

        // Pin the profile only for the safe 4:2:0 path. There is no public
        // HEVC 4:4:4 (Rext) profile-level constant, so for 4:4:4 we let
        // VideoToolbox derive the profile from the 4:4:4 source format; pinning
        // Main here would force chroma subsampling and defeat the purpose.
        if chroma == .yuv420 {
            ok = ok && set(kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_HEVC_Main_AutoLevel)
        }

        guard ok else {
            VTCompressionSessionInvalidate(session)
            return nil
        }

        VTCompressionSessionPrepareToEncodeFrames(session)
        return session
    }

    // MARK: - Adaptive bitrate (always on `stateQueue`)

    private func adjustBitrateLocked(for feedback: FrameProtocol.LinkFeedback) {
        let now = Date().timeIntervalSinceReferenceDate
        // Hysteresis: don't restep the bitrate more than ~twice a second.
        guard now - lastBitrateChange >= 0.5 else { return }

        let previous = currentBitrate
        var next = currentBitrate

        // React to loss / deep queues by backing off; ramp up when the link is
        // clean. Steps are coarse to avoid oscillation.
        if feedback.lossPct >= 5.0 || feedback.queueDepth >= 8 {
            next = currentBitrate - 4_000_000
        } else if feedback.lossPct >= 1.0 || feedback.queueDepth >= 4 {
            next = currentBitrate - 2_000_000
        } else if feedback.lossPct < 0.5 && feedback.queueDepth <= 1 {
            next = currentBitrate + 2_000_000
        }

        next = min(Self.maxBitrate, max(Self.minBitrate, next))
        guard next != previous else { return }

        currentBitrate = next
        lastBitrateChange = now
        if let compressionSession {
            VTSessionSetProperty(
                compressionSession,
                key: kVTCompressionPropertyKey_AverageBitRate,
                value: currentBitrate as CFNumber
            )
        }
        frameLinkLog.log("ScreenMirror: bitrate -> \(self.currentBitrate, privacy: .public) bps (loss \(feedback.lossPct, privacy: .public)%, queue \(feedback.queueDepth, privacy: .public))")
    }

    // MARK: - Encoded output (called on VideoToolbox's callback thread)

    fileprivate func handleEncodedSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard let data = Self.copySampleData(from: sampleBuffer) else { return }
        let keyFrame = Self.isKeyFrame(sampleBuffer)

        // Stamp + emit on the state queue so frameID stays monotonic and we
        // read the chroma that this session was actually created with.
        stateQueue.async { [weak self] in
            guard let self else { return }

            if keyFrame,
               let config = Self.videoConfiguration(from: sampleBuffer, chroma: self.activeChroma) {
                self.sender.send(.configuration(config))
            }

            let id = self.frameID
            self.frameID &+= 1
            self.sender.send(.sample(FrameProtocol.VideoSample(
                frameID: id,
                isKeyFrame: keyFrame,
                data: data
            )))
        }
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

    /// Extracts the HEVC VPS + SPS + PPS parameter sets (three sets, unlike
    /// H.264's two) and builds a ``FrameProtocol/VideoConfiguration``.
    private static func videoConfiguration(
        from sampleBuffer: CMSampleBuffer,
        chroma: FrameProtocol.VideoChroma
    ) -> FrameProtocol.VideoConfiguration? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            return nil
        }

        func parameterSet(at index: Int) -> Data? {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            var count = 0
            var nalUnitHeaderLength: Int32 = 0
            let status = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                formatDescription,
                parameterSetIndex: index,
                parameterSetPointerOut: &pointer,
                parameterSetSizeOut: &size,
                parameterSetCountOut: &count,
                nalUnitHeaderLengthOut: &nalUnitHeaderLength
            )
            guard status == noErr, let pointer, size > 0 else { return nil }
            return Data(bytes: pointer, count: size)
        }

        // HEVC parameter sets are ordered VPS (0), SPS (1), PPS (2).
        guard let vps = parameterSet(at: 0),
              let sps = parameterSet(at: 1),
              let pps = parameterSet(at: 2) else { return nil }

        let dimensions = CMVideoFormatDescriptionGetDimensions(formatDescription)
        return FrameProtocol.VideoConfiguration(
            width: Int(dimensions.width),
            height: Int(dimensions.height),
            chroma: chroma,
            vps: vps,
            sps: sps,
            pps: pps
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
