import AVFoundation
import AppKit
import AudioToolbox
import CoreMediaIO
import Foundation
import OSLog
import Observation

enum DeviceConnectionStatus: Sendable, Equatable {
    case waiting
    case connecting
    case streaming
    case failed(String)
}

// DeviceCaptureSession — drives an `AVCaptureSession` that mirrors a
// USB-tethered iPhone, the same way QuickTime's "Movie Recording" does:
// it flips the CMIO `AllowScreenCaptureDevices` switch so the iPhone
// shows up as an external AVCaptureDevice, then attaches video + audio
// inputs and exposes the session for an `AVCaptureVideoPreviewLayer`.
//
// Also exposes record-to-disk and one-shot screenshot, the two QuickTime
// affordances we want next to the preview.
@MainActor
@Observable
final class DeviceCaptureSession: NSObject {
    @ObservationIgnored let session = AVCaptureSession()

    var status: DeviceConnectionStatus = .waiting
    var deviceUniqueID: String?
    var deviceName: String?
    var isRecording: Bool = false
    var lastError: String?
    /// Increments on every successful clipboard write. UI binds `.onChange`
    /// to this to flash a "Copied" toast — counter instead of `Date?` so
    /// back-to-back copies still fire the observation.
    var clipboardCopyCount: Int = 0
    /// Whether the live capture has an audio input wired up, so recordings
    /// include sound. False when no paired audio device was found/added — a
    /// recording then comes out video-only.
    var hasAudioInput: Bool = false
    /// Increments when a recording starts with no audio track, so the UI can
    /// flash a one-time "recording without audio" notice. Counter (not a flag)
    /// so back-to-back silent recordings each fire the observation, same idiom
    /// as `clipboardCopyCount`.
    var recordingWithoutAudioCount: Int = 0

    @ObservationIgnored private let logger = Logger(subsystem: "app.blau.pilot.device", category: "capture")
    @ObservationIgnored private let audioPreview = AVCaptureAudioPreviewOutput()
    @ObservationIgnored private let videoDataOutput = AVCaptureVideoDataOutput()
    @ObservationIgnored private let audioDataOutput = AVCaptureAudioDataOutput()
    @ObservationIgnored private let frameQueue = DispatchQueue(label: "app.blau.pilot.device.frame")
    @ObservationIgnored private let sessionQueue = DispatchQueue(label: "app.blau.pilot.device.capture")
    /// Drives the bounded rescan that catches an already-connected iPhone the
    /// one-shot discovery races against (see `scheduleRescan`).
    @ObservationIgnored private var rescanAttemptsRemaining = 0
    @ObservationIgnored private var rescanActive = false

    /// Grabs one-shot frames (screenshots) and writes recordings to disk via
    /// `AVAssetWriter`. We write the exact frames the session delivers — the
    /// same ones the preview shows — rather than routing through
    /// `AVCaptureMovieFileOutput`, whose output dimensions follow the session
    /// preset. On macOS the preset can't be `.inputPriority` (iOS-only), so a
    /// movie file output bakes a letterboxed 16:9 frame instead of the device's
    /// tall screen; writing the data-output buffers ourselves preserves the
    /// device's real aspect ratio (issue #56).
    @ObservationIgnored private let coordinator = CaptureCoordinator()

    override init() {
        super.init()
        Self.enableScreenCaptureDevices()
        useDeviceNativeFormat()
        audioPreview.volume = 1.0
        videoDataOutput.alwaysDiscardsLateVideoFrames = true
        videoDataOutput.setSampleBufferDelegate(coordinator, queue: frameQueue)
        audioDataOutput.setSampleBufferDelegate(coordinator, queue: frameQueue)
        coordinator.onFinish = { [weak self] url, errorMessage in
            Task { @MainActor in
                self?.recordingDidFinish(url: url, errorMessage: errorMessage)
            }
        }
        observeConnections()
    }

    func start() {
        // The CMIO `AllowScreenCaptureDevices` flag is the toggle that makes
        // QuickTime's iPhone source appear; it's also what surfaces the
        // device list under the camera TCC bucket. We need camera permission
        // before AVFoundation will hand us the device, so prompt up-front.
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    guard granted else {
                        self.status = .failed("Pilot needs camera permission to mirror the iPhone screen.")
                        return
                    }
                    self.attachIfAvailable()
                }
            }
        }
    }

    func stop() {
        if isRecording {
            coordinator.stopRecording()
        }
        detach()
    }

    // MARK: - Recording

    func toggleRecording() {
        guard status == .streaming else { return }
        if isRecording {
            coordinator.stopRecording()
        } else {
            startRecording()
        }
    }

    private func startRecording() {
        guard !isRecording else { return }
        guard videoDataOutput.connection(with: .video) != nil else {
            lastError = "No video stream available to record."
            return
        }
        let url = Self.timestampedURL(folder: "Desktop", name: "iPhone Recording", ext: "mov")
        coordinator.startRecording(to: url)
        isRecording = true
        lastError = nil
        // No paired audio device means the writer has no audio track to fill —
        // surface a one-time notice so the silent recording isn't a surprise.
        if !hasAudioInput {
            recordingWithoutAudioCount += 1
        }
    }

    fileprivate func recordingDidFinish(url: URL, errorMessage: String?) {
        isRecording = false
        if let errorMessage {
            lastError = "Recording failed: \(errorMessage)"
            logger.error("recording failed: \(errorMessage)")
            return
        }
        verifyNativeAspectRatio(of: url)
    }

    // MARK: - Screenshot

    func takeScreenshot() {
        guard status == .streaming else { return }
        Task { [weak self] in
            guard let self else { return }
            guard let cgImage = await self.coordinator.nextFrame() else {
                self.lastError = "Couldn't grab a frame for the screenshot."
                return
            }
            let url = Self.timestampedURL(folder: "Desktop", name: "iPhone Screenshot", ext: "png")
            self.write(cgImage: cgImage, to: url)
        }
    }

    /// Copies a single frame of the live device feed to the general
    /// pasteboard as a PNG-backed `NSImage`, so it pastes into Messages,
    /// Notes, Preview, design tools, etc. Mirrors `takeScreenshot()`
    /// without touching disk.
    func copyScreenshotToClipboard() {
        guard status == .streaming else { return }
        Task { [weak self] in
            guard let self else { return }
            guard let cgImage = await self.coordinator.nextFrame() else {
                self.lastError = "Couldn't grab a frame to copy."
                return
            }
            let image = NSImage(
                cgImage: cgImage,
                size: NSSize(width: cgImage.width, height: cgImage.height)
            )
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            // Write `NSImage` so paste targets that prefer image data get
            // it, and add an explicit PNG representation for clients that
            // ask for raw bytes (Slack, browsers, etc.).
            var wroteAny = pasteboard.writeObjects([image])
            let bitmap = NSBitmapImageRep(cgImage: cgImage)
            if let pngData = bitmap.representation(using: .png, properties: [:]) {
                pasteboard.setData(pngData, forType: .png)
                wroteAny = true
            }
            if !wroteAny {
                self.lastError = "Couldn't put the screenshot on the clipboard."
            } else {
                self.lastError = nil
                self.clipboardCopyCount &+= 1
            }
        }
    }

    private func write(cgImage: CGImage, to url: URL) {
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            lastError = "Couldn't encode screenshot as PNG."
            return
        }
        do {
            try data.write(to: url)
            lastError = nil
        } catch {
            lastError = "Couldn't save screenshot: \(error.localizedDescription)"
            logger.error("save screenshot failed: \(error.localizedDescription)")
        }
    }

    private static func timestampedURL(folder: String, name: String, ext: String) -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let stamp = formatter.string(from: Date())
        let home = URL(fileURLWithPath: NSHomeDirectory())
        return home.appendingPathComponent(folder).appendingPathComponent("\(name) \(stamp).\(ext)")
    }

    // MARK: - CMIO toggle

    /// Flip `kCMIOHardwarePropertyAllowScreenCaptureDevices` so the OS
    /// publishes USB-tethered iPhones as `AVCaptureDevice`s. This is the
    /// same flag QuickTime sets when it offers "iPhone" as a recording
    /// source. Idempotent — safe to call on every launch.
    private static func enableScreenCaptureDevices() {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyAllowScreenCaptureDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        var allow: UInt32 = 1
        CMIOObjectSetPropertyData(
            CMIOObjectID(kCMIOObjectSystemObject),
            &address,
            0, nil,
            UInt32(MemoryLayout.size(ofValue: allow)),
            &allow
        )
    }

    private func attachIfAvailable() {
        if let device = Self.firstAttachedScreenCaptureDevice() {
            attach(device)
        } else {
            status = .waiting
            scheduleRescan()
        }
    }

    /// An iPhone that's already plugged in when the pane opens never fires
    /// `wasConnectedNotification`, and the OS needs a beat to publish the
    /// screen-capture device after the CMIO flag flips and camera access is
    /// granted — so the single discovery in `attachIfAvailable()` can miss it
    /// and leave the pane stuck on `.waiting`. Poll a few times so the common
    /// "phone already connected" case attaches on its own, no unplug/replug.
    private func scheduleRescan() {
        rescanAttemptsRemaining = 10  // ~5s at a 0.5s cadence
        guard !rescanActive else { return }  // a poll chain is already running
        rescanActive = true
        rescanTick()
    }

    private func rescanTick() {
        guard deviceUniqueID == nil, rescanAttemptsRemaining > 0 else {
            rescanActive = false
            return
        }
        rescanAttemptsRemaining -= 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.deviceUniqueID == nil else {
                    self?.rescanActive = false
                    return
                }
                if let device = Self.firstAttachedScreenCaptureDevice() {
                    self.attach(device)
                } else {
                    self.rescanTick()
                }
            }
        }
    }

    private func cancelRescan() {
        rescanAttemptsRemaining = 0
        rescanActive = false
    }

    private static func firstAttachedScreenCaptureDevice() -> AVCaptureDevice? {
        // The CMIO screen-capture pathway publishes the iPhone as an
        // `.external` device that delivers `.muxed` video+audio — that's
        // the only flavor we want. Continuity Camera (which streams the
        // iPhone's actual camera, not the screen) reports as
        // `.continuityCamera` with `.video`, so filtering by `.external` +
        // `.muxed` excludes it cleanly.
        let muxed = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.external],
            mediaType: .muxed,
            position: .unspecified
        ).devices

        if let phone = muxed.first(where: { Self.looksLikeIOSDevice($0) }) {
            return phone
        }
        if let any = muxed.first {
            return any
        }

        let video = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.external],
            mediaType: .video,
            position: .unspecified
        ).devices

        return video.first { device in
            device.deviceType != .continuityCamera && Self.looksLikeIOSDevice(device)
        }
    }

    private static func looksLikeIOSDevice(_ device: AVCaptureDevice) -> Bool {
        device.localizedName.localizedCaseInsensitiveContains("iphone")
            || device.localizedName.localizedCaseInsensitiveContains("ipad")
            || device.modelID.localizedCaseInsensitiveContains("iphone")
            || device.modelID.localizedCaseInsensitiveContains("ipad")
            || device.modelID.contains("iOS")
    }

    // MARK: - Hot-plug

    private func observeConnections() {
        let nc = NotificationCenter.default
        nc.addObserver(
            self,
            selector: #selector(handleDeviceConnected),
            name: AVCaptureDevice.wasConnectedNotification,
            object: nil
        )
        nc.addObserver(
            self,
            selector: #selector(handleDeviceDisconnected(_:)),
            name: AVCaptureDevice.wasDisconnectedNotification,
            object: nil
        )
    }

    @objc private func handleDeviceConnected() {
        MainActor.assumeIsolated {
            guard deviceUniqueID == nil,
                  let device = Self.firstAttachedScreenCaptureDevice() else { return }
            attach(device)
        }
    }

    @objc private func handleDeviceDisconnected(_ note: Notification) {
        let lostID = (note.object as? AVCaptureDevice)?.uniqueID
        MainActor.assumeIsolated {
            guard let lostID, lostID == deviceUniqueID else { return }
            detach()
        }
    }

    // MARK: - Session wiring

    private func attach(_ device: AVCaptureDevice) {
        cancelRescan()
        status = .connecting
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        for input in session.inputs { session.removeInput(input) }
        for output in session.outputs { session.removeOutput(output) }
        hasAudioInput = false

        useDeviceNativeFormat()

        do {
            let videoInput = try AVCaptureDeviceInput(device: device)
            if session.canAddInput(videoInput) {
                session.addInput(videoInput)
            }
            // Pin the device to its highest-res native format only after the
            // input is live, so the `.inputPriority` session keeps the device's
            // real aspect ratio instead of having it overridden when the input
            // is added.
            configureHighestResolutionFormat(for: device)
        } catch {
            logger.error("video input failed: \(error.localizedDescription)")
            status = .failed(error.localizedDescription)
            return
        }

        if let audioDevice = pairedAudioDevice(forVideo: device) {
            do {
                let audioInput = try AVCaptureDeviceInput(device: audioDevice)
                if session.canAddInput(audioInput) {
                    session.addInput(audioInput)
                    if session.canAddOutput(audioPreview) {
                        session.addOutput(audioPreview)
                    }
                    // Separate data output so recordings can capture audio too —
                    // the writer pulls sample buffers from here. Only once both
                    // the input and this output are live is there an audio track
                    // to record.
                    if session.canAddOutput(audioDataOutput) {
                        session.addOutput(audioDataOutput)
                        hasAudioInput = true
                    }
                }
            } catch {
                logger.warning("audio input failed: \(error.localizedDescription)")
            }
        }

        if session.canAddOutput(videoDataOutput) {
            session.addOutput(videoDataOutput)
        }

        deviceUniqueID = device.uniqueID
        deviceName = device.localizedName
        status = .streaming
        run(.start)
    }

    private func detach() {
        cancelRescan()
        hasAudioInput = false
        session.beginConfiguration()
        for input in session.inputs { session.removeInput(input) }
        for output in session.outputs { session.removeOutput(output) }
        session.commitConfiguration()

        run(.stop)

        deviceUniqueID = nil
        deviceName = nil
        isRecording = false
        status = .waiting
    }

    private enum Lifecycle { case start, stop }

    private func run(_ lifecycle: Lifecycle) {
        nonisolated(unsafe) let session = self.session
        sessionQueue.async {
            switch lifecycle {
            case .start: if !session.isRunning { session.startRunning() }
            case .stop: if session.isRunning { session.stopRunning() }
            }
        }
    }

    private func pairedAudioDevice(forVideo video: AVCaptureDevice) -> AVCaptureDevice? {
        let candidates = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.external],
            mediaType: .audio,
            position: .unspecified
        ).devices

        if let exact = candidates.first(where: { $0.uniqueID == video.uniqueID }) {
            return exact
        }
        if let modelMatch = candidates.first(where: { $0.modelID == video.modelID }) {
            return modelMatch
        }
        return candidates.first { $0.localizedName == video.localizedName }
    }

    /// Use the input device's own format instead of a fixed preset. A fixed
    /// resolution preset (e.g. `.hd1920x1080`) forces 16:9, which letterboxes a
    /// phone's taller screen in the recording. (`.inputPriority` would be ideal
    /// but is iOS-only.) `.high` adapts to the device's native format, and we
    /// then pin `activeFormat` via `configureHighestResolutionFormat`, so we
    /// record at the device's real resolution and aspect ratio.
    private func useDeviceNativeFormat() {
        if session.canSetSessionPreset(.high) {
            session.sessionPreset = .high
        }
    }

    private func configureHighestResolutionFormat(for device: AVCaptureDevice) {
        let bestFormat = device.formats.max { lhs, rhs in
            let lhsSize = CMVideoFormatDescriptionGetDimensions(lhs.formatDescription)
            let rhsSize = CMVideoFormatDescriptionGetDimensions(rhs.formatDescription)
            let lhsPixels = Int(lhsSize.width) * Int(lhsSize.height)
            let rhsPixels = Int(rhsSize.width) * Int(rhsSize.height)
            if lhsPixels != rhsPixels {
                return lhsPixels < rhsPixels
            }
            return lhs.videoSupportedFrameRateRanges.bestFrameRate
                < rhs.videoSupportedFrameRateRanges.bestFrameRate
        }

        guard let bestFormat else { return }
        do {
            try device.lockForConfiguration()
            device.activeFormat = bestFormat
            device.unlockForConfiguration()
        } catch {
            logger.warning("screen capture format selection failed: \(error.localizedDescription)")
        }
    }

    /// Log the saved recording's real dimensions so we can confirm it kept the
    /// device's native aspect ratio (a tall phone screen, not a 16:9 frame) —
    /// read from the finished file, independent of the live preview (issue #56).
    private func verifyNativeAspectRatio(of url: URL) {
        let logger = self.logger
        Task.detached(priority: .utility) {
            let asset = AVURLAsset(url: url)
            guard let track = try? await asset.loadTracks(withMediaType: .video).first,
                  let size = try? await track.load(.naturalSize) else { return }
            let w = Int(size.width.rounded())
            let h = Int(size.height.rounded())
            logger.info("recording saved at \(w)x\(h) (\(h >= w ? "portrait" : "landscape"))")
        }
    }
}

private extension [AVFrameRateRange] {
    var bestFrameRate: Double {
        map(\.maxFrameRate).max() ?? 0
    }
}

// MARK: - Capture coordinator

/// Receives video + audio sample buffers off the capture queue and does two
/// jobs: hand back a single frame for screenshots, and write recordings to
/// disk with `AVAssetWriter`. Writing the buffers ourselves (rather than via
/// `AVCaptureMovieFileOutput`) is what keeps the recording at the device's
/// native dimensions: the writer is sized from the first video frame's real
/// `CMVideoFormatDescription`, so the file is exactly what the session
/// delivers — the same frames the preview shows (issue #56).
///
/// All mutable state is guarded by `lock`. The two data outputs share one
/// serial delivery queue, so video/audio callbacks never overlap; only
/// `start`/`stopRecording` (called from the main actor) race them, and the
/// lock serializes that.
private final class CaptureCoordinator: NSObject,
    AVCaptureVideoDataOutputSampleBufferDelegate,
    AVCaptureAudioDataOutputSampleBufferDelegate,
    @unchecked Sendable {
    private let lock = NSLock()
    private let ciContext = CIContext()
    private var pending: CheckedContinuation<CGImage?, Never>?

    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var recordingURL: URL?
    private var armed = false      // start requested; writer is built on the first frame
    private var finishing = false

    /// Called on completion with the saved URL and an error description (if any).
    var onFinish: (@Sendable (URL, String?) -> Void)?

    // MARK: Screenshot

    func nextFrame() async -> CGImage? {
        await withCheckedContinuation { cont in
            lock.lock()
            pending?.resume(returning: nil)
            pending = cont
            lock.unlock()
        }
    }

    // MARK: Recording control

    func startRecording(to url: URL) {
        lock.lock()
        defer { lock.unlock() }
        guard writer == nil else { return }
        recordingURL = url
        armed = true
        finishing = false
    }

    func stopRecording() {
        lock.lock()
        guard let writer, !finishing else {
            // Armed but no frame ever arrived, or already stopping: just disarm.
            armed = false
            recordingURL = nil
            lock.unlock()
            return
        }
        finishing = true
        let url = recordingURL ?? writer.outputURL
        let callback = onFinish
        videoInput?.markAsFinished()
        audioInput?.markAsFinished()
        lock.unlock()

        writer.finishWriting { [weak self] in
            let message = writer.status == .failed ? writer.error?.localizedDescription : nil
            callback?(url, message)
            guard let self else { return }
            self.lock.lock()
            self.writer = nil
            self.videoInput = nil
            self.audioInput = nil
            self.recordingURL = nil
            self.armed = false
            self.finishing = false
            self.lock.unlock()
        }
    }

    // MARK: Sample delegate

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        if output is AVCaptureVideoDataOutput {
            serveScreenshot(sampleBuffer)
            appendVideo(sampleBuffer)
        } else if output is AVCaptureAudioDataOutput {
            appendAudio(sampleBuffer)
        }
    }

    private func serveScreenshot(_ sampleBuffer: CMSampleBuffer) {
        lock.lock()
        let cont = pending
        pending = nil
        lock.unlock()

        guard let cont else { return }
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            cont.resume(returning: nil)
            return
        }
        let ciImage = CIImage(cvImageBuffer: imageBuffer)
        cont.resume(returning: ciContext.createCGImage(ciImage, from: ciImage.extent))
    }

    private func appendVideo(_ sampleBuffer: CMSampleBuffer) {
        lock.lock()
        defer { lock.unlock() }
        if armed, writer == nil {
            buildWriter(from: sampleBuffer)
        }
        guard let writer, let videoInput, !finishing else { return }
        if writer.status == .unknown {
            writer.startWriting()
            writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        }
        if writer.status == .writing, videoInput.isReadyForMoreMediaData {
            videoInput.append(sampleBuffer)
        }
    }

    private func appendAudio(_ sampleBuffer: CMSampleBuffer) {
        lock.lock()
        defer { lock.unlock() }
        // Only once the writer is live (video frame started the session) —
        // appending audio before `startSession` would fail.
        guard let writer, let audioInput, !finishing,
              writer.status == .writing, audioInput.isReadyForMoreMediaData else { return }
        audioInput.append(sampleBuffer)
    }

    /// Build the writer sized to the device's real frame dimensions. Called
    /// with `lock` held, on the first video sample of a recording.
    private func buildWriter(from sampleBuffer: CMSampleBuffer) {
        guard let url = recordingURL,
              let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
        let dimensions = CMVideoFormatDescriptionGetDimensions(formatDescription)
        do {
            let writer = try AVAssetWriter(outputURL: url, fileType: .mov)

            let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: Int(dimensions.width),
                AVVideoHeightKey: Int(dimensions.height),
            ])
            videoInput.expectsMediaDataInRealTime = true
            if writer.canAdd(videoInput) { writer.add(videoInput) }

            let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVNumberOfChannelsKey: 2,
                AVSampleRateKey: 44_100,
                AVEncoderBitRateKey: 128_000,
            ])
            audioInput.expectsMediaDataInRealTime = true
            if writer.canAdd(audioInput) { writer.add(audioInput) }

            self.writer = writer
            self.videoInput = videoInput
            self.audioInput = audioInput
        } catch {
            armed = false
        }
    }
}
