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
            read_clipboard_cb: { userdata, loc, state in
                return GhosttyRuntime.readClipboard(userdata, location: loc, state: state)
            },
            confirm_read_clipboard_cb: { userdata, str, state, request in
                GhosttyRuntime.confirmReadClipboard(
                    userdata,
                    string: str,
                    state: state,
                    request: request
                )
            },
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

    private static func readClipboard(
        _ userdata: UnsafeMutableRawPointer?,
        location: ghostty_clipboard_e,
        state: UnsafeMutableRawPointer?
    ) -> Bool {
        guard location == GHOSTTY_CLIPBOARD_STANDARD else { return false }
        guard let surface = surface(from: userdata) else { return false }

        let pasteString: String? = if Thread.isMainThread {
            NSPasteboard.general.string(forType: .string)
        } else {
            DispatchQueue.main.sync {
                NSPasteboard.general.string(forType: .string)
            }
        }

        guard let pasteString, !pasteString.isEmpty else { return false }
        completeClipboardRequest(surface: surface, string: pasteString, state: state)
        return true
    }

    private static func confirmReadClipboard(
        _ userdata: UnsafeMutableRawPointer?,
        string: UnsafePointer<CChar>?,
        state: UnsafeMutableRawPointer?,
        request: ghostty_clipboard_request_e
    ) {
        guard request == GHOSTTY_CLIPBOARD_REQUEST_PASTE else { return }
        guard let surface = surface(from: userdata) else { return }
        guard let string else { return }

        let pasteString = String(cString: string)
        completeClipboardRequest(surface: surface, string: pasteString, state: state, confirmed: true)
    }

    private static func completeClipboardRequest(
        surface: ghostty_surface_t,
        string: String,
        state: UnsafeMutableRawPointer?,
        confirmed: Bool = false
    ) {
        string.withCString { cString in
            ghostty_surface_complete_clipboard_request(surface, cString, state, confirmed)
        }
    }

    private static func surface(from userdata: UnsafeMutableRawPointer?) -> ghostty_surface_t? {
        guard let userdata else { return nil }
        let view = Unmanaged<GhosttyMetalView>.fromOpaque(userdata).takeUnretainedValue()
        return view.callbackSurface
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
        case GHOSTTY_ACTION_RING_BELL:
            guard target.tag == GHOSTTY_TARGET_SURFACE else { return true }
            let surfaceID = UInt(bitPattern: target.target.surface)
            NotificationCenter.default.post(
                name: .ghosttyBellDidRing,
                object: nil,
                userInfo: ["surfaceID": surfaceID]
            )
            return true
        case GHOSTTY_ACTION_SET_TITLE, GHOSTTY_ACTION_CELL_SIZE, GHOSTTY_ACTION_MOUSE_SHAPE,
             GHOSTTY_ACTION_MOUSE_VISIBILITY, GHOSTTY_ACTION_MOUSE_OVER_LINK,
             GHOSTTY_ACTION_RENDERER_HEALTH,
             GHOSTTY_ACTION_SCROLLBAR, GHOSTTY_ACTION_COLOR_CHANGE,
             GHOSTTY_ACTION_CONFIG_CHANGE:
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
        let content = """
        background = \(hex)
        macos-option-as-alt = true
        """
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
    nonisolated(unsafe) fileprivate var callbackSurface: ghostty_surface_t?
    private var renderObserver: NSObjectProtocol?
    private var trackingArea: NSTrackingArea?
    private let pane: Pane

    init(app: ghostty_app_t, pane: Pane) {
        self.pane = pane
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        wantsLayer = true

        // Create the surface - Ghostty will set up Metal on the layer itself
        let rawDirectory = pane.currentDirectory
        let persistedDirectory = Self.validWorkingDirectory(from: rawDirectory)
        print("[Ghostty] Pane \(pane.id): rawDirectory='\(rawDirectory)' persistedDirectory='\(persistedDirectory ?? "nil")'")

        // Install OSC 7 hook silently via ZDOTDIR override.
        // We create a temp .zshenv that installs the precmd hook, then restores
        // the real ZDOTDIR so the user's normal config loads.
        let zdotdir = Self.setupOSC7ZdotDir()
        let envVars: [(key: String, value: String)] = zdotdir != nil
            ? [("ZDOTDIR", zdotdir!), ("__PILOT_REAL_ZDOTDIR", NSHomeDirectory())]
            : []

        let surface = Self.makeSurface(
            app: app,
            view: self,
            workingDirectory: persistedDirectory,
            initialInput: nil,
            envVars: envVars
        )

        guard let surface else { return }
        self.surface = surface
        self.callbackSurface = surface

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

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleBellDidRing(_:)),
            name: .ghosttyBellDidRing,
            object: nil
        )

        // OSC 7 precmd hook (installed via ZDOTDIR) handles per-surface cwd tracking.
        // No polling needed. Each shell reports its own directory via Ghostty's PWD action.
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
        NotificationCenter.default.removeObserver(self, name: .ghosttyBellDidRing, object: nil)
        if let surface {
            ghostty_surface_free(surface)
            self.surface = nil
            self.callbackSurface = nil
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

        // Always go through interpretKeyEvents for proper macOS text input handling.
        // This matches upstream Ghostty behavior. Do NOT short-circuit for modifier combos.
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

        // Must have a modifier to be a key equivalent
        guard event.modifierFlags.contains(.command) ||
              event.modifierFlags.contains(.control) else {
            return false
        }

        // Cmd+V: paste from clipboard (Ghostty binding)
        if event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers?.lowercased() == "v" {
            return performPasteFromClipboard()
        }

        // Cmd+C: copy to clipboard (Ghostty binding)
        if event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers?.lowercased() == "c" {
            guard let surface else { return false }
            let action = "copy_to_clipboard"
            return ghostty_surface_binding_action(surface, action, UInt(action.utf8.count))
        }

        // All other Cmd/Ctrl combos: send through keyDown → Ghostty handles bindings at C level
        keyDown(with: event)
        return true
    }

    @objc func paste(_ sender: Any?) {
        _ = performPasteFromClipboard()
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

    private func performPasteFromClipboard() -> Bool {
        guard let surface else { return false }
        let action = "paste_from_clipboard"
        return ghostty_surface_binding_action(surface, action, UInt(action.utf8.count))
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
        pane.setCurrentDirectory(pwd)
    }

    @objc
    private func handleBellDidRing(_ notification: Notification) {
        guard let bellSurfaceID = notification.userInfo?["surfaceID"] as? UInt else { return }
        guard let surface else { return }
        guard bellSurfaceID == UInt(bitPattern: surface) else { return }
        pane.incrementBellCount()
    }

    private nonisolated static func validWorkingDirectory(from directory: String) -> String? {
        let trimmed = directory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let expandedDirectory = NSString(string: trimmed).expandingTildeInPath
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: expandedDirectory, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return nil
        }

        return expandedDirectory
    }

    /// Creates a temp directory with a .zshenv that installs an OSC 7 precmd hook,
    /// then restores the real ZDOTDIR so the user's normal config loads.
    private nonisolated static func setupOSC7ZdotDir() -> String? {
        let dir = NSTemporaryDirectory() + "pilot-zsh-\(ProcessInfo.processInfo.processIdentifier)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        let zshenv = """
        # Pilot: install OSC 7 working directory reporting
        __pilot_osc7_precmd() { printf '\\e]7;file://%s%s\\a' "$(hostname)" "$(pwd)"; }
        precmd_functions+=(__pilot_osc7_precmd)
        # Restore real ZDOTDIR and source the user's .zshenv if it exists
        export ZDOTDIR="$__PILOT_REAL_ZDOTDIR"
        unset __PILOT_REAL_ZDOTDIR
        [[ -f "$ZDOTDIR/.zshenv" ]] && source "$ZDOTDIR/.zshenv"
        """

        do {
            try zshenv.write(toFile: dir + "/.zshenv", atomically: true, encoding: .utf8)
            return dir
        } catch {
            return nil
        }
    }

    private nonisolated static func shellEscape(_ string: String) -> String {
        "'" + string.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    private nonisolated static func makeSurface(
        app: ghostty_app_t,
        view: GhosttyMetalView,
        workingDirectory: String?,
        initialInput: String?,
        envVars: [(key: String, value: String)] = []
    ) -> ghostty_surface_t? {
        func build(
            _ directory: UnsafePointer<CChar>?,
            _ input: UnsafePointer<CChar>?,
            _ envPtrs: UnsafeMutablePointer<ghostty_env_var_s>?,
            _ envCount: Int
        ) -> ghostty_surface_t? {
            var surfaceCfg = ghostty_surface_config_new()
            surfaceCfg.userdata = Unmanaged.passUnretained(view).toOpaque()
            surfaceCfg.platform_tag = GHOSTTY_PLATFORM_MACOS
            surfaceCfg.platform = ghostty_platform_u(
                macos: ghostty_platform_macos_s(
                    nsview: Unmanaged.passUnretained(view).toOpaque()
                )
            )
            surfaceCfg.scale_factor = Double(NSScreen.main?.backingScaleFactor ?? 2.0)
            surfaceCfg.working_directory = directory
            surfaceCfg.initial_input = input
            surfaceCfg.env_vars = envPtrs
            surfaceCfg.env_var_count = envCount
            return ghostty_surface_new(app, &surfaceCfg)
        }

        // All string -> CString conversions must be nested so pointers stay valid
        func withOptionalCString<R>(_ string: String?, _ body: (UnsafePointer<CChar>?) -> R) -> R {
            if let string { return string.withCString { body($0) } }
            return body(nil)
        }

        if envVars.isEmpty {
            return withOptionalCString(workingDirectory) { dirPtr in
                withOptionalCString(initialInput) { inputPtr in
                    build(dirPtr, inputPtr, nil, 0)
                }
            }
        }

        // Keep NSStrings alive so utf8String pointers remain valid through build()
        let nsKeys = envVars.map { NSString(string: $0.key) }
        let nsValues = envVars.map { NSString(string: $0.value) }
        var envArray = (0..<envVars.count).map { i in
            ghostty_env_var_s(key: nsKeys[i].utf8String, value: nsValues[i].utf8String)
        }
        _ = nsKeys   // prevent premature deallocation
        _ = nsValues

        return withOptionalCString(workingDirectory) { dirPtr in
            withOptionalCString(initialInput) { inputPtr in
                envArray.withUnsafeMutableBufferPointer { buf in
                    build(dirPtr, inputPtr, buf.baseAddress, buf.count)
                }
            }
        }
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
        // Commands like deleteBackward:, insertNewline: etc. are handled
        // by keyDown sending the physical key event to Ghostty directly.
        // No additional action needed here.
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
    static let ghosttyBellDidRing = Notification.Name("ghosttyBellDidRing")
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
    let rawFlags = flags.rawValue

    if flags.contains(.shift) { mods |= GHOSTTY_MODS_SHIFT.rawValue }
    if flags.contains(.control) { mods |= GHOSTTY_MODS_CTRL.rawValue }
    if flags.contains(.option) { mods |= GHOSTTY_MODS_ALT.rawValue }
    if flags.contains(.command) { mods |= GHOSTTY_MODS_SUPER.rawValue }
    if flags.contains(.capsLock) { mods |= GHOSTTY_MODS_CAPS.rawValue }

    if flags.contains(.shift), rawFlags & UInt(NX_DEVICERSHIFTKEYMASK) != 0 {
        mods |= GHOSTTY_MODS_SHIFT_RIGHT.rawValue
    }
    if flags.contains(.control), rawFlags & UInt(NX_DEVICERCTLKEYMASK) != 0 {
        mods |= GHOSTTY_MODS_CTRL_RIGHT.rawValue
    }
    if flags.contains(.option), rawFlags & UInt(NX_DEVICERALTKEYMASK) != 0 {
        mods |= GHOSTTY_MODS_ALT_RIGHT.rawValue
    }
    if flags.contains(.command), rawFlags & UInt(NX_DEVICERCMDKEYMASK) != 0 {
        mods |= GHOSTTY_MODS_SUPER_RIGHT.rawValue
    }

    return ghostty_input_mods_e(rawValue: mods)
}

private func ghosttyPhysicalKeyCode(for macKeyCode: UInt16) -> UInt32 {
    let key: ghostty_input_key_e = switch macKeyCode {
    case UInt16(kVK_ANSI_A): GHOSTTY_KEY_A
    case UInt16(kVK_ANSI_B): GHOSTTY_KEY_B
    case UInt16(kVK_ANSI_C): GHOSTTY_KEY_C
    case UInt16(kVK_ANSI_D): GHOSTTY_KEY_D
    case UInt16(kVK_ANSI_E): GHOSTTY_KEY_E
    case UInt16(kVK_ANSI_F): GHOSTTY_KEY_F
    case UInt16(kVK_ANSI_G): GHOSTTY_KEY_G
    case UInt16(kVK_ANSI_H): GHOSTTY_KEY_H
    case UInt16(kVK_ANSI_I): GHOSTTY_KEY_I
    case UInt16(kVK_ANSI_J): GHOSTTY_KEY_J
    case UInt16(kVK_ANSI_K): GHOSTTY_KEY_K
    case UInt16(kVK_ANSI_L): GHOSTTY_KEY_L
    case UInt16(kVK_ANSI_M): GHOSTTY_KEY_M
    case UInt16(kVK_ANSI_N): GHOSTTY_KEY_N
    case UInt16(kVK_ANSI_O): GHOSTTY_KEY_O
    case UInt16(kVK_ANSI_P): GHOSTTY_KEY_P
    case UInt16(kVK_ANSI_Q): GHOSTTY_KEY_Q
    case UInt16(kVK_ANSI_R): GHOSTTY_KEY_R
    case UInt16(kVK_ANSI_S): GHOSTTY_KEY_S
    case UInt16(kVK_ANSI_T): GHOSTTY_KEY_T
    case UInt16(kVK_ANSI_U): GHOSTTY_KEY_U
    case UInt16(kVK_ANSI_V): GHOSTTY_KEY_V
    case UInt16(kVK_ANSI_W): GHOSTTY_KEY_W
    case UInt16(kVK_ANSI_X): GHOSTTY_KEY_X
    case UInt16(kVK_ANSI_Y): GHOSTTY_KEY_Y
    case UInt16(kVK_ANSI_Z): GHOSTTY_KEY_Z
    case UInt16(kVK_ANSI_0): GHOSTTY_KEY_DIGIT_0
    case UInt16(kVK_ANSI_1): GHOSTTY_KEY_DIGIT_1
    case UInt16(kVK_ANSI_2): GHOSTTY_KEY_DIGIT_2
    case UInt16(kVK_ANSI_3): GHOSTTY_KEY_DIGIT_3
    case UInt16(kVK_ANSI_4): GHOSTTY_KEY_DIGIT_4
    case UInt16(kVK_ANSI_5): GHOSTTY_KEY_DIGIT_5
    case UInt16(kVK_ANSI_6): GHOSTTY_KEY_DIGIT_6
    case UInt16(kVK_ANSI_7): GHOSTTY_KEY_DIGIT_7
    case UInt16(kVK_ANSI_8): GHOSTTY_KEY_DIGIT_8
    case UInt16(kVK_ANSI_9): GHOSTTY_KEY_DIGIT_9
    case UInt16(kVK_ANSI_Equal): GHOSTTY_KEY_EQUAL
    case UInt16(kVK_ANSI_Minus): GHOSTTY_KEY_MINUS
    case UInt16(kVK_ANSI_LeftBracket): GHOSTTY_KEY_BRACKET_LEFT
    case UInt16(kVK_ANSI_RightBracket): GHOSTTY_KEY_BRACKET_RIGHT
    case UInt16(kVK_ANSI_Semicolon): GHOSTTY_KEY_SEMICOLON
    case UInt16(kVK_ANSI_Quote): GHOSTTY_KEY_QUOTE
    case UInt16(kVK_ANSI_Backslash): GHOSTTY_KEY_BACKSLASH
    case UInt16(kVK_ANSI_Comma): GHOSTTY_KEY_COMMA
    case UInt16(kVK_ANSI_Period): GHOSTTY_KEY_PERIOD
    case UInt16(kVK_ANSI_Slash): GHOSTTY_KEY_SLASH
    case UInt16(kVK_ANSI_Grave): GHOSTTY_KEY_BACKQUOTE
    case UInt16(kVK_ISO_Section): GHOSTTY_KEY_INTL_BACKSLASH
    case UInt16(kVK_JIS_Yen): GHOSTTY_KEY_INTL_YEN
    case UInt16(kVK_JIS_Underscore): GHOSTTY_KEY_INTL_RO
    case UInt16(kVK_Return): GHOSTTY_KEY_ENTER
    case UInt16(kVK_Tab): GHOSTTY_KEY_TAB
    case UInt16(kVK_Space): GHOSTTY_KEY_SPACE
    case UInt16(kVK_Delete): GHOSTTY_KEY_BACKSPACE
    case UInt16(kVK_ForwardDelete): GHOSTTY_KEY_DELETE
    case UInt16(kVK_Escape): GHOSTTY_KEY_ESCAPE
    case UInt16(kVK_Command): GHOSTTY_KEY_META_LEFT
    case UInt16(kVK_RightCommand): GHOSTTY_KEY_META_RIGHT
    case UInt16(kVK_Shift): GHOSTTY_KEY_SHIFT_LEFT
    case UInt16(kVK_RightShift): GHOSTTY_KEY_SHIFT_RIGHT
    case UInt16(kVK_Option): GHOSTTY_KEY_ALT_LEFT
    case UInt16(kVK_RightOption): GHOSTTY_KEY_ALT_RIGHT
    case UInt16(kVK_Control): GHOSTTY_KEY_CONTROL_LEFT
    case UInt16(kVK_RightControl): GHOSTTY_KEY_CONTROL_RIGHT
    case UInt16(kVK_CapsLock): GHOSTTY_KEY_CAPS_LOCK
    case UInt16(kVK_Function): GHOSTTY_KEY_FN
    case UInt16(kVK_Help): GHOSTTY_KEY_HELP
    case UInt16(kVK_Home): GHOSTTY_KEY_HOME
    case UInt16(kVK_End): GHOSTTY_KEY_END
    case UInt16(kVK_PageUp): GHOSTTY_KEY_PAGE_UP
    case UInt16(kVK_PageDown): GHOSTTY_KEY_PAGE_DOWN
    case UInt16(kVK_LeftArrow): GHOSTTY_KEY_ARROW_LEFT
    case UInt16(kVK_RightArrow): GHOSTTY_KEY_ARROW_RIGHT
    case UInt16(kVK_DownArrow): GHOSTTY_KEY_ARROW_DOWN
    case UInt16(kVK_UpArrow): GHOSTTY_KEY_ARROW_UP
    case UInt16(kVK_F1): GHOSTTY_KEY_F1
    case UInt16(kVK_F2): GHOSTTY_KEY_F2
    case UInt16(kVK_F3): GHOSTTY_KEY_F3
    case UInt16(kVK_F4): GHOSTTY_KEY_F4
    case UInt16(kVK_F5): GHOSTTY_KEY_F5
    case UInt16(kVK_F6): GHOSTTY_KEY_F6
    case UInt16(kVK_F7): GHOSTTY_KEY_F7
    case UInt16(kVK_F8): GHOSTTY_KEY_F8
    case UInt16(kVK_F9): GHOSTTY_KEY_F9
    case UInt16(kVK_F10): GHOSTTY_KEY_F10
    case UInt16(kVK_F11): GHOSTTY_KEY_F11
    case UInt16(kVK_F12): GHOSTTY_KEY_F12
    case UInt16(kVK_F13): GHOSTTY_KEY_F13
    case UInt16(kVK_F14): GHOSTTY_KEY_F14
    case UInt16(kVK_F15): GHOSTTY_KEY_F15
    case UInt16(kVK_F16): GHOSTTY_KEY_F16
    case UInt16(kVK_F17): GHOSTTY_KEY_F17
    case UInt16(kVK_F18): GHOSTTY_KEY_F18
    case UInt16(kVK_F19): GHOSTTY_KEY_F19
    case UInt16(kVK_F20): GHOSTTY_KEY_F20
    case UInt16(kVK_ANSI_Keypad0): GHOSTTY_KEY_NUMPAD_0
    case UInt16(kVK_ANSI_Keypad1): GHOSTTY_KEY_NUMPAD_1
    case UInt16(kVK_ANSI_Keypad2): GHOSTTY_KEY_NUMPAD_2
    case UInt16(kVK_ANSI_Keypad3): GHOSTTY_KEY_NUMPAD_3
    case UInt16(kVK_ANSI_Keypad4): GHOSTTY_KEY_NUMPAD_4
    case UInt16(kVK_ANSI_Keypad5): GHOSTTY_KEY_NUMPAD_5
    case UInt16(kVK_ANSI_Keypad6): GHOSTTY_KEY_NUMPAD_6
    case UInt16(kVK_ANSI_Keypad7): GHOSTTY_KEY_NUMPAD_7
    case UInt16(kVK_ANSI_Keypad8): GHOSTTY_KEY_NUMPAD_8
    case UInt16(kVK_ANSI_Keypad9): GHOSTTY_KEY_NUMPAD_9
    case UInt16(kVK_ANSI_KeypadDecimal): GHOSTTY_KEY_NUMPAD_DECIMAL
    case UInt16(kVK_ANSI_KeypadMultiply): GHOSTTY_KEY_NUMPAD_MULTIPLY
    case UInt16(kVK_ANSI_KeypadPlus): GHOSTTY_KEY_NUMPAD_ADD
    case UInt16(kVK_ANSI_KeypadClear): GHOSTTY_KEY_NUMPAD_CLEAR
    case UInt16(kVK_ANSI_KeypadDivide): GHOSTTY_KEY_NUMPAD_DIVIDE
    case UInt16(kVK_ANSI_KeypadEnter): GHOSTTY_KEY_NUMPAD_ENTER
    case UInt16(kVK_ANSI_KeypadMinus): GHOSTTY_KEY_NUMPAD_SUBTRACT
    case UInt16(kVK_ANSI_KeypadEquals): GHOSTTY_KEY_NUMPAD_EQUAL
    case UInt16(kVK_JIS_KeypadComma): GHOSTTY_KEY_NUMPAD_COMMA
    case UInt16(kVK_VolumeUp): GHOSTTY_KEY_AUDIO_VOLUME_UP
    case UInt16(kVK_VolumeDown): GHOSTTY_KEY_AUDIO_VOLUME_DOWN
    case UInt16(kVK_Mute): GHOSTTY_KEY_AUDIO_VOLUME_MUTE
    default: GHOSTTY_KEY_UNIDENTIFIED
    }

    return UInt32(key.rawValue)
}

private extension NSEvent {
    func ghosttyKeyEvent(
        _ action: ghostty_input_action_e,
        translationMods: NSEvent.ModifierFlags? = nil
    ) -> ghostty_input_key_s {
        var key = ghostty_input_key_s()
        key.action = action
        key.keycode = ghosttyPhysicalKeyCode(for: keyCode)
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

            if scalar.value == 0x7F {
                return nil
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
