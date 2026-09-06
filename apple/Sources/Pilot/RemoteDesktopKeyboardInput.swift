import Foundation

/// Keeps dictated text and its later Enter attached to one authenticated VNC
/// connection. Reconnecting the same saved machine always creates a new ID.
@MainActor
final class RemoteDesktopKeyboardInput {
    struct KeyEvent: Equatable {
        let keysym: UInt32
        let isDown: Bool
    }

    typealias Sender = @MainActor (KeyEvent) -> Bool

    private(set) var sessionID: UUID?
    private var sender: Sender?

    @discardableResult
    func beginSession(sender: @escaping Sender) -> UUID {
        let id = UUID()
        sessionID = id
        self.sender = sender
        return id
    }

    func endSession() {
        sessionID = nil
        sender = nil
    }

    func sendText(_ text: String, sessionID: UUID) -> Bool {
        guard let keysyms = Self.textKeysyms(text), !keysyms.isEmpty else { return false }
        return send(keysyms, sessionID: sessionID)
    }

    func sendEnter(sessionID: UUID) -> Bool {
        send([0xff0d], sessionID: sessionID) // X11 XK_Return
    }

    private func send(_ keysyms: [UInt32], sessionID: UUID) -> Bool {
        guard self.sessionID == sessionID, let sender else { return false }
        for keysym in keysyms {
            guard self.sessionID == sessionID else { return false }
            // Enqueue a complete press/release pair on the same connection,
            // without suspending between characters or the following Enter.
            let pressed = sender(KeyEvent(keysym: keysym, isDown: true))
            let released = sender(KeyEvent(keysym: keysym, isDown: false))
            guard pressed && released else {
                if self.sessionID == sessionID { endSession() }
                return false
            }
        }
        return self.sessionID == sessionID
    }

    private static func textKeysyms(_ text: String) -> [UInt32]? {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
            .precomposedStringWithCanonicalMapping
        var keysyms: [UInt32] = []
        for scalar in normalized.unicodeScalars {
            let value = scalar.value
            switch value {
            case 0x09, 0x0a, 0x0d, 0x85, 0x2028, 0x2029:
                // Dictation inserts text; only an explicit Up hold submits it.
                // Literal Tab/Return keystrokes could focus or execute a form.
                keysyms.append(0x20)
            case 0..<0x20, 0x7f...0x9f:
                // Validate the whole payload before inserting any part of it.
                return nil
            case 0x20...0xff:
                keysyms.append(value)
            default:
                // RFB uses X11 keysyms, whose Unicode range is U+0100 and
                // above with bit 24 set; a bare scalar means another key.
                keysyms.append(0x0100_0000 | value)
            }
        }
        return keysyms
    }
}
