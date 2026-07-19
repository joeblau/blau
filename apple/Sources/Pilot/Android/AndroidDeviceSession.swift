import AVFoundation
import AppKit
import CoreMedia
import Foundation
import OSLog

/// Drives one Android device pane over the user's own `adb` — the native
/// answer to scrcpy, with zero bundled binaries and zero device-side installs:
/// `screenrecord` H.264 piped into an `AVSampleBufferDisplayLayer` for the live
/// mirror, `screencap` for screenshots, `input` (via one persistent shell) for
/// taps/gestures/keys/text, and a passthrough `AVAssetWriter` for recording.
///
/// Runtime-only (the registry keys it by `Pane.id`); no SwiftData. Async work
/// is tagged with monotonic generation tokens (`SimulatorSession`'s pattern):
/// `connectionGeneration` invalidates a whole device connection,
/// `streamGeneration` invalidates one screenrecord invocation within it.
@MainActor
@Observable
final class AndroidDeviceSession {
    enum Status: Equatable {
        case picking
        case adbMissing
        case connecting(String)
        case streaming
        case failed(String)
    }

    var status: Status = .picking
    var devices: [AndroidDevice] = []
    var isRefreshing = false
    var lastError: String?
    var isRecording = false
    /// Increments after each successful clipboard write so the pane can show a
    /// confirmation even when screenshots are copied back-to-back.
    var clipboardCopyCount = 0
    /// Increments the first time typed/pasted characters are dropped by the
    /// adb text allowlist, so the pane can flash a one-time notice.
    var droppedTextNoticeCount = 0

    private(set) var connectedSerial: String?
    private(set) var connectedName: String?

    /// Live video surface; hosted by `AndroidCaptureHostView`.
    @ObservationIgnored let displayLayer = AVSampleBufferDisplayLayer()
    /// Encoded video pixel size, for aspect-fit letterboxing. Read directly by
    /// the (AppKit) host view, so it doesn't need SwiftUI observation.
    @ObservationIgnored private(set) var captureSize: CGSize?

    @ObservationIgnored private var adbURL: URL?
    /// Display size from `wm size`, in the device's natural (portrait)
    /// orientation; input coordinates are mapped into this space, swapped when
    /// `rotation` is odd (landscape).
    @ObservationIgnored private var naturalDisplaySize: CGSize?
    @ObservationIgnored private var rotation = 0

    @ObservationIgnored private var stream: AndroidScreenStream?
    @ObservationIgnored private var policy = AndroidStreamPolicy()
    @ObservationIgnored private var epoch: ContinuousClock.Instant?
    @ObservationIgnored private var injector: AndroidInputInjector?
    @ObservationIgnored private let recorder = AndroidStreamRecorder()
    @ObservationIgnored private var rotationWatcher: Process?
    @ObservationIgnored private var rotationWatcherHandle: FileHandle?
    @ObservationIgnored private var rotationLineBuffer = Data()

    @ObservationIgnored private var connectionGeneration = 0
    @ObservationIgnored private var streamGeneration = 0
    @ObservationIgnored private(set) var isSuspended = false
    @ObservationIgnored private var selfHealActive = false
    @ObservationIgnored private var hasWarnedAboutDroppedText = false

    /// Pending typed characters, coalesced into one `input text` per beat.
    @ObservationIgnored private var pendingText = ""
    @ObservationIgnored private var textFlushTask: Task<Void, Never>?
    /// Pending scroll-wheel deltas (device pixels), coalesced per beat.
    @ObservationIgnored private var pendingScroll: (dx: CGFloat, dy: CGFloat, anchor: CGPoint)?
    @ObservationIgnored private var scrollFlushTask: Task<Void, Never>?

    @ObservationIgnored private let logger = Logger(subsystem: "app.blau.pilot.android", category: "session")

    private static let selfHealInterval: Duration = .seconds(2)

    init() {
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = NSColor.clear.cgColor
        recorder.onSegmentFinished = { [weak self] url, errorMessage in
            Task { @MainActor [weak self] in
                self?.recordingSegmentDidFinish(url: url, errorMessage: errorMessage)
            }
        }
    }

    // MARK: - Device list

    func refreshDevices() {
        guard !isSuspended, !isRefreshing else { return }
        isRefreshing = true
        Task {
            let result = await Self.loadDevices()
            self.isRefreshing = false
            switch result {
            case .success(let devices):
                self.devices = devices
                self.lastError = nil
                if self.status == .adbMissing { self.status = .picking }
            case .toolingMissing:
                self.devices = []
                if self.status == .picking || self.status == .adbMissing {
                    self.status = .adbMissing
                }
            case .failure(let message):
                self.logger.error("adb devices failed: \(message, privacy: .public)")
                self.devices = []
                self.lastError = message
            }
        }
    }

    private enum LoadResult: Sendable {
        case success([AndroidDevice])
        case toolingMissing
        case failure(String)
    }

    private static func loadDevices() async -> LoadResult {
        await Task.detached(priority: .userInitiated) {
            do {
                return .success(try AdbBridge.listDevices())
            } catch AdbError.toolingMissing {
                return .toolingMissing
            } catch AdbError.commandFailed(let message) {
                return .failure(message)
            } catch {
                return .failure(error.localizedDescription)
            }
        }.value
    }

    // MARK: - Connect / teardown

    func connect(_ device: AndroidDevice) {
        guard device.isConnectable else { return }
        isSuspended = false
        connectionGeneration &+= 1
        let generation = connectionGeneration
        teardownConnection()

        connectedSerial = device.serial
        connectedName = device.displayName
        status = .connecting(device.displayName)

        Task {
            let outcome = await Self.prepareConnection(serial: device.serial)
            guard generation == self.connectionGeneration else { return }
            switch outcome {
            case .ready(let adbURL, let naturalSize, let rotation):
                self.adbURL = adbURL
                self.naturalDisplaySize = naturalSize
                self.rotation = rotation
                self.policy = AndroidStreamPolicy()
                self.epoch = ContinuousClock.now
                self.injector = AndroidInputInjector(adbURL: adbURL, serial: device.serial)
                self.startRotationWatcher(adbURL: adbURL, serial: device.serial, generation: generation)
                self.startStream(attempt: self.policy.firstAttempt)
                // A sleeping screen produces no frames at all (screenrecord
                // emits nothing, not even codec config), which would strand
                // the pane on "Connecting…": wake the device, and if frames
                // still never arrive, fail into the self-heal loop with an
                // actionable message.
                self.send(.keyevent(AndroidKeyMap.Keycode.wakeup))
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(12))
                    guard let self, generation == self.connectionGeneration,
                          case .connecting = self.status else { return }
                    self.stream?.stop()
                    self.stream = nil
                    self.streamGeneration &+= 1
                    self.status = .failed("The device isn't sending video. Wake its screen, then retry.")
                    self.startSelfHeal()
                }
            case .toolingMissing:
                self.status = .adbMissing
            case .failure(let message):
                self.status = .failed(message)
                self.startSelfHeal()
            }
        }
    }

    private enum ConnectionOutcome: Sendable {
        case ready(adbURL: URL, naturalSize: CGSize?, rotation: Int)
        case toolingMissing
        case failure(String)
    }

    private static func prepareConnection(serial: String) async -> ConnectionOutcome {
        await Task.detached(priority: .userInitiated) {
            guard let adbURL = AdbBridge.resolveAdbURL() else { return .toolingMissing }
            let rotation = AdbBridge.currentRotation(adbURL: adbURL, serial: serial) ?? 0
            do {
                let size = try AdbBridge.displaySize(adbURL: adbURL, serial: serial)
                return .ready(adbURL: adbURL, naturalSize: size, rotation: rotation)
            } catch AdbError.commandFailed(let message) where message.contains("unauthorized") {
                return .failure("The device hasn't authorized this computer. Accept the USB-debugging prompt on the phone, then retry.")
            } catch {
                // A missing size only costs the resolution cap; stream anyway.
                return .ready(adbURL: adbURL, naturalSize: nil, rotation: rotation)
            }
        }.value
    }

    /// Stop mirroring and every per-connection resource. The device itself is
    /// left untouched.
    func stop() {
        isSuspended = false
        connectionGeneration &+= 1
        streamGeneration &+= 1
        teardownConnection()
    }

    /// Stop every long-lived adb/decode resource while retaining the user's
    /// selected device. Background and collapsed panes remain mounted so their
    /// layout state persists, but they must not keep a device encoder, USB pipe,
    /// decoder, input shell, or rotation watcher alive.
    func suspend() {
        guard !isSuspended else { return }
        isSuspended = true
        connectionGeneration &+= 1
        streamGeneration &+= 1
        teardownConnection(recordingStopReason: "Recording stopped because the Android pane was hidden.")
        if let name = connectedName {
            // The inactive view is hidden. Keeping a non-terminal state lets a
            // resumed presentation reconnect the remembered serial cleanly.
            status = .connecting(name)
        }
    }

    /// Reconnect the device remembered by `suspend()`. No selection is cleared,
    /// and reconnect uses the latest device-list metadata when available.
    func resume() {
        guard isSuspended else { return }
        isSuspended = false
        guard let serial = connectedSerial else {
            if devices.isEmpty { refreshDevices() }
            return
        }
        let device = devices.first { $0.serial == serial && $0.isConnectable }
            ?? AndroidDevice(serial: serial, state: .device, model: connectedName, product: nil)
        connect(device)
    }

    func chooseAnotherDevice() {
        stop()
        connectedSerial = nil
        connectedName = nil
        status = .picking
        refreshDevices()
    }

    /// Manual retry from the failed overlay — the self-heal poll's big button.
    func retry() {
        guard case .failed = status, let serial = connectedSerial else { return }
        let device = devices.first { $0.serial == serial }
            ?? AndroidDevice(serial: serial, state: .device, model: connectedName, product: nil)
        connect(device)
    }

    private func teardownConnection(
        recordingStopReason: String = "Recording stopped because the device disconnected."
    ) {
        recorder.stop(reason: recordingStopReason)
        isRecording = false
        stream?.stop()
        stream = nil
        if let injector {
            Task { await injector.shutdown() }
        }
        injector = nil
        stopRotationWatcher()
        selfHealActive = false
        captureSize = nil
        naturalDisplaySize = nil
        rotation = 0
        adbURL = nil
        epoch = nil
        pendingText = ""
        textFlushTask?.cancel()
        textFlushTask = nil
        pendingScroll = nil
        scrollFlushTask?.cancel()
        scrollFlushTask = nil
        displayLayer.flushAndRemoveImage()
    }

    // MARK: - Stream lifecycle

    private func startStream(attempt: AndroidStreamPolicy.Attempt) {
        guard let adbURL, let serial = connectedSerial, let epoch else { return }
        streamGeneration &+= 1
        let generation = streamGeneration

        let size = naturalDisplaySize.map { natural in
            AdbBridge.cappedStreamSize(native: orientedSize(natural), longEdge: attempt.longEdgeCap)
        }
        let stream = AndroidScreenStream(
            layer: displayLayer,
            onFormat: { [weak self] _, dimensions in
                Task { @MainActor [weak self] in
                    guard let self, generation == self.streamGeneration else { return }
                    self.captureSize = dimensions
                    if self.status != .streaming {
                        self.status = .streaming
                        self.lastError = nil
                    }
                }
            },
            onSample: { [recorder] sample, isIDR in
                guard recorder.isActive,
                      let format = CMSampleBufferGetFormatDescription(sample) else { return }
                recorder.append(sample, isIDR: isIDR, format: format)
            },
            onNeedsSync: { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self, generation == self.streamGeneration else { return }
                    self.logger.info("display needs a sync frame; restarting stream")
                    self.restartStream()
                }
            },
            onExit: { [weak self] exit, runtime, diagnostics in
                Task { @MainActor [weak self] in
                    self?.streamDidExit(exit, runtime: runtime, diagnostics: diagnostics, generation: generation)
                }
            }
        )
        self.stream = stream
        stream.start(configuration: AndroidScreenStream.Configuration(
            adbURL: adbURL,
            serial: serial,
            size: size,
            timeLimitZero: attempt.timeLimitZero,
            epoch: epoch
        ))
    }

    private func streamDidExit(_ exit: AndroidStreamExit, runtime: Duration, diagnostics: String, generation: Int) {
        guard generation == streamGeneration else { return }
        stream = nil
        if case .poisoned(let reason) = exit {
            logger.error("stream poisoned: \(reason, privacy: .public)")
        }
        switch policy.nextDecision(runtime: runtime, diagnostics: diagnostics) {
        case .restart(let attempt):
            // The display layer keeps the last frame, so the respawn seam is a
            // short freeze, never a black flash.
            startStream(attempt: attempt)
        case .fail(let message):
            recorder.stop(reason: "Recording stopped because the video stream failed.")
            isRecording = false
            status = .failed(message)
            startSelfHeal()
        }
    }

    /// Restart the mirror in place (rotation, record-start). Keeps the epoch,
    /// so recording PTS stays continuous, and the policy's learned rung, so an
    /// old device doesn't re-spawn a doomed `--time-limit 0` child every time.
    private func restartStream() {
        guard connectedSerial != nil, adbURL != nil else { return }
        stream?.stop()
        stream = nil
        startStream(attempt: policy.currentAttempt)
    }

    private func orientedSize(_ natural: CGSize) -> CGSize {
        rotation % 2 == 0 ? natural : CGSize(width: natural.height, height: natural.width)
    }

    // MARK: - Rotation watch

    /// screenrecord does not reliably exit when the device rotates — it keeps
    /// encoding with the stale projection — so a tiny on-device loop reports
    /// `rotation=N` every 2 s and a change force-restarts the stream.
    private func startRotationWatcher(adbURL: URL, serial: String, generation: Int) {
        let watcher = AdbBridge.makeRotationWatchProcess(adbURL: adbURL, serial: serial)
        let stdout = Pipe()
        watcher.standardOutput = stdout
        watcher.standardError = FileHandle.nullDevice
        rotationLineBuffer = Data()
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                // EOF (watcher died or was terminated): detach the source, or
                // this level-triggered handler spins at 100% CPU forever.
                handle.readabilityHandler = nil
                return
            }
            guard self != nil else {
                handle.readabilityHandler = nil
                return
            }
            Task { @MainActor [weak self] in
                guard let self, generation == self.connectionGeneration else { return }
                self.consumeRotationOutput(chunk)
            }
        }
        do {
            try watcher.run()
            rotationWatcher = watcher
            rotationWatcherHandle = stdout.fileHandleForReading
        } catch {
            stdout.fileHandleForReading.readabilityHandler = nil
            // Degraded, not broken: the mirror still works, rotation just
            // needs a manual reconnect.
            logger.warning("rotation watcher failed to launch: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func stopRotationWatcher() {
        rotationWatcherHandle?.readabilityHandler = nil
        rotationWatcherHandle = nil
        if let rotationWatcher, rotationWatcher.isRunning {
            rotationWatcher.terminate()
        }
        rotationWatcher = nil
        rotationLineBuffer = Data()
    }

    private func consumeRotationOutput(_ chunk: Data) {
        rotationLineBuffer.append(chunk)
        if rotationLineBuffer.count > 4_096 {
            rotationLineBuffer = rotationLineBuffer.suffix(64)
        }
        while let newline = rotationLineBuffer.firstIndex(of: 0x0A) {
            let lineData = rotationLineBuffer.prefix(upTo: newline)
            rotationLineBuffer.removeSubrange(...newline)
            guard let value = AdbBridge.parseRotationLine(String(decoding: lineData, as: UTF8.self)) else {
                continue
            }
            if value != rotation {
                rotation = value
                logger.info("device rotated to \(value); restarting stream")
                restartStream()
            }
        }
    }

    // MARK: - Failed-state self-heal

    /// While `.failed`, poll for the device to become listable again and
    /// reconnect on the spot — no unplug/replug, no manual retry required
    /// (`DeviceCaptureSession.failedRescanTick`'s lesson: never make a failed
    /// state terminal).
    private func startSelfHeal() {
        guard !selfHealActive else { return }
        selfHealActive = true
        let generation = connectionGeneration
        Task {
            while self.selfHealActive, generation == self.connectionGeneration {
                try? await Task.sleep(for: Self.selfHealInterval)
                guard self.selfHealActive, generation == self.connectionGeneration,
                      case .failed = self.status, let serial = self.connectedSerial else { return }
                let result = await Self.loadDevices()
                guard self.selfHealActive, generation == self.connectionGeneration,
                      case .failed = self.status else { return }
                if case .success(let devices) = result,
                   let device = devices.first(where: { $0.serial == serial && $0.isConnectable }) {
                    self.selfHealActive = false
                    self.connect(device)
                    return
                }
            }
        }
    }

    // MARK: - Recording

    func toggleRecording() {
        if isRecording {
            recorder.stop()
            return
        }
        guard status == .streaming else { return }
        let armed = recorder.arm { segment in
            let name = segment == 1 ? "Android Recording" : "Android Recording part \(segment)"
            return AndroidMediaFiles.timestampedURL(name: name, ext: "mp4")
        }
        guard armed else {
            lastError = "A recording is already being saved. Wait for it to finish and retry."
            return
        }
        isRecording = true
        lastError = nil
        // Restart the stream so a fresh SPS/PPS + IDR arrives immediately —
        // screenrecord's ~10 s keyframe interval would otherwise delay the
        // recording's first frame by up to that long.
        restartStream()
    }

    private func recordingSegmentDidFinish(url: URL, errorMessage: String?) {
        if !recorder.isActive {
            isRecording = false
        }
        if let errorMessage {
            lastError = "Recording: \(errorMessage)"
            logger.error("recording segment failed: \(errorMessage, privacy: .public)")
            return
        }
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        if fileSize <= 0 {
            lastError = "Recording ended without producing a video."
        } else {
            lastError = nil
        }
    }

    // MARK: - Screenshot

    func takeScreenshot() {
        guard status == .streaming, let adbURL, let serial = connectedSerial else { return }
        Task { [weak self] in
            let result = await Self.captureScreenshot(adbURL: adbURL, serial: serial)
            guard let self, self.connectedSerial == serial else { return }
            switch result {
            case .success(let pngData):
                let url = AndroidMediaFiles.timestampedURL(name: "Android Screenshot", ext: "png")
                do {
                    try pngData.write(to: url, options: .withoutOverwriting)
                    self.lastError = nil
                } catch {
                    self.lastError = "Couldn't save screenshot: \(error.localizedDescription)"
                }
            case .failure(let message):
                self.lastError = "Couldn't take screenshot: \(message)"
                self.logger.error("screenshot failed: \(message, privacy: .public)")
            }
        }
    }

    func copyScreenshotToClipboard() {
        guard status == .streaming, let adbURL, let serial = connectedSerial else { return }
        Task { [weak self] in
            let result = await Self.captureScreenshot(adbURL: adbURL, serial: serial)
            guard let self, self.connectedSerial == serial else { return }
            switch result {
            case .success(let pngData):
                guard let image = NSImage(data: pngData) else {
                    self.lastError = "Couldn't decode the device screenshot."
                    return
                }
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                let wroteImage = pasteboard.writeObjects([image])
                let wrotePNG = pasteboard.setData(pngData, forType: .png)
                if wroteImage || wrotePNG {
                    self.lastError = nil
                    self.clipboardCopyCount &+= 1
                } else {
                    self.lastError = "Couldn't put the screenshot on the clipboard."
                }
            case .failure(let message):
                self.lastError = "Couldn't copy screenshot: \(message)"
                self.logger.error("copy screenshot failed: \(message, privacy: .public)")
            }
        }
    }

    private enum ScreenshotResult: Sendable {
        case success(Data)
        case failure(String)
    }

    private static func captureScreenshot(adbURL: URL, serial: String) async -> ScreenshotResult {
        await Task.detached(priority: .userInitiated) {
            do {
                return .success(try AdbBridge.screenshotPNG(adbURL: adbURL, serial: serial))
            } catch AdbError.commandFailed(let message) {
                return .failure(message)
            } catch AdbError.invalidOutput(let message) {
                return .failure(message)
            } catch {
                return .failure(error.localizedDescription)
            }
        }.value
    }

    // MARK: - Input (normalized 0…1 coords from the host view)

    /// Map a normalized point in the displayed video to device input pixels.
    /// `input` expects coordinates in the current display frame, which swaps
    /// W/H with rotation; the video after a rotation restart matches that
    /// orientation, so the same normalized point lands correctly in both.
    private func devicePoint(normalizedX: Double, normalizedY: Double) -> CGPoint? {
        let space = naturalDisplaySize.map(orientedSize) ?? captureSize
        guard let space else { return nil }
        return CGPoint(x: normalizedX * space.width, y: normalizedY * space.height)
    }

    func gestureEnded(_ classifier: inout AndroidGestureClassifier, normalizedX: Double, normalizedY: Double) {
        guard let point = devicePoint(normalizedX: normalizedX, normalizedY: normalizedY),
              let gesture = classifier.ended(at: point) else { return }
        send(AndroidGestureClassifier.command(for: gesture))
    }

    func gestureBegan(_ classifier: inout AndroidGestureClassifier, normalizedX: Double, normalizedY: Double) {
        guard let point = devicePoint(normalizedX: normalizedX, normalizedY: normalizedY) else { return }
        classifier.began(at: point)
    }

    func gestureMoved(_ classifier: inout AndroidGestureClassifier, normalizedX: Double, normalizedY: Double) {
        guard let point = devicePoint(normalizedX: normalizedX, normalizedY: normalizedY) else { return }
        classifier.moved(to: point)
    }

    /// Trackpad/wheel scroll, coalesced into one replayed swipe per beat.
    func scroll(normalizedDX: Double, normalizedDY: Double, anchorX: Double, anchorY: Double) {
        guard let space = naturalDisplaySize.map(orientedSize) ?? captureSize,
              let anchor = devicePoint(normalizedX: anchorX, normalizedY: anchorY) else { return }
        // Keep the tuple explicitly CGFloat-typed for Xcode 26 as well as 27;
        // Xcode 27 permits mixed Double/CGFloat arithmetic that 26 rejects.
        let dx = CGFloat(normalizedDX) * space.width
        let dy = CGFloat(normalizedDY) * space.height
        if var pending = pendingScroll {
            pending.dx += dx
            pending.dy += dy
            pendingScroll = pending
        } else {
            pendingScroll = (dx, dy, anchor)
        }
        guard scrollFlushTask == nil else { return }
        scrollFlushTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            self?.scrollFlushTask = nil
            self?.flushScroll()
        }
    }

    private func flushScroll() {
        guard let (dx, dy, anchor) = pendingScroll else { return }
        pendingScroll = nil
        let space = naturalDisplaySize.map(orientedSize) ?? captureSize
        guard let space else { return }
        // Clamp the replayed swipe to stay well inside the screen.
        let limitX = space.width * 0.4
        let limitY = space.height * 0.4
        let clampedDX = min(max(dx, -limitX), limitX)
        let clampedDY = min(max(dy, -limitY), limitY)
        guard abs(clampedDX) >= 4 || abs(clampedDY) >= 4 else { return }
        send(.swipe(
            fromX: Int(anchor.x),
            fromY: Int(anchor.y),
            toX: Int(anchor.x + clampedDX),
            toY: Int(anchor.y + clampedDY),
            durationMS: 100
        ))
    }

    func keyDown(macKeyCode: UInt16) -> Bool {
        guard let code = AndroidKeyMap.androidKeycode(forMacKeyCode: macKeyCode) else { return false }
        flushTextNow()
        send(.keyevent(code))
        return true
    }

    /// Toolbar navigation (Back / Home / App Switch / Power).
    func sendKeycode(_ code: Int) {
        send(.keyevent(code))
    }

    /// Printable characters, coalesced into one `input text` per beat so fast
    /// typing doesn't pay one on-device exec per character.
    func type(_ characters: String) {
        pendingText += characters
        guard textFlushTask == nil else { return }
        textFlushTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            self?.textFlushTask = nil
            self?.flushTextNow()
        }
    }

    /// Paste the macOS clipboard as device text (bounded).
    func pasteFromClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        flushTextNow()
        for chunk in text.prefix(4_096).chunked(into: 256) {
            sendText(String(chunk))
        }
    }

    private func flushTextNow() {
        guard !pendingText.isEmpty else { return }
        let text = pendingText
        pendingText = ""
        sendText(text)
    }

    private func sendText(_ text: String) {
        let (command, dropped) = AndroidInputCommand.text(text)
        if dropped > 0, !hasWarnedAboutDroppedText {
            hasWarnedAboutDroppedText = true
            droppedTextNoticeCount &+= 1
        }
        if let command { send(command) }
    }

    private func send(_ command: AndroidInputCommand) {
        guard let injector else { return }
        Task { await injector.send(command) }
    }
}

/// Timestamped Desktop destinations for Android media. A standalone
/// nonisolated helper because the recorder names follow-up segments from the
/// stream queue (`DeviceCaptureSession.timestampedURL` is main-actor-bound).
enum AndroidMediaFiles {
    static func timestampedURL(name: String, ext: String) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss.SSS"
        let filename = "\(name) \(formatter.string(from: Date())).\(ext)"
        return URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Desktop", isDirectory: true)
            .appendingPathComponent(filename)
    }
}

private extension StringProtocol {
    func chunked(into size: Int) -> [SubSequence] {
        var chunks: [SubSequence] = []
        var start = startIndex
        while start < endIndex {
            let end = index(start, offsetBy: size, limitedBy: endIndex) ?? endIndex
            chunks.append(self[start..<end])
            start = end
        }
        return chunks
    }
}
