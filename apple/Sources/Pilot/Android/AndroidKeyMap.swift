import Foundation

/// Compile-time macOS key-code → Android keyevent translation, plus the
/// printable-vs-control routing decision. Mirrors `HIDKeyMap`'s role for the
/// simulator pane. Only codes in this table ever reach `input keyevent`.
enum AndroidKeyMap {
    /// Android keyevent codes used by the pane (KeyEvent.KEYCODE_*).
    enum Keycode {
        static let back = 4
        static let home = 3
        static let appSwitch = 187
        static let power = 26
        static let enter = 66
        static let del = 67  // backspace
        static let forwardDel = 112
        static let tab = 61
        static let dpadUp = 19
        static let dpadDown = 20
        static let dpadLeft = 21
        static let dpadRight = 22
        static let pageUp = 92
        static let pageDown = 93
        static let moveHome = 122
        static let moveEnd = 123
        static let volumeUp = 24
        static let volumeDown = 25
        static let wakeup = 224
    }

    /// macOS virtual key codes (Carbon `kVK_*`) → Android keyevents for the
    /// non-printable keys the mirror forwards. Printable characters go through
    /// `input text` instead (see `AndroidDeviceSession.type`).
    private static let macKeyCodeToAndroid: [UInt16: Int] = [
        36: Keycode.enter,        // Return
        76: Keycode.enter,        // Keypad Enter
        51: Keycode.del,          // Delete (backspace)
        117: Keycode.forwardDel,  // Forward Delete
        48: Keycode.tab,          // Tab
        53: Keycode.back,         // Escape → Android Back (the useful mapping)
        126: Keycode.dpadUp,      // Arrow Up
        125: Keycode.dpadDown,    // Arrow Down
        123: Keycode.dpadLeft,    // Arrow Left
        124: Keycode.dpadRight,   // Arrow Right
        116: Keycode.pageUp,      // Page Up
        121: Keycode.pageDown,    // Page Down
        115: Keycode.moveHome,    // Home
        119: Keycode.moveEnd,     // End
    ]

    static func androidKeycode(forMacKeyCode keyCode: UInt16) -> Int? {
        macKeyCodeToAndroid[keyCode]
    }
}
