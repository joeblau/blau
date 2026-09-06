import Foundation
import Testing
@testable import Pilot

@Suite("Remote desktop dictation keyboard input")
@MainActor
struct RemoteDesktopKeyboardInputTests {
    @Test("Text is fully released before an explicit Enter is pressed")
    func textThenEnterIsOrdered() {
        let input = RemoteDesktopKeyboardInput()
        var events: [RemoteDesktopKeyboardInput.KeyEvent] = []
        let sessionID = input.beginSession { events.append($0); return true }

        #expect(input.sendText("go", sessionID: sessionID))
        #expect(events == keyEvents([0x67, 0x6f]))
        #expect(input.sendEnter(sessionID: sessionID))
        #expect(events == keyEvents([0x67, 0x6f, 0xff0d]))
    }

    @Test("Unicode uses scalar keysyms, preserving accents, punctuation, CJK, and emoji")
    func unicodeTextIsEncodedWithoutUTF16Truncation() {
        let input = RemoteDesktopKeyboardInput()
        var events: [RemoteDesktopKeyboardInput.KeyEvent] = []
        let sessionID = input.beginSession { events.append($0); return true }

        #expect(input.sendText("Ae\u{301}—中👩‍💻", sessionID: sessionID))
        #expect(events == keyEvents([
            0x41, 0xe9, 0x0100_2014, 0x0100_4e2d,
            0x0101_f469, 0x0100_200d, 0x0101_f4bb,
        ]))
    }

    @Test("Dictated line breaks and tabs cannot submit or move focus before Enter")
    func whitespaceDoesNotBecomeControlKeys() {
        let input = RemoteDesktopKeyboardInput()
        var events: [RemoteDesktopKeyboardInput.KeyEvent] = []
        let sessionID = input.beginSession { events.append($0); return true }

        #expect(input.sendText("a\r\nb\tc\u{2028}d\u{2029}e", sessionID: sessionID))
        #expect(events == keyEvents(Array("a b c d e".unicodeScalars.map(\.value))))
        #expect(!events.contains { $0.keysym == 0xff0d || $0.keysym == 0xff09 })
    }

    @Test("Unsupported controls reject the whole payload before any text is inserted",
          arguments: ["run\u{1b}[31m", "run\u{0}", "run\u{7f}", "run\u{9b}", ""])
    func controlsAreRejected(text: String) {
        let input = RemoteDesktopKeyboardInput()
        var events: [RemoteDesktopKeyboardInput.KeyEvent] = []
        let sessionID = input.beginSession { events.append($0); return true }

        #expect(!input.sendText(text, sessionID: sessionID))
        #expect(events.isEmpty)
    }

    @Test("Reconnect rejects stale text and Enter while allowing the new session")
    func reconnectInvalidatesCapturedTarget() {
        let input = RemoteDesktopKeyboardInput()
        var oldEvents: [RemoteDesktopKeyboardInput.KeyEvent] = []
        var newEvents: [RemoteDesktopKeyboardInput.KeyEvent] = []
        let oldID = input.beginSession { oldEvents.append($0); return true }
        input.endSession()
        #expect(input.sessionID == nil)
        #expect(!input.sendText("old", sessionID: oldID))
        #expect(!input.sendEnter(sessionID: oldID))

        let newID = input.beginSession { newEvents.append($0); return true }
        #expect(newID != oldID)
        #expect(!input.sendText("old", sessionID: oldID))
        #expect(!input.sendEnter(sessionID: oldID))
        #expect(oldEvents.isEmpty)
        #expect(newEvents.isEmpty)
        #expect(input.sendText("n", sessionID: newID))
        #expect(input.sendEnter(sessionID: newID))
        #expect(newEvents == keyEvents([0x6e, 0xff0d]))
    }

    @Test("A transport failure releases the current key and blocks a later Enter")
    func failedSendCannotExecutePartialText() {
        let input = RemoteDesktopKeyboardInput()
        var events: [RemoteDesktopKeyboardInput.KeyEvent] = []
        let sessionID = input.beginSession { event in
            events.append(event)
            return !(event.keysym == 0x62 && event.isDown)
        }

        #expect(!input.sendText("abc", sessionID: sessionID))
        #expect(events == keyEvents([0x61, 0x62]))
        #expect(input.sessionID == nil)
        #expect(!input.sendEnter(sessionID: sessionID))
        #expect(events == keyEvents([0x61, 0x62]))
    }

    @Test("Replacing a connection during a send never forwards its remaining keys")
    func replacementDuringSendKeepsBothConnectionsSeparate() {
        let input = RemoteDesktopKeyboardInput()
        var oldEvents: [RemoteDesktopKeyboardInput.KeyEvent] = []
        var newEvents: [RemoteDesktopKeyboardInput.KeyEvent] = []
        let oldID = input.beginSession { event in
            oldEvents.append(event)
            if event.isDown {
                input.beginSession { newEvents.append($0); return true }
            }
            return true
        }

        #expect(!input.sendText("ab", sessionID: oldID))
        #expect(oldEvents == keyEvents([0x61]))
        #expect(newEvents.isEmpty)
        #expect(input.sessionID != oldID)
        #expect(!input.sendEnter(sessionID: oldID))
    }

    private func keyEvents(_ keysyms: [UInt32]) -> [RemoteDesktopKeyboardInput.KeyEvent] {
        keysyms.flatMap { keysym in
            [.init(keysym: keysym, isDown: true), .init(keysym: keysym, isDown: false)]
        }
    }
}
