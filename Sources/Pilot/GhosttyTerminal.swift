import AppKit
import Carbon.HIToolbox
import SwiftUI
import GhosttyKit

// MARK: - Ghostty App Singleton

/// Manages the global Ghostty app instance. One per process.
final class GhosttyRuntime: @unchecked Sendable {
    static let shared = GhosttyRuntime()

    private(set) var app: ghostty_app_t?
    private(set) var config: ghostty_config_t?

    private init() {
        // Initialize the Ghostty library
        ghostty_init(0, nil)

        // Create and finalize config
        guard let cfg = ghostty_config_new() else { return }
        ghostty_config_load_default_files(cfg)

        // Set background to match macOS window background
        let bgConfigPath = Self.writeBackgroundConfig()
        if let bgConfigPath {
            bgConfigPath.withCString { path in
                ghostty_config_load_file(cfg, path)
            }
        }

        ghostty_config_finalize(cfg)
        self.config = cfg

        // Clean up temp file
        if let bgConfigPath {
            try? FileManager.default.removeItem(atPath: bgConfigPath)
        }

        // Create the runtime config with C callbacks
        var runtime_cfg = ghostty_runtime_config_s(
            userdata: Unmanaged.passUnretained(self).toOpaque(),
            supports_selection_clipboard: false,
            wakeup_cb: { _ in
                DispatchQueue.main.async {
                    GhosttyRuntime.shared.tick()
                }
            },
            action_cb: { app, target, action in
                return GhosttyRuntime.handleAction(app, target: target, action: action)
            },
            read_clipboard_cb: { _, _, _ in false },
            confirm_read_clipboard_cb: { _, _, _, _ in },
            write_clipboard_cb: { _, loc, content, len, _ in
                guard let content, len > 0 else { return }
                guard let dataPtr = content.pointee.data else { return }
                let str = String(cString: dataPtr)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(str, forType: .string)
            },
            close_surface_cb: { _, _ in }
        )

        guard let ghosttyApp = ghostty_app_new(&runtime_cfg, cfg) else { return }
        self.app = ghosttyApp
    }

    func tick() {
        guard let app else { return }
        ghostty_app_tick(app)
    }

    private static func handleAction(_ app: ghostty_app_t?, target: ghostty_target_s, action: ghostty_action_s) -> Bool {
        switch action.tag {
        case GHOSTTY_ACTION_RENDER:
            NotificationCenter.default.post(name: .ghosttyNeedsDisplay, object: nil)
            return true
        case GHOSTTY_ACTION_SET_TITLE, GHOSTTY_ACTION_CELL_SIZE, GHOSTTY_ACTION_MOUSE_SHAPE,
             GHOSTTY_ACTION_MOUSE_VISIBILITY, GHOSTTY_ACTION_MOUSE_OVER_LINK,
             GHOSTTY_ACTION_RENDERER_HEALTH, GHOSTTY_ACTION_PWD,
             GHOSTTY_ACTION_SCROLLBAR, GHOSTTY_ACTION_COLOR_CHANGE,
             GHOSTTY_ACTION_RING_BELL, GHOSTTY_ACTION_CONFIG_CHANGE:
            return true
        default:
            return false
        }
    }

    /// Resolves the current macOS window background color and writes a temporary
    /// Ghostty config file that sets `background` to match.
    private static func writeBackgroundConfig() -> String? {
        guard let color = NSColor.windowBackgroundColor.usingColorSpace(.sRGB) else { return nil }
        let r = Int(color.redComponent * 255)
        let g = Int(color.greenComponent * 255)
        let b = Int(color.blueComponent * 255)
        let hex = String(format: "#%02x%02x%02x", r, g, b)

        let path = NSTemporaryDirectory() + "ghostty-bg-\(ProcessInfo.processInfo.processIdentifier).conf"
        let content = "background = \(hex)\n"
        do {
            try content.write(toFile: path, atomically: true, encoding: .utf8)
            return path
        } catch {
            return nil
        }
    }

    deinit {
        if let app { ghostty_app_free(app) }
        if let config { ghostty_config_free(config) }
    }
}

// MARK: - Metal Surface NSView

/// An NSView that hosts a Ghostty terminal surface with Metal rendering.
/// The surface creates its own Metal renderer using the NSView's layer.
@MainActor
class GhosttyMetalView: NSView, CALayerDelegate, NSTextInputClient {
    var surface: ghostty_surface_t?
    private var renderObserver: NSObjectProtocol?
    private var trackingArea: NSTrackingArea?

    init(app: ghostty_app_t) {
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        wantsLayer = true

        // Create the surface - Ghostty will set up Metal on the layer itself
        var surfaceCfg = ghostty_surface_config_new()
        surfaceCfg.userdata = Unmanaged.passUnretained(self).toOpaque()
        surfaceCfg.platform_tag = GHOSTTY_PLATFORM_MACOS
        surfaceCfg.platform = ghostty_platform_u(
            macos: ghostty_platform_macos_s(
                nsview: Unmanaged.passUnretained(self).toOpaque()
            )
        )
        surfaceCfg.scale_factor = Double(NSScreen.main?.backingScaleFactor ?? 2.0)

        guard let surface = ghostty_surface_new(app, &surfaceCfg) else { return }
        self.surface = surface

        // Listen for render notifications
        renderObserver = NotificationCenter.default.addObserver(
            forName: .ghosttyNeedsDisplay,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.needsDisplay = true
            }
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    nonisolated deinit {
        // Cleanup handled by removeFromSuperview / NSView lifecycle
    }

    override func removeFromSuperview() {
        if let renderObserver {
            NotificationCenter.default.removeObserver(renderObserver)
            self.renderObserver = nil
        }
        if let surface {
            ghostty_surface_free(surface)
            self.surface = nil
        }
        super.removeFromSuperview()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        )
        addTrackingArea(trackingArea!)
    }

    override func layout() {
        super.layout()
        guard let surface else { return }
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        let w = UInt32(bounds.width * scale)
        let h = UInt32(bounds.height * scale)
        ghostty_surface_set_size(surface, w, h)
        ghostty_surface_set_content_scale(surface, Double(scale), Double(scale))
    }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func becomeFirstResponder() -> Bool {
        if let surface { ghostty_surface_set_focus(surface, true) }
        return super.becomeFirstResponder()
    }

    override func resignFirstResponder() -> Bool {
        if let surface { ghostty_surface_set_focus(surface, false) }
        return super.resignFirstResponder()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            window.makeFirstResponder(self)
            if let surface = self.surface {
                let scale = window.backingScaleFactor
                ghostty_surface_set_content_scale(surface, Double(scale), Double(scale))
            }
        }
    }

    // Text accumulated during keyDown via insertText
    private var keyTextAccumulator: [String]?

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        guard let surface else { return }

        let action = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS

        // Accumulate text from interpretKeyEvents
        keyTextAccumulator = []
        defer { keyTextAccumulator = nil }

        interpretKeyEvents([event])

        if let texts = keyTextAccumulator, !texts.isEmpty {
            if shouldSendTextDirectly(for: event) {
                for text in texts {
                    text.utf8CString.withUnsafeBufferPointer { buffer in
                        guard let ptr = buffer.baseAddress else { return }
                        ghostty_surface_text(surface, ptr, UInt(text.utf8.count))
                    }
                }
                return
            }

            for text in texts {
                text.withCString { ptr in
                    var key = makeKey(event, action: action)
                    key.text = ptr
                    _ = ghostty_surface_key(surface, key)
                }
            }
        } else {
            let key = makeKey(event, action: action)
            _ = ghostty_surface_key(surface, key)
        }
    }

    override func keyUp(with event: NSEvent) {
        guard let surface else { return }
        guard !shouldSendTextDirectly(for: event) else { return }
        let key = makeKey(event, action: GHOSTTY_ACTION_RELEASE)
        _ = ghostty_surface_key(surface, key)
    }

    override func flagsChanged(with event: NSEvent) {
        super.flagsChanged(with: event)
    }

    // MARK: - NSTextInputClient

    func insertText(_ string: Any, replacementRange: NSRange) {
        let str: String
        if let s = string as? NSAttributedString {
            str = s.string
        } else if let s = string as? String {
            str = s
        } else {
            return
        }
        keyTextAccumulator?.append(str)
    }

    override func doCommand(by selector: Selector) {
        // Handle commands like insertNewline, deleteBackward, etc.
        // These are already handled by keyDown sending the key event
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {}
    func unmarkText() {}
    func selectedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }
    func markedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }
    func hasMarkedText() -> Bool { false }
    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect { .zero }
    func characterIndex(for point: NSPoint) -> Int { 0 }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard let surface else { return }
        let pt = mousePoint(event)
        ghostty_surface_mouse_pos(surface, pt.x, pt.y, mods(event))
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, mods(event))
    }

    override func mouseUp(with event: NSEvent) {
        guard let surface else { return }
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, mods(event))
    }

    override func mouseMoved(with event: NSEvent) {
        guard let surface else { return }
        let pt = mousePoint(event)
        ghostty_surface_mouse_pos(surface, pt.x, pt.y, mods(event))
    }

    override func mouseDragged(with event: NSEvent) { mouseMoved(with: event) }
    override func rightMouseDown(with event: NSEvent) { mouseDown(with: event) }
    override func rightMouseUp(with event: NSEvent) { mouseUp(with: event) }

    override func scrollWheel(with event: NSEvent) {
        guard let surface else { return }
        ghostty_surface_mouse_scroll(surface, event.scrollingDeltaX, event.scrollingDeltaY, 0)
    }

    // MARK: - Helpers

    private func mousePoint(_ event: NSEvent) -> (x: Double, y: Double) {
        let pt = convert(event.locationInWindow, from: nil)
        return (Double(pt.x), Double(bounds.height - pt.y))
    }

    private func mods(_ event: NSEvent) -> ghostty_input_mods_e {
        var m: UInt32 = 0
        let f = event.modifierFlags
        if f.contains(.shift) { m |= UInt32(GHOSTTY_MODS_SHIFT.rawValue) }
        if f.contains(.control) { m |= UInt32(GHOSTTY_MODS_CTRL.rawValue) }
        if f.contains(.option) { m |= UInt32(GHOSTTY_MODS_ALT.rawValue) }
        if f.contains(.command) { m |= UInt32(GHOSTTY_MODS_SUPER.rawValue) }
        return ghostty_input_mods_e(rawValue: m)
    }

    private func shouldSendTextDirectly(for event: NSEvent) -> Bool {
        let blocked: NSEvent.ModifierFlags = [.command, .control]
        guard event.modifierFlags.intersection(blocked).isEmpty else { return false }
        guard let chars = event.characters, !chars.isEmpty else { return false }
        return chars.unicodeScalars.contains(where: { !CharacterSet.controlCharacters.contains($0) })
    }

    private func ghosttyKeyCode(for event: NSEvent) -> ghostty_input_key_e {
        switch Int(event.keyCode) {
        case kVK_Return:
            return GHOSTTY_KEY_ENTER
        case kVK_ANSI_KeypadEnter:
            return GHOSTTY_KEY_NUMPAD_ENTER
        case kVK_Delete:
            return GHOSTTY_KEY_BACKSPACE
        case kVK_ForwardDelete:
            return GHOSTTY_KEY_DELETE
        case kVK_Tab:
            return GHOSTTY_KEY_TAB
        case kVK_Space:
            return GHOSTTY_KEY_SPACE
        case kVK_Escape:
            return GHOSTTY_KEY_ESCAPE
        case kVK_LeftArrow:
            return GHOSTTY_KEY_ARROW_LEFT
        case kVK_RightArrow:
            return GHOSTTY_KEY_ARROW_RIGHT
        case kVK_DownArrow:
            return GHOSTTY_KEY_ARROW_DOWN
        case kVK_UpArrow:
            return GHOSTTY_KEY_ARROW_UP
        case kVK_Home:
            return GHOSTTY_KEY_HOME
        case kVK_End:
            return GHOSTTY_KEY_END
        case kVK_PageUp:
            return GHOSTTY_KEY_PAGE_UP
        case kVK_PageDown:
            return GHOSTTY_KEY_PAGE_DOWN
        case kVK_Help:
            return GHOSTTY_KEY_HELP
        default:
            break
        }

        guard let scalar = event.charactersIgnoringModifiers?.unicodeScalars.first else {
            return GHOSTTY_KEY_UNIDENTIFIED
        }

        switch scalar {
        case "a", "A": return GHOSTTY_KEY_A
        case "b", "B": return GHOSTTY_KEY_B
        case "c", "C": return GHOSTTY_KEY_C
        case "d", "D": return GHOSTTY_KEY_D
        case "e", "E": return GHOSTTY_KEY_E
        case "f", "F": return GHOSTTY_KEY_F
        case "g", "G": return GHOSTTY_KEY_G
        case "h", "H": return GHOSTTY_KEY_H
        case "i", "I": return GHOSTTY_KEY_I
        case "j", "J": return GHOSTTY_KEY_J
        case "k", "K": return GHOSTTY_KEY_K
        case "l", "L": return GHOSTTY_KEY_L
        case "m", "M": return GHOSTTY_KEY_M
        case "n", "N": return GHOSTTY_KEY_N
        case "o", "O": return GHOSTTY_KEY_O
        case "p", "P": return GHOSTTY_KEY_P
        case "q", "Q": return GHOSTTY_KEY_Q
        case "r", "R": return GHOSTTY_KEY_R
        case "s", "S": return GHOSTTY_KEY_S
        case "t", "T": return GHOSTTY_KEY_T
        case "u", "U": return GHOSTTY_KEY_U
        case "v", "V": return GHOSTTY_KEY_V
        case "w", "W": return GHOSTTY_KEY_W
        case "x", "X": return GHOSTTY_KEY_X
        case "y", "Y": return GHOSTTY_KEY_Y
        case "z", "Z": return GHOSTTY_KEY_Z
        case "0": return GHOSTTY_KEY_DIGIT_0
        case "1": return GHOSTTY_KEY_DIGIT_1
        case "2": return GHOSTTY_KEY_DIGIT_2
        case "3": return GHOSTTY_KEY_DIGIT_3
        case "4": return GHOSTTY_KEY_DIGIT_4
        case "5": return GHOSTTY_KEY_DIGIT_5
        case "6": return GHOSTTY_KEY_DIGIT_6
        case "7": return GHOSTTY_KEY_DIGIT_7
        case "8": return GHOSTTY_KEY_DIGIT_8
        case "9": return GHOSTTY_KEY_DIGIT_9
        case "`", "~": return GHOSTTY_KEY_BACKQUOTE
        case "\\", "|": return GHOSTTY_KEY_BACKSLASH
        case "[", "{": return GHOSTTY_KEY_BRACKET_LEFT
        case "]", "}": return GHOSTTY_KEY_BRACKET_RIGHT
        case ",", "<": return GHOSTTY_KEY_COMMA
        case "=", "+": return GHOSTTY_KEY_EQUAL
        case "-","_": return GHOSTTY_KEY_MINUS
        case ".", ">": return GHOSTTY_KEY_PERIOD
        case "'", "\"": return GHOSTTY_KEY_QUOTE
        case ";", ":": return GHOSTTY_KEY_SEMICOLON
        case "/", "?": return GHOSTTY_KEY_SLASH
        default: return GHOSTTY_KEY_UNIDENTIFIED
        }
    }

    private func unshiftedCodepoint(for event: NSEvent) -> UInt32 {
        guard let scalar = event.charactersIgnoringModifiers?.unicodeScalars.first else {
            return 0
        }

        return scalar.value
    }

    private func makeKey(_ event: NSEvent, action: ghostty_input_action_e) -> ghostty_input_key_s {
        let text: UnsafePointer<CChar>? = nil
        let mods = mods(event)
        return ghostty_input_key_s(
            action: action,
            mods: mods,
            consumed_mods: surface.map { ghostty_surface_key_translation_mods($0, mods) } ?? GHOSTTY_MODS_NONE,
            keycode: UInt32(ghosttyKeyCode(for: event).rawValue),
            text: text,
            unshifted_codepoint: unshiftedCodepoint(for: event),
            composing: false
        )
    }
}

// MARK: - Notification

extension Notification.Name {
    static let ghosttyNeedsDisplay = Notification.Name("ghosttyNeedsDisplay")
}

// MARK: - SwiftUI Wrapper

struct GhosttyTerminalView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        guard let app = GhosttyRuntime.shared.app else {
            let v = NSView()
            v.wantsLayer = true
            v.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            return v
        }
        let view = GhosttyMetalView(app: app)
        // Ensure the view can become first responder for keyboard input
        DispatchQueue.main.async {
            view.window?.makeFirstResponder(view)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
