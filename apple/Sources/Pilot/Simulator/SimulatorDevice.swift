import Foundation
import OSLog

// SimulatorDevice — wraps a CoreSimulator `SimDevice` instance.
// The concrete SPI methods are TODOs; structure + lifecycle state machine
// is in place so pane code can interact with a non-SPI-completed device
// and get typed errors back.
//
// TODO(spi): Hold a reference to the live `SimDevice` obtained from
// `SimulatorDeviceSet.device(forUDID:)` and translate each public method
// to the matching SPI call:
//   - bootAsyncWithOptions:completionQueue:completionHandler:
//   - shutdownAsyncWithCompletionQueue:completionHandler:
//   - installApplication:withOptions:error:
//   - sendEvent:error:   (HID input)
//   - registerNotificationHandler:  (state transitions)
// See fb-idb's FBSimulator + FBSimulatorBootStrategy for reference impl.

@MainActor
final class SimulatorDevice {
    let udid: String
    let devicesRoot: URL

    private let logger = Logger(subsystem: "app.blau.pilot.simulator", category: "device")
    private(set) var state: LifecycleState = .unknown

    init(udid: String, devicesRoot: URL) {
        self.udid = udid
        self.devicesRoot = devicesRoot
    }

    enum LifecycleState: Sendable, Equatable {
        case unknown
        case shutdown
        case booting
        case booted
        case shuttingDown
    }

    // MARK: - Boot

    func boot() async throws {
        state = .booting
        // TODO(spi): Replace with SimDevice.bootAsyncWithOptions. Honor:
        //   - `kSimDeviceBootOptionsDisabledJobs` (skip background daemons we don't need)
        //   - 60s timeout → SimulatorError.bootTimeout
        logger.notice("SimulatorDevice.boot() called for \(self.udid) — SPI not yet wired")
        throw SimulatorError.spiUnavailable(symbol: "SimDevice.bootAsyncWithOptions:completionQueue:completionHandler:")
    }

    // MARK: - Shutdown

    func shutdown() async throws {
        state = .shuttingDown
        logger.notice("SimulatorDevice.shutdown() called for \(self.udid) — SPI not yet wired")
        // Intentionally no-throw: shutdown on an unbooted device is a no-op.
        state = .shutdown
    }

    // MARK: - App install

    /// Install an .app bundle or .ipa. Phase 1b feature — skeleton in place.
    /// TODO(spi): SimDevice.installApplication:withOptions:error:
    func install(appURL: URL) async throws {
        throw SimulatorError.spiUnavailable(symbol: "SimDevice.installApplication:withOptions:error:")
    }

    // MARK: - HID

    /// Send a HID event constructed by `SimulatorInputBridge`.
    /// TODO(spi): SimDevice.sendEvent: takes an SimDeviceIOHIDEvent.
    func sendHIDEvent(_ event: HIDEventPayload) async throws {
        throw SimulatorError.inputSendFailed(underlying: "SPI not yet wired")
    }
}

/// Opaque carrier for HID event bytes, decoupled from the private SPI surface.
/// `SimulatorInputBridge` builds these from `NSEvent`; `SimulatorDevice`
/// hands them to the SPI send call once wired.
struct HIDEventPayload: Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        case keyDown(keyCode: UInt16)
        case keyUp(keyCode: UInt16)
        case touchDown(x: Double, y: Double)
        case touchMove(x: Double, y: Double)
        case touchUp(x: Double, y: Double)
        case twoFingerPinchBegin(x: Double, y: Double, separation: Double)
        case twoFingerPinchUpdate(x: Double, y: Double, separation: Double)
        case twoFingerPinchEnd
        case scroll(dx: Double, dy: Double, atX: Double, atY: Double)
        case hardwareButton(button: HardwareButton)
    }

    enum HardwareButton: Sendable, Equatable {
        case home
        case lock
        case volumeUp
        case volumeDown
        case siri
    }

    let kind: Kind
    let timestamp: TimeInterval
}
