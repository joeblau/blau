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
        case GHOSTTY_ACTION_PWD:
            guard target.tag == GHOSTTY_TARGET_SURFACE else { return true }
            guard let pwd = action.action.pwd.pwd else { return true }
            let surfaceID = UInt(bitPattern: target.target.surface)
            NotificationCenter.default.post(
                name: .ghosttyWorkingDirectoryDidChange,
                object: nil,
                userInfo: [
                    "surfaceID": surfaceID,
                    "pwd": String(cString: pwd),
                ]
            )
            return true
        case GHOSTTY_ACTION_SET_TITLE, GHOSTTY_ACTION_CELL_SIZE, GHOSTTY_ACTION_MOUSE_SHAPE,
             GHOSTTY_ACTION_MOUSE_VISIBILITY, GHOSTTY_ACTION_MOUSE_OVER_LINK,
             GHOSTTY_ACTION_RENDERER_HEALTH,
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
class GhosttyMetalView: NSView, CALayerDelegate {
    var surface: ghostty_surface_t?
    private var renderObserver: NSObjectProtocol?
    private var trackingArea: NSTrackingArea?
    private let pane: Pane

    init(app: ghostty_app_t, pane: Pane) {
        self.pane = pane
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

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleWorkingDirectoryDidChange(_:)),
            name: .ghosttyWorkingDirectoryDidChange,
            object: nil
        )
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
        NotificationCenter.default.removeObserver(self, name: .ghosttyWorkingDirectoryDidChange, object: nil)
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
        guard let surface else {
            interpretKeyEvents([event])
            return
        }

        let translationModsGhostty = eventModifierFlags(
            mods: ghostty_surface_key_translation_mods(surface, ghosttyMods(event.modifierFlags))
        )

        var translationMods = event.modifierFlags
        for flag in [NSEvent.ModifierFlags.shift, .control, .option, .command] {
            if translationModsGhostty.contains(flag) {
                translationMods.insert(flag)
            } else {
                translationMods.remove(flag)
            }
        }

        let translationEvent: NSEvent
        if translationMods == event.modifierFlags {
            translationEvent = event
        } else {
            translationEvent = NSEvent.keyEvent(
                with: event.type,
                location: event.locationInWindow,
                modifierFlags: translationMods,
                timestamp: event.timestamp,
                windowNumber: event.windowNumber,
                context: nil,
                characters: event.characters(byApplyingModifiers: translationMods) ?? "",
                charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
                isARepeat: event.isARepeat,
                keyCode: event.keyCode
            ) ?? event
        }

        let action = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS
        keyTextAccumulator = []
        defer { keyTextAccumulator = nil }

        interpretKeyEvents([translationEvent])

        if let texts = keyTextAccumulator, !texts.isEmpty {
            for text in texts {
                _ = keyAction(action, event: event, translationEvent: translationEvent, text: text)
            }
        } else {
            _ = keyAction(
                action,
                event: event,
                translationEvent: translationEvent,
                text: translationEvent.ghosttyCharacters
            )
        }
    }

    override func keyUp(with event: NSEvent) {
        _ = keyAction(GHOSTTY_ACTION_RELEASE, event: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        guard surface != nil else { return false }
        guard event.timestamp != 0 else { return false }
        guard event.modifierFlags.contains(.command) || event.modifierFlags.contains(.control) else {
            return false
        }

        keyDown(with: event)
        return true
    }

    override func flagsChanged(with event: NSEvent) {
        let mod: UInt32
        switch event.keyCode {
        case 0x39:
            mod = GHOSTTY_MODS_CAPS.rawValue
        case 0x38, 0x3C:
            mod = GHOSTTY_MODS_SHIFT.rawValue
        case 0x3B, 0x3E:
            mod = GHOSTTY_MODS_CTRL.rawValue
        case 0x3A, 0x3D:
            mod = GHOSTTY_MODS_ALT.rawValue
        case 0x37, 0x36:
            mod = GHOSTTY_MODS_SUPER.rawValue
        default:
            return
        }

        let mods = ghosttyMods(event.modifierFlags)
        var action = GHOSTTY_ACTION_RELEASE
        if mods.rawValue & mod != 0 {
            let sidePressed: Bool
            switch event.keyCode {
            case 0x3C:
                sidePressed = event.modifierFlags.rawValue & UInt(NX_DEVICERSHIFTKEYMASK) != 0
            case 0x3E:
                sidePressed = event.modifierFlags.rawValue & UInt(NX_DEVICERCTLKEYMASK) != 0
            case 0x3D:
                sidePressed = event.modifierFlags.rawValue & UInt(NX_DEVICERALTKEYMASK) != 0
            case 0x36:
                sidePressed = event.modifierFlags.rawValue & UInt(NX_DEVICERCMDKEYMASK) != 0
            default:
                sidePressed = true
            }

            if sidePressed {
                action = GHOSTTY_ACTION_PRESS
            }
        }

        _ = keyAction(action, event: event)
    }

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
        ghosttyMods(event.modifierFlags)
    }

    private func keyAction(
        _ action: ghostty_input_action_e,
        event: NSEvent,
        translationEvent: NSEvent? = nil,
        text: String? = nil,
        composing: Bool = false
    ) -> Bool {
        guard let surface else { return false }

        var key = event.ghosttyKeyEvent(action, translationMods: translationEvent?.modifierFlags)
        key.composing = composing

        if let text,
           text.count > 0,
           let codepoint = text.utf8.first,
           codepoint >= 0x20 {
            return text.withCString { ptr in
                key.text = ptr
                return ghostty_surface_key(surface, key)
            }
        }

        return ghostty_surface_key(surface, key)
    }

    @objc
    private func handleWorkingDirectoryDidChange(_ notification: Notification) {
        guard let changedSurfaceID = notification.userInfo?["surfaceID"] as? UInt else { return }
        guard let surface else { return }
        guard changedSurfaceID == UInt(bitPattern: surface) else { return }
        guard let pwd = notification.userInfo?["pwd"] as? String else { return }
        pane.terminalState.currentDirectory = pwd
    }
}

// MARK: - NSTextInputClient

extension GhosttyMetalView: @MainActor NSTextInputClient {
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
}

// MARK: - Notification

extension Notification.Name {
    static let ghosttyNeedsDisplay = Notification.Name("ghosttyNeedsDisplay")
    static let ghosttyWorkingDirectoryDidChange = Notification.Name("ghosttyWorkingDirectoryDidChange")
}

private func eventModifierFlags(mods: ghostty_input_mods_e) -> NSEvent.ModifierFlags {
    var flags = NSEvent.ModifierFlags()
    if mods.rawValue & GHOSTTY_MODS_SHIFT.rawValue != 0 { flags.insert(.shift) }
    if mods.rawValue & GHOSTTY_MODS_CTRL.rawValue != 0 { flags.insert(.control) }
    if mods.rawValue & GHOSTTY_MODS_ALT.rawValue != 0 { flags.insert(.option) }
    if mods.rawValue & GHOSTTY_MODS_SUPER.rawValue != 0 { flags.insert(.command) }
    return flags
}

private func ghosttyMods(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
    var mods: UInt32 = GHOSTTY_MODS_NONE.rawValue

    if flags.contains(.shift) { mods |= GHOSTTY_MODS_SHIFT.rawValue }
    if flags.contains(.control) { mods |= GHOSTTY_MODS_CTRL.rawValue }
    if flags.contains(.option) { mods |= GHOSTTY_MODS_ALT.rawValue }
    if flags.contains(.command) { mods |= GHOSTTY_MODS_SUPER.rawValue }
    if flags.contains(.capsLock) { mods |= GHOSTTY_MODS_CAPS.rawValue }

    let rawFlags = flags.rawValue
    if rawFlags & UInt(NX_DEVICERSHIFTKEYMASK) != 0 { mods |= GHOSTTY_MODS_SHIFT_RIGHT.rawValue }
    if rawFlags & UInt(NX_DEVICERCTLKEYMASK) != 0 { mods |= GHOSTTY_MODS_CTRL_RIGHT.rawValue }
    if rawFlags & UInt(NX_DEVICERALTKEYMASK) != 0 { mods |= GHOSTTY_MODS_ALT_RIGHT.rawValue }
    if rawFlags & UInt(NX_DEVICERCMDKEYMASK) != 0 { mods |= GHOSTTY_MODS_SUPER_RIGHT.rawValue }

    return ghostty_input_mods_e(rawValue: mods)
}

private extension NSEvent {
    func ghosttyKeyEvent(
        _ action: ghostty_input_action_e,
        translationMods: NSEvent.ModifierFlags? = nil
    ) -> ghostty_input_key_s {
        var key = ghostty_input_key_s()
        key.action = action
        key.keycode = UInt32(keyCode)
        key.text = nil
        key.composing = false

        key.mods = ghosttyMods(modifierFlags)
        key.consumed_mods = ghosttyMods((translationMods ?? modifierFlags).subtracting([.control, .command]))

        if type == .keyDown || type == .keyUp,
           let chars = characters(byApplyingModifiers: []),
           let codepoint = chars.unicodeScalars.first {
            key.unshifted_codepoint = codepoint.value
        } else {
            key.unshifted_codepoint = 0
        }

        return key
    }

    var ghosttyCharacters: String? {
        guard let characters else { return nil }

        if characters.count == 1,
           let scalar = characters.unicodeScalars.first {
            if scalar.value < 0x20 {
                return self.characters(byApplyingModifiers: modifierFlags.subtracting(.control))
            }

            if scalar.value >= 0xF700 && scalar.value <= 0xF8FF {
                return nil
            }
        }

        return characters
    }
}

// MARK: - SwiftUI Wrapper

struct GhosttyTerminalView: NSViewRepresentable {
    let pane: Pane

    func makeNSView(context: Context) -> NSView {
        guard let app = GhosttyRuntime.shared.app else {
            let v = NSView()
            v.wantsLayer = true
            v.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            return v
        }
        let view = GhosttyMetalView(app: app, pane: pane)
        // Ensure the view can become first responder for keyboard input
        DispatchQueue.main.async {
            view.window?.makeFirstResponder(view)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
