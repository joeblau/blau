import CoreGraphics
import Foundation
import ObjectiveC

/// Injects touch + keyboard straight into a booted simulator via SimulatorKit's
/// `SimDeviceLegacyHIDClient` and the dlsym'd `IndigoHIDMessageFor*` builders —
/// ported from serve-sim's `HIDInjector`. Coordinates are normalized 0…1.
/// No CGEvent, no Accessibility, no window. `@unchecked Sendable`: every send is
/// serialized on `inputQueue`.
final class SimulatorHID: @unchecked Sendable {
    private typealias MouseFunc = @convention(c) (
        UnsafePointer<CGPoint>, UnsafePointer<CGPoint>?, UInt32, Int32, CGFloat, CGFloat, UInt32
    ) -> UnsafeMutableRawPointer?
    private typealias KeyboardFunc = @convention(c) (UInt32, UInt32) -> UnsafeMutableRawPointer?

    private let hidClient: NSObject
    private let sendSel: Selector
    private let mouseFunc: MouseFunc
    private let keyboardFunc: KeyboardFunc?
    private let inputQueue = DispatchQueue(label: "app.blau.simulator.hid")

    /// Digitizer HID target — the value that's honored for touch on Xcode 26/27.
    private static let touchTarget: UInt32 = 0x32

    init(deviceUDID: String) throws {
        SimPrivateFrameworks.load()
        guard let device = SimPrivateFrameworks.findDevice(udid: deviceUDID) else {
            throw Self.error(1, "Simulator not found")
        }
        guard let mousePtr = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "IndigoHIDMessageForMouseNSEvent") else {
            throw Self.error(2, "IndigoHIDMessageForMouseNSEvent unavailable")
        }
        self.mouseFunc = unsafeBitCast(mousePtr, to: MouseFunc.self)
        self.keyboardFunc = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "IndigoHIDMessageForKeyboardArbitrary")
            .map { unsafeBitCast($0, to: KeyboardFunc.self) }

        guard let hidClass = NSClassFromString("_TtC12SimulatorKit24SimDeviceLegacyHIDClient") else {
            throw Self.error(3, "SimDeviceLegacyHIDClient not found")
        }
        let initSel = NSSelectorFromString("initWithDevice:error:")
        typealias InitFunc = @convention(c) (AnyObject, Selector, AnyObject, AutoreleasingUnsafeMutablePointer<NSError?>) -> AnyObject?
        guard let initIMP = class_getMethodImplementation(hidClass, initSel),
              let allocated = class_createInstance(hidClass, 0) else {
            throw Self.error(4, "Cannot allocate HID client")
        }
        let initFunc = unsafeBitCast(initIMP, to: InitFunc.self)
        var err: NSError?
        let client = initFunc(allocated as AnyObject, initSel, device, &err)
        if let err { throw err }
        guard let clientObj = client as? NSObject else {
            throw Self.error(5, "Failed to create HID client")
        }
        self.hidClient = clientObj
        self.sendSel = NSSelectorFromString("sendWithMessage:freeWhenDone:completionQueue:completion:")
    }

    // MARK: - Touch / gestures

    enum TouchPhase { case down, move, up }

    /// Edge values for `IndigoHIDMessageForMouseNSEvent`. `.bottom` makes iOS
    /// recognize a swipe up from the bottom edge as the Home gesture.
    enum Edge: UInt32 { case none = 0, left = 1, top = 2, bottom = 3, right = 4 }

    private func eventType(_ phase: TouchPhase) -> Int32 { phase == .up ? 2 : 1 }
    private func clamp(_ v: Double) -> Double { min(max(v, 0.001), 0.999) }

    /// Single-finger touch at normalized (x, y) in 0…1.
    func sendTouch(_ phase: TouchPhase, x: Double, y: Double, edge: Edge = .none) {
        // The C builder rejects "dragged" (6); down and move both use 1, up uses 2.
        var point = CGPoint(x: clamp(x), y: clamp(y))
        guard let msg = mouseFunc(&point, nil, Self.touchTarget, eventType(phase), 1.0, 1.0, edge.rawValue) else { return }
        inputQueue.async { [self] in rawSend(msg) }
    }

    /// Two-finger touch (pinch / multi-touch) at normalized coords.
    func sendMultiTouch(_ phase: TouchPhase, x1: Double, y1: Double, x2: Double, y2: Double) {
        var p1 = CGPoint(x: clamp(x1), y: clamp(y1))
        var p2 = CGPoint(x: clamp(x2), y: clamp(y2))
        guard let msg = mouseFunc(&p1, &p2, Self.touchTarget, eventType(phase), 1.0, 1.0, 0) else { return }
        inputQueue.async { [self] in rawSend(msg) }
    }

    // MARK: Scroll — a stateful synthesized drag (serve-sim technique)

    private var scrollActive = false
    private var scrollAnchor = CGPoint(x: 0.5, y: 0.5)
    private var scrollFinger = CGPoint(x: 0.5, y: 0.5)
    private var scrollEndWork: DispatchWorkItem?
    private static let scrollGain = 1.6
    private static let scrollEdgeMargin = 0.08
    private static let scrollIdle = 0.12

    /// `dx`/`dy` are NORMALIZED deltas (fraction of the screen); `anchor` is the
    /// cursor in 0…1, so iOS hit-tests the scroll view under the pointer.
    func sendScroll(normalizedDX dx: Double, normalizedDY dy: Double, anchorX: Double, anchorY: Double) {
        guard dx.isFinite, dy.isFinite, dx != 0 || dy != 0 else { return }
        // The finger moves opposite to the content.
        let stepX = -dx * Self.scrollGain
        let stepY = -dy * Self.scrollGain
        let anchor = CGPoint(x: clamp(anchorX), y: clamp(anchorY))
        inputQueue.async { [self] in
            if !scrollActive {
                scrollAnchor = anchor
                scrollFinger = anchor
                rawTouch(1, scrollFinger)
                scrollActive = true
            }
            var next = CGPoint(x: scrollFinger.x + stepX, y: scrollFinger.y + stepY)
            // Near an edge: lift, re-anchor under the cursor, keep going.
            if next.x <= Self.scrollEdgeMargin || next.x >= 1 - Self.scrollEdgeMargin ||
               next.y <= Self.scrollEdgeMargin || next.y >= 1 - Self.scrollEdgeMargin {
                rawTouch(2, scrollFinger)
                scrollFinger = scrollAnchor
                rawTouch(1, scrollFinger)
                next = CGPoint(x: scrollFinger.x + stepX, y: scrollFinger.y + stepY)
            }
            scrollFinger = CGPoint(x: clamp(next.x), y: clamp(next.y))
            rawTouch(1, scrollFinger)

            scrollEndWork?.cancel()
            let work = DispatchWorkItem { [self] in
                guard scrollActive else { return }
                rawTouch(2, scrollFinger)
                scrollActive = false
            }
            scrollEndWork = work
            inputQueue.asyncAfter(deadline: .now() + Self.scrollIdle, execute: work)
        }
    }

    /// Synchronous single-finger touch (call only on `inputQueue`).
    private func rawTouch(_ type: Int32, _ point: CGPoint) {
        var p = CGPoint(x: clamp(point.x), y: clamp(point.y))
        if let msg = mouseFunc(&p, nil, Self.touchTarget, type, 1.0, 1.0, 0) { rawSend(msg) }
    }

    // MARK: - Keyboard

    /// Send a USB HID keyboard event (Usage Page 0x07) by raw usage code.
    func sendKeyUsage(_ usage: UInt32, down: Bool) {
        guard let keyboardFunc, let msg = keyboardFunc(usage, down ? 1 : 2) else { return }
        inputQueue.async { [self] in rawSend(msg) }
    }

    // MARK: - Send

    private func rawSend(_ msg: UnsafeMutableRawPointer) {
        guard let cls = object_getClass(hidClient),
              let sendIMP = class_getMethodImplementation(cls, sendSel) else { free(msg); return }
        typealias SendFunc = @convention(c) (AnyObject, Selector, UnsafeMutableRawPointer, ObjCBool, AnyObject?, AnyObject?) -> Void
        unsafeBitCast(sendIMP, to: SendFunc.self)(hidClient, sendSel, msg, ObjCBool(true), nil, nil)
    }

    private static func error(_ code: Int, _ message: String) -> NSError {
        NSError(domain: "SimulatorHID", code: code, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

/// macOS virtual key codes (`NSEvent.keyCode`) → USB HID usage codes (page 0x07).
enum HIDKeyMap {
    /// Modifier usages, so the host view can press/release them on `flagsChanged`.
    static let leftShift: UInt32 = 0xE1
    static let leftControl: UInt32 = 0xE0
    static let leftOption: UInt32 = 0xE2
    static let leftCommand: UInt32 = 0xE3

    static func usage(forKeyCode keyCode: UInt16) -> UInt32? { table[keyCode] }

    private static let table: [UInt16: UInt32] = [
        0x00: 0x04, 0x0B: 0x05, 0x08: 0x06, 0x02: 0x07, 0x0E: 0x08, // a b c d e
        0x03: 0x09, 0x05: 0x0A, 0x04: 0x0B, 0x22: 0x0C, 0x26: 0x0D, // f g h i j
        0x28: 0x0E, 0x25: 0x0F, 0x2E: 0x10, 0x2D: 0x11, 0x1F: 0x12, // k l m n o
        0x23: 0x13, 0x0C: 0x14, 0x0F: 0x15, 0x01: 0x16, 0x11: 0x17, // p q r s t
        0x20: 0x18, 0x09: 0x19, 0x0D: 0x1A, 0x07: 0x1B, 0x10: 0x1C, // u v w x y
        0x06: 0x1D,                                                  // z
        0x12: 0x1E, 0x13: 0x1F, 0x14: 0x20, 0x15: 0x21, 0x17: 0x22, // 1 2 3 4 5
        0x16: 0x23, 0x1A: 0x24, 0x1C: 0x25, 0x19: 0x26, 0x1D: 0x27, // 6 7 8 9 0
        0x24: 0x28, // return
        0x35: 0x29, // escape
        0x33: 0x2A, // delete (backspace)
        0x30: 0x2B, // tab
        0x31: 0x2C, // space
        0x1B: 0x2D, 0x18: 0x2E, 0x21: 0x2F, 0x1E: 0x30, 0x2A: 0x31, // - = [ ] \
        0x29: 0x33, 0x27: 0x34, 0x32: 0x35, 0x2B: 0x36, 0x2F: 0x37, // ; ' ` , .
        0x2C: 0x38, // /
        0x7C: 0x4F, 0x7B: 0x50, 0x7D: 0x51, 0x7E: 0x52, // → ← ↓ ↑
    ]
}
