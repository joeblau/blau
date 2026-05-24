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

    @ObservationIgnored private let logger = Logger(subsystem: "app.blau.pilot.device", category: "capture")
    @ObservationIgnored private let audioPreview = AVCaptureAudioPreviewOutput()
    @ObservationIgnored private let movieOutput = AVCaptureMovieFileOutput()
    @ObservationIgnored private let videoDataOutput = AVCaptureVideoDataOutput()
    @ObservationIgnored private let frameDelegate = NextFrameCaptureDelegate()
    @ObservationIgnored private let frameQueue = DispatchQueue(label: "app.blau.pilot.device.frame")
    @ObservationIgnored private let sessionQueue = DispatchQueue(label: "app.blau.pilot.device.capture")
    @ObservationIgnored private let recordingDelegate = MovieRecordingDelegate()

    override init() {
        super.init()
        Self.enableScreenCaptureDevices()
        session.sessionPreset = .high
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
        }
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

        do {
            let videoInput = try AVCaptureDeviceInput(device: device)
            if session.canAddInput(videoInput) {
                session.addInput(videoInput)
            }
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
