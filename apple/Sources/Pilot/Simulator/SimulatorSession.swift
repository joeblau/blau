import AVFoundation
import AppKit
import CoreGraphics
import Foundation
import OSLog

/// Drives one iPhone Simulator pane via **direct simulator forwarding** (the
/// serve-sim technique): boots a device with `simctl`, captures its framebuffer
/// `IOSurface` straight from CoreSimulator/SimulatorKit (just the device screen —
/// no DeviceHub window, no Screen Recording), and injects touch/keyboard with
/// SimulatorKit's HID client.
///
/// Runtime-only (the registry keys it by `Pane.id`); no SwiftData. Async capture
/// work is tagged with a monotonic `captureGeneration` so a teardown or new boot
/// invalidates superseded work.
@MainActor
@Observable
final class SimulatorSession {
    enum Status: Equatable {
        case picking
        case booting(String)
        case starting(String)
        case streaming
        case failed(String)
        case toolingMissing
    }

    var status: Status = .picking
    var devices: [SimRuntimeGroup] = []
    var isRefreshing = false
    var lastError: String?

    private(set) var bootedDeviceName: String?
    private(set) var bootedUDID: String?

    /// Live video surface; hosted by `SimulatorCaptureHostView`.
    @ObservationIgnored let displayLayer = AVSampleBufferDisplayLayer()
    /// Framebuffer pixel size, for input coordinate mapping. Read directly by the
    /// (AppKit) host view, so it doesn't need SwiftUI observation.
    @ObservationIgnored private(set) var captureSize: CGSize?

    @ObservationIgnored private var framebuffer: SimulatorFramebuffer?
    @ObservationIgnored private var hid: SimulatorHID?
    @ObservationIgnored private var captureGeneration = 0
    @ObservationIgnored private let logger = Logger(subsystem: "app.blau.pilot.simulator", category: "session")

    init() {
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = NSColor.black.cgColor
    }

    // MARK: - Device list

    private enum LoadResult: Sendable {
        case success([SimRuntimeGroup])
        case toolingMissing
        case failure(String)
    }

    func refreshDevices() {
        guard !isRefreshing else { return }
        isRefreshing = true
        Task {
            let result = await Self.loadDevices()
            self.isRefreshing = false
            switch result {
            case .success(let groups):
                self.devices = groups
                self.lastError = nil
                if self.status == .toolingMissing { self.status = .picking }
            case .toolingMissing:
                self.status = .toolingMissing
            case .failure(let message):
                self.logger.error("simctl list failed: \(message, privacy: .public)")
                self.devices = []
                self.lastError = message
            }
        }
    }

    private static func loadDevices() async -> LoadResult {
        await Task.detached(priority: .userInitiated) {
            do { return .success(try SimctlBridge.listDevices()) }
            catch SimctlError.toolingMissing { return .toolingMissing }
            catch { return .failure(error.localizedDescription) }
        }.value
    }

    // MARK: - Boot + capture

    func boot(_ device: SimDevice) {
        captureGeneration &+= 1
        let generation = captureGeneration
        teardownCapture()

        bootedDeviceName = device.name
        bootedUDID = device.udid
        status = .booting(device.name)

        Task {
            let outcome = await Self.performBoot(device)
            guard generation == self.captureGeneration else { return }
            switch outcome {
            case .none:
                self.status = .starting(device.name)
                self.startCapture(device: device, generation: generation)
            case .toolingMissing:
                self.status = .toolingMissing
            case .message(let message):
                self.status = .failed(message)
            }
        }
    }

    private enum BootOutcome: Sendable { case none; case toolingMissing; case message(String) }

    private static func performBoot(_ device: SimDevice) async -> BootOutcome {
        await Task.detached(priority: .userInitiated) {
            do {
                if !device.isBooted { try SimctlBridge.boot(udid: device.udid) }
                SimctlBridge.bootStatus(udid: device.udid)
                return .none
            } catch SimctlError.toolingMissing {
                return .toolingMissing
            } catch SimctlError.commandFailed(let message) {
                return .message(message)
            } catch {
                return .message(error.localizedDescription)
            }
        }.value
    }

    private func startCapture(device: SimDevice, generation: Int) {
        guard generation == captureGeneration else { return }

        // HID is best-effort: capture can still show a read-only screen if the
        // SimulatorKit HID client can't be created.
        hid = try? SimulatorHID(deviceUDID: device.udid)

        let framebuffer = SimulatorFramebuffer(layer: displayLayer) { [weak self] width, height in
            Task { @MainActor in
                guard let self, generation == self.captureGeneration else { return }
                self.captureSize = CGSize(width: width, height: height)
            }
        }
        do {
            try framebuffer.start(deviceUDID: device.udid)
            self.framebuffer = framebuffer
            self.status = .streaming
        } catch {
            self.status = .failed(
                "Couldn't read the simulator framebuffer (\(error.localizedDescription)). This needs a full Xcode with the private CoreSimulator/SimulatorKit frameworks."
            )
        }
    }

    // MARK: - Teardown

    private func teardownCapture() {
        framebuffer?.stop()
        framebuffer = nil
        hid = nil
        captureSize = nil
        displayLayer.flushAndRemoveImage()
    }

    /// Stop capturing but leave the simulator booted. Called by the registry on
    /// pane removal.
    func stop() {
        captureGeneration &+= 1
        teardownCapture()
    }

    func chooseAnotherDevice() {
        stop()
        bootedDeviceName = nil
        bootedUDID = nil
        status = .picking
        refreshDevices()
    }

    func shutdownSimulator() {
        let udid = bootedUDID
        stop()
        bootedDeviceName = nil
        bootedUDID = nil
        status = .picking
        if let udid {
            Task {
                await Self.performShutdown(udid)
                self.refreshDevices()
            }
        } else {
            refreshDevices()
        }
    }

    private static func performShutdown(_ udid: String) async {
        await Task.detached(priority: .utility) { try? SimctlBridge.shutdown(udid: udid) }.value
    }

    // MARK: - Input (normalized 0…1 coords, forwarded straight to the simulator)

    func touch(_ phase: SimulatorHID.TouchPhase, normalizedX: Double, normalizedY: Double, edge: SimulatorHID.Edge = .none) {
        hid?.sendTouch(phase, x: normalizedX, y: normalizedY, edge: edge)
    }

    /// Two-finger pinch (normalized coords for each finger).
    func pinch(_ phase: SimulatorHID.TouchPhase, x1: Double, y1: Double, x2: Double, y2: Double) {
        hid?.sendMultiTouch(phase, x1: x1, y1: y1, x2: x2, y2: y2)
    }

    /// Trackpad scroll, as normalized deltas + the cursor anchor.
    func scroll(normalizedDX: Double, normalizedDY: Double, anchorX: Double, anchorY: Double) {
        hid?.sendScroll(normalizedDX: normalizedDX, normalizedDY: normalizedDY, anchorX: anchorX, anchorY: anchorY)
    }

    func keyUsage(_ usage: UInt32, down: Bool) {
        hid?.sendKeyUsage(usage, down: down)
    }
}
