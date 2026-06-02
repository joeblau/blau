import AVFoundation
import AppKit
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

    @ObservationIgnored private let logger = Logger(subsystem: "app.blau.pilot.device", category: "capture")
    @ObservationIgnored private let audioPreview = AVCaptureAudioPreviewOutput()
    @ObservationIgnored private let movieOutput = AVCaptureMovieFileOutput()
    @ObservationIgnored private let videoDataOutput = AVCaptureVideoDataOutput()
    @ObservationIgnored private let frameDelegate = NextFrameCaptureDelegate()
    @ObservationIgnored private let frameQueue = DispatchQueue(label: "app.blau.pilot.device.frame")
    @ObservationIgnored private let sessionQueue = DispatchQueue(label: "app.blau.pilot.device.capture")
    @ObservationIgnored private let recordingDelegate = MovieRecordingDelegate()

    /// Native pixel dimensions of the `activeFormat` we pin the device to,
    /// captured when we lock the highest-resolution format. Used after a
    /// recording finishes to confirm the on-disk file kept the device's real
    /// aspect ratio rather than a letterboxed 16:9 (issue #56).
    @ObservationIgnored private var nativeDimensions: CMVideoDimensions?

    override init() {
        super.init()
        Self.enableScreenCaptureDevices()
        useDeviceNativeFormat()
        audioPreview.volume = 1.0
        videoDataOutput.alwaysDiscardsLateVideoFrames = true
        videoDataOutput.setSampleBufferDelegate(frameDelegate, queue: frameQueue)
        recordingDelegate.owner = self
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
            movieOutput.stopRecording()
        }
        detach()
    }

    // MARK: - Recording

    func toggleRecording() {
        guard status == .streaming else { return }
        if isRecording {
            movieOutput.stopRecording()
        } else {
            startRecording()
        }
    }

    private func startRecording() {
        guard !isRecording else { return }
        guard movieOutput.connection(with: .video) != nil else {
            lastError = "No video stream available to record."
            return
        }
        let url = Self.timestampedURL(folder: "Desktop", name: "iPhone Recording", ext: "mov")
        movieOutput.startRecording(to: url, recordingDelegate: recordingDelegate)
        isRecording = true
        lastError = nil
    }

    fileprivate func recordingDidFinish(url: URL, error: Error?) {
        isRecording = false
        if let error {
            lastError = "Recording failed: \(error.localizedDescription)"
            logger.error("recording failed: \(error.localizedDescription)")
            return
        }
        verifyNativeAspectRatio(of: url)
    }

    // MARK: - Screenshot

    func takeScreenshot() {
        guard status == .streaming else { return }
        Task { [weak self] in
            guard let self else { return }
            guard let cgImage = await self.frameDelegate.nextFrame() else {
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
            guard let cgImage = await self.frameDelegate.nextFrame() else {
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
        }
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
        status = .connecting
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        for input in session.inputs { session.removeInput(input) }
        for output in session.outputs { session.removeOutput(output) }

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
                }
                if session.canAddOutput(audioPreview) {
                    session.addOutput(audioPreview)
                }
            } catch {
                logger.warning("audio input failed: \(error.localizedDescription)")
            }
        }

        if session.canAddOutput(movieOutput) {
            session.addOutput(movieOutput)
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
            // Remember the format we pinned so we can verify the recorded file
            // came out at these exact dimensions (issue #56).
            nativeDimensions = CMVideoFormatDescriptionGetDimensions(bestFormat.formatDescription)
        } catch {
            logger.warning("screen capture format selection failed: \(error.localizedDescription)")
        }
    }

    /// Confirm the on-disk recording matches the device's native aspect ratio
    /// rather than a letterboxed 16:9 — checked independently of the live
    /// preview. On macOS an `AVCaptureConnection` exposes no scale/crop factor
    /// (that API is iOS-only), so the recorded dimensions follow the pinned
    /// `activeFormat`; rather than trusting that, we read the finished file and
    /// compare the saved video track's `naturalSize` against the format we
    /// pinned (orientation-agnostic), logging a warning on mismatch so a
    /// regression is caught (issue #56).
    private func verifyNativeAspectRatio(of url: URL) {
        guard let dims = nativeDimensions else { return }
        let expectedW = Int(dims.width)
        let expectedH = Int(dims.height)
        let logger = self.logger
        Task.detached(priority: .utility) {
            let asset = AVURLAsset(url: url)
            guard let track = try? await asset.loadTracks(withMediaType: .video).first,
                  let size = try? await track.load(.naturalSize) else { return }
            let recordedW = Int(size.width.rounded())
            let recordedH = Int(size.height.rounded())
            func ratio(_ a: Int, _ b: Int) -> Double {
                let lo = Double(min(a, b)), hi = Double(max(a, b))
                return hi > 0 ? lo / hi : 0
            }
            if abs(ratio(expectedW, expectedH) - ratio(recordedW, recordedH)) > 0.01 {
                logger.warning("recorded \(recordedW)x\(recordedH) aspect differs from device-native \(expectedW)x\(expectedH) — possible letterboxing")
            } else {
                logger.info("recording honors native aspect: \(recordedW)x\(recordedH) (native \(expectedW)x\(expectedH))")
            }
        }
    }
}

private extension [AVFrameRateRange] {
    var bestFrameRate: Double {
        map(\.maxFrameRate).max() ?? 0
    }
}

// MARK: - Frame & recording delegates

private final class NextFrameCaptureDelegate: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var pending: CheckedContinuation<CGImage?, Never>?
    private let ciContext = CIContext()

    func nextFrame() async -> CGImage? {
        await withCheckedContinuation { cont in
            lock.lock()
            pending?.resume(returning: nil)
            pending = cont
            lock.unlock()
        }
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
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
        let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent)
        cont.resume(returning: cgImage)
    }
}

private final class MovieRecordingDelegate: NSObject, AVCaptureFileOutputRecordingDelegate, @unchecked Sendable {
    weak var owner: DeviceCaptureSession?

    func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: Error?
    ) {
        Task { @MainActor in
            self.owner?.recordingDidFinish(url: outputFileURL, error: error)
        }
    }
}
