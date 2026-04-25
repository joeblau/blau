import AppKit
import Foundation
import OSLog

// SimulatorInputBridge — translates AppKit `NSEvent`s into opaque
// `HIDEventPayload` values, which `SimulatorDevice.sendHIDEvent(_:)`
// forwards to the simulator once SPI is wired.
//
//   ┌──────────────┐       ┌──────────────────────┐       ┌────────────────┐
//   │ NSEvent      │──────▶│ SimulatorInputBridge │──────▶│ HIDEventPayload│
//   │ (keyDown,    │       │ (translator)         │       │                │
//   │  mouse, etc) │       └──────────────────────┘       └────────────────┘
//   └──────────────┘                                               │
//                                                                  ▼
//                                                  ┌───────────────────────────┐
//                                                  │ SimulatorDevice.sendHID..│
//                                                  │ (TODO: wire to SPI)      │
//                                                  └───────────────────────────┘
//
// Keyboard: raw keystrokes — iOS runs its own IME. Do NOT compose via
// `NSTextInputClient`; that's a Ghostty-specific path. (See project
// learning `ghostty-keyboard-interpretKeyEvents`: the terminal needs
// composed text; the simulator wants raw keycodes.)
//
// Mouse: one finger for left-click + drag; two fingers via Option+drag
// to match Apple's Simulator.app convention.

final class SimulatorInputBridge {
    private let logger = Logger(subsystem: "app.blau.pilot.simulator", category: "input")

    /// Converts an `NSEvent` into zero or more HID payloads. Returning an
    /// array lets complex gestures (like pinch-begin + pinch-update) emit
    /// multiple events atomically.
    func translate(
        event: NSEvent,
        in viewBounds: CGRect,
        pinchSeparation: Double
    ) -> [HIDEventPayload] {
        let timestamp = event.timestamp
        switch event.type {
        case .keyDown:
            return [HIDEventPayload(kind: .keyDown(keyCode: event.keyCode), timestamp: timestamp)]
        case .keyUp:
            return [HIDEventPayload(kind: .keyUp(keyCode: event.keyCode), timestamp: timestamp)]
        case .flagsChanged:
            return []
        case .leftMouseDown:
            let point = viewPoint(event: event, in: viewBounds)
            if event.modifierFlags.contains(.option) {
                return [
                    HIDEventPayload(
                        kind: .twoFingerPinchBegin(x: point.x, y: point.y, separation: pinchSeparation),
                        timestamp: timestamp
                    )
                ]
            }
            return [HIDEventPayload(kind: .touchDown(x: point.x, y: point.y), timestamp: timestamp)]
        case .leftMouseDragged:
            let point = viewPoint(event: event, in: viewBounds)
            if event.modifierFlags.contains(.option) {
                return [
                    HIDEventPayload(
                        kind: .twoFingerPinchUpdate(x: point.x, y: point.y, separation: pinchSeparation),
                        timestamp: timestamp
                    )
                ]
            }
            return [HIDEventPayload(kind: .touchMove(x: point.x, y: point.y), timestamp: timestamp)]
        case .leftMouseUp:
            let point = viewPoint(event: event, in: viewBounds)
            if event.modifierFlags.contains(.option) {
                return [HIDEventPayload(kind: .twoFingerPinchEnd, timestamp: timestamp)]
            }
            return [HIDEventPayload(kind: .touchUp(x: point.x, y: point.y), timestamp: timestamp)]
        case .scrollWheel:
            let point = viewPoint(event: event, in: viewBounds)
            return [
                HIDEventPayload(
                    kind: .scroll(
                        dx: event.scrollingDeltaX,
                        dy: event.scrollingDeltaY,
                        atX: point.x,
                        atY: point.y
                    ),
                    timestamp: timestamp
                )
            ]
        default:
            return []
        }
    }

    /// Hardware button shortcut surface — called by pane toolbar buttons
    /// (home, lock, rotation, etc.), not by NSEvent translation.
    func hardwareButton(_ button: HIDEventPayload.HardwareButton) -> HIDEventPayload {
        HIDEventPayload(kind: .hardwareButton(button: button), timestamp: ProcessInfo.processInfo.systemUptime)
    }

    /// Converts event coordinates from AppKit (origin bottom-left) to
    /// simulator-screen coordinates (origin top-left, 0-1 normalized).
    private func viewPoint(event: NSEvent, in bounds: CGRect) -> CGPoint {
        guard let window = event.window else {
            return CGPoint(x: 0, y: 0)
        }
        let windowPoint = event.locationInWindow
        let viewPoint = window.contentView?.convert(windowPoint, to: nil) ?? windowPoint
        // Flip Y (AppKit → UIKit-ish) and normalize.
        let normalizedX = max(0, min(1, viewPoint.x / bounds.width))
        let normalizedY = max(0, min(1, 1 - (viewPoint.y / bounds.height)))
        return CGPoint(x: normalizedX, y: normalizedY)
    }
}
