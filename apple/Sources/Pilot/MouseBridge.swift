import ApplicationServices
import CoreGraphics
import Foundation

@MainActor
final class MouseBridge {
    static let shared = MouseBridge()
    private let trustedCheckOptionPromptKey = "AXTrustedCheckOptionPrompt" as CFString

    func ensurePermissions() -> Bool {
        let trusted = AXIsProcessTrusted()
        if !trusted {
            let opts = [trustedCheckOptionPromptKey: true] as CFDictionary
            AXIsProcessTrustedWithOptions(opts)
        }
        return trusted
    }

    func move(dx: Float, dy: Float) {
        let loc = CGEvent(source: nil)?.location ?? .zero
        let dest = CGPoint(x: loc.x + CGFloat(dx), y: loc.y + CGFloat(dy))
        let event = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                            mouseCursorPosition: dest, mouseButton: .left)
        event?.post(tap: .cghidEventTap)
    }

    func click() {
        let loc = CGEvent(source: nil)?.location ?? .zero
        let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown,
                           mouseCursorPosition: loc, mouseButton: .left)
        let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp,
                         mouseCursorPosition: loc, mouseButton: .left)
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}
