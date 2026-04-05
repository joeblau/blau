import AppKit
import SwiftUI
import GhosttyKit

// MARK: - Ghostty App Singleton

/// Manages the global Ghostty app instance. One per process.
final class GhosttyRuntime: @unchecked Sendable {
    static let shared = GhosttyRuntime()
    static let terminalBackgroundColor = NSColor(
        srgbRed: 0x1C / 255.0,
        green: 0x1C / 255.0,
        blue: 0x1C / 255.0,
        alpha: 1.0
    )
    static let terminalBackgroundHex = "#1c1c1c"

    private(set) var app: ghostty_app_t?
    private(set) var config: ghostty_config_t?

    private init() {
        // Initialize the Ghostty library
        ghostty_init(0, nil)

        // Create and finalize config
        guard let cfg = ghostty_config_new() else { return }
        ghostty_config_load_default_files(cfg)

        // Force a stable dark terminal background regardless of macOS appearance.
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
            supports_selection_clipboard: true,
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
                let pb = GhosttyRuntime.pasteboard(for: loc)
                pb.clearContents()
                pb.setString(str, forType: .string)
            },
            close_surface_cb: { _, _ in }
        )

        guard let ghosttyApp = ghostty_app_new(&runtime_cfg, cfg) else { return }
        self.app = ghosttyApp

        // Track app focus for cursor blink, etc.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let app = self?.app else { return }
            ghostty_app_set_focus(app, true)
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let app = self?.app else { return }
            ghostty_app_set_focus(app, false)
        }
    }

    func tick() {
        guard let app else { return }
        ghostty_app_tick(app)
    }

    private static func pasteboard(for location: ghostty_clipboard_e) -> NSPasteboard {
        if location == GHOSTTY_CLIPBOARD_SELECTION {
            return NSPasteboard(name: NSPasteboard.Name("com.mitchellh.ghostty.selection"))
        }
        return .general
    }

    private static func readClipboard(
        _ userdata: UnsafeMutableRawPointer?,
        location: ghostty_clipboard_e,
        state: UnsafeMutableRawPointer?
    ) -> Bool {
        guard let surface = surface(from: userdata) else { return false }
        let pb = pasteboard(for: location)

        let pasteString: String? = if Thread.isMainThread {
            pb.string(forType: .string)
        } else {
            DispatchQueue.main.sync {
                pb.string(forType: .string)
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

    /// Writes a temporary Ghostty config file that forces a consistent dark
    /// terminal background to avoid light empty regions in terminal panes.
    private static func writeBackgroundConfig() -> String? {
        let path = NSTemporaryDirectory() + "ghostty-bg-\(ProcessInfo.processInfo.processIdentifier).conf"
        let content = """
        background = \(terminalBackgroundHex)
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
    /// Registry of live terminal views keyed by Pane ID.
    /// Used to target the active terminal for remote input (voice paste, watch Enter).
    private static var registry: [UUID: GhosttyMetalView] = [:]

    static func view(for paneID: UUID) -> GhosttyMetalView? {
        registry[paneID]
    }

    @discardableResult
    static func focus(paneID: UUID) -> Bool {
        guard let view = registry[paneID], let window = view.window else { return false }
        if window.firstResponder !== view {
            window.makeFirstResponder(view)
        }
        return true
    }

    var surface: ghostty_surface_t?
    nonisolated(unsafe) fileprivate var callbackSurface: ghostty_surface_t?
    private var renderObserver: NSObjectProtocol?
    private var trackingArea: NSTrackingArea?
    private let pane: Pane

    init(app: ghostty_app_t, pane: Pane) {
        self.pane = pane
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        wantsLayer = true
        layer?.backgroundColor = GhosttyRuntime.terminalBackgroundColor.cgColor

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
        let persistentSessionInput = PersistentTerminalSession.bootstrapCommand(
            for: pane,
            workingDirectory: persistedDirectory
        )

        let surface = Self.makeSurface(
            app: app,
            view: self,
            workingDirectory: persistedDirectory,
            initialInput: persistentSessionInput,
            envVars: envVars
        )

        guard let surface else { return }
        self.surface = surface
        self.callbackSurface = surface
        Self.registry[pane.id] = self

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
        Self.registry.removeValue(forKey: pane.id)
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
        pane.workspace?.setFrontmostTerminalPaneID(pane.id)
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
            // Don't grab focus here — all workspaces are rendered in a ZStack
            // and the last terminal to fire would steal focus from the active
            // workspace's terminal.  Workspace-level focus management
            // (focusTerminalIfNeededForWorkspaceActivation, etc.) handles this.
            if let surface = self.surface {
                let scale = window.backingScaleFactor
                ghostty_surface_set_content_scale(surface, Double(scale), Double(scale))
            }
        }
    }

    // Text accumulated during keyDown via insertText
    private var keyTextAccumulator: [String]?

    // Records the timestamp of the last event to performKeyEquivalent.
    // Used to re-dispatch command-modded key events that AppKit intercepted
    // via doCommand before our keyDown could handle them.
    private var lastPerformKeyEvent: TimeInterval?

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        guard let surface else {
            interpretKeyEvents([event])
            return
        }

        let action = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS

        // Fast path for Ctrl-modified keys (Ctrl+C, Ctrl+D, etc.)
        // Bypass interpretKeyEvents entirely and send raw keycode to Ghostty.
        if event.modifierFlags.contains(.control) &&
            !event.modifierFlags.contains(.command) {
            let text = event.charactersIgnoringModifiers
            _ = keyAction(action, event: event, text: text)
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

        keyTextAccumulator = []
        defer { keyTextAccumulator = nil }

        // Reset the re-dispatch timestamp since interpretKeyEvents may trigger doCommand.
        self.lastPerformKeyEvent = nil

        interpretKeyEvents([translationEvent])

        // Sync preedit state after interpretKeyEvents
        syncPreedit()

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
        // Only handle key equivalents if we are the first responder.
        // AppKit walks the view hierarchy for performKeyEquivalent, so
        // terminals in inactive workspaces would otherwise intercept
        // Cmd+V, Cmd+C, etc. before the active terminal sees them.
        guard window?.firstResponder === self else { return false }

        if event.modifierFlags.contains(.command),
           !event.modifierFlags.contains(.control),
           !event.modifierFlags.contains(.option),
           event.charactersIgnoringModifiers?.lowercased() == "v" {
            paste(nil)
            return true
        }

        let equivalent: String
        switch event.charactersIgnoringModifiers {
        case "\r":
            // Pass C-<return> through verbatim
            // (prevent the default context menu equivalent)
            if !event.modifierFlags.contains(.control) {
                return false
            }
            equivalent = "\r"

        case "/":
            // Treat C-/ as C-_. We do this because C-/ makes macOS beep.
            if !event.modifierFlags.contains(.control) ||
                !event.modifierFlags.isDisjoint(with: [.shift, .command, .option]) {
                return false
            }
            equivalent = "_"

        default:
            // Ignore synthetic events with zero timestamp
            if event.timestamp == 0 {
                return false
            }

            // Ignore all non-command/control events
            if !event.modifierFlags.contains(.command) &&
                !event.modifierFlags.contains(.control) {
                lastPerformKeyEvent = nil
                return false
            }

            // If we have a prior command binding and the timestamp matches,
            // re-dispatch through keyDown for encoding.
            if let lastPerformKeyEvent {
                self.lastPerformKeyEvent = nil
                if lastPerformKeyEvent == event.timestamp {
                    equivalent = event.characters ?? ""
                    break
                }
            }

            // Send all Cmd/Ctrl combos through keyDown so Ghostty's C-level
            // binding system can handle them (paste, copy, etc.).
            self.keyDown(with: event)
            return true
        }

        let finalEvent = NSEvent.keyEvent(
            with: .keyDown,
            location: event.locationInWindow,
            modifierFlags: event.modifierFlags,
            timestamp: event.timestamp,
            windowNumber: event.windowNumber,
            context: nil,
            characters: equivalent,
            charactersIgnoringModifiers: equivalent,
            isARepeat: event.isARepeat,
            keyCode: event.keyCode
        )

        self.keyDown(with: finalEvent!)
        return true
    }

    @objc func paste(_ sender: Any?) {
        _ = performPasteFromClipboard() || pasteGeneralClipboardContents()
    }

    /// Paste text directly into the terminal surface (bypasses clipboard).
    /// Used for remote voice-to-text input.
    func pasteText(_ text: String) {
        guard let surface else { return }
        text.withCString { ptr in
            ghostty_surface_text(surface, ptr, UInt(text.utf8.count))
        }
    }

    /// Send an Enter keypress to the terminal surface.
    /// Used for watch double-pinch → Enter.
    func sendEnter() {
        _ = keyAction(GHOSTTY_ACTION_PRESS, keycode: 0x24) // kVK_Return
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

        // If we're in the middle of a preedit, don't do anything with mods.
        if hasMarkedText() { return }

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

    override func rightMouseDown(with event: NSEvent) {
        guard let surface else { super.rightMouseDown(with: event); return }
        // If the terminal app has captured the mouse, send the event to Ghostty.
        // Otherwise, show the system context menu.
        if ghostty_surface_mouse_captured(surface) {
            _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_RIGHT, mods(event))
        } else {
            super.rightMouseDown(with: event)
        }
    }

    override func rightMouseUp(with event: NSEvent) {
        guard let surface else { return }
        if ghostty_surface_mouse_captured(surface) {
            _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_RIGHT, mods(event))
        }
    }

    override func otherMouseDown(with event: NSEvent) {
        guard let surface, event.buttonNumber == 2 else { return }
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_MIDDLE, mods(event))
    }

    override func otherMouseUp(with event: NSEvent) {
        guard let surface, event.buttonNumber == 2 else { return }
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_MIDDLE, mods(event))
    }

    override func mouseExited(with event: NSEvent) {
        guard let surface else { return }
        ghostty_surface_mouse_pos(surface, -1, -1, mods(event))
    }

    override func scrollWheel(with event: NSEvent) {
        guard let surface else { return }
        var x = event.scrollingDeltaX
        var y = event.scrollingDeltaY
        if event.hasPreciseScrollingDeltas {
            x *= 2
            y *= 2
        }
        ghostty_surface_mouse_scroll(surface, x, y, scrollMods(event))
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

    private func pasteGeneralClipboardContents() -> Bool {
        guard let text = NSPasteboard.general.string(forType: .string),
              !text.isEmpty else { return false }
        pasteText(text)
        return true
    }

    private func mods(_ event: NSEvent) -> ghostty_input_mods_e {
        ghosttyMods(event.modifierFlags)
    }

    private func scrollMods(_ event: NSEvent) -> ghostty_input_scroll_mods_t {
        // Newer Ghostty headers expose scroll modifiers as an opaque packed int
        // and no longer vend the precise/momentum constants directly. Preserve
        // the keyboard modifier bits and let Ghostty handle the rest internally.
        let baseMods = Int32(bitPattern: ghosttyMods(event.modifierFlags).rawValue)
        return ghostty_input_scroll_mods_t(baseMods)
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
        let chars: String
        if let s = string as? NSAttributedString {
            chars = s.string
        } else if let s = string as? String {
            chars = s
        } else {
            return
        }

        // If insertText is called, our preedit must be over.
        unmarkText()

        // If we have an accumulator we're in a keyDown event so we just
        // accumulate and return.
        if var acc = keyTextAccumulator {
            acc.append(chars)
            keyTextAccumulator = acc
            return
        }

        // Fallback: text arriving outside keyDown (dictation, accessibility, etc.)
        sendTextToSurface(chars)
    }

    /// Send text directly to the surface, handling special characters.
    /// Used for text that arrives outside the normal keyDown path.
    private func sendTextToSurface(_ text: String) {
        guard let surface else { return }
        var buffer = ""
        var prevWasCR = false

        func flush() {
            guard !buffer.isEmpty else { return }
            buffer.withCString { ptr in
                var key = ghostty_input_key_s()
                key.action = GHOSTTY_ACTION_PRESS
                key.keycode = 0
                key.mods = GHOSTTY_MODS_NONE
                key.consumed_mods = GHOSTTY_MODS_NONE
                key.text = ptr
                key.composing = false
                key.unshifted_codepoint = 0
                _ = ghostty_surface_key(surface, key)
            }
            buffer = ""
        }

        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x0D: // CR
                flush()
                _ = keyAction(GHOSTTY_ACTION_PRESS, keycode: 0x24) // kVK_Return
                prevWasCR = true
                continue
            case 0x0A: // LF
                if !prevWasCR {
                    flush()
                    _ = keyAction(GHOSTTY_ACTION_PRESS, keycode: 0x24)
                }
            case 0x09: // Tab
                flush()
                _ = keyAction(GHOSTTY_ACTION_PRESS, keycode: 0x30) // kVK_Tab
            case 0x1B: // Escape
                flush()
                _ = keyAction(GHOSTTY_ACTION_PRESS, keycode: 0x35) // kVK_Escape
            default:
                buffer.append(Character(scalar))
            }
            prevWasCR = false
        }
        flush()
    }

    /// Send a bare keycode press (no text) for special keys.
    private func keyAction(_ action: ghostty_input_action_e, keycode: UInt32) -> Bool {
        guard let surface else { return false }
        var key = ghostty_input_key_s()
        key.action = action
        key.keycode = keycode
        key.mods = GHOSTTY_MODS_NONE
        key.consumed_mods = GHOSTTY_MODS_NONE
        key.text = nil
        key.composing = false
        key.unshifted_codepoint = 0
        return ghostty_surface_key(surface, key)
    }

    override func doCommand(by selector: Selector) {
        // If we are being processed by performKeyEquivalent with a command binding,
        // we send it back through the event system so it can be encoded.
        if let lastPerformKeyEvent,
           let current = NSApp.currentEvent,
           lastPerformKeyEvent == current.timestamp {
            NSApp.sendEvent(current)
            return
        }

        // This function needs to exist to prevent audible NSBeep for
        // unimplemented actions. Commands like deleteBackward:, insertNewline:
        // etc. are handled by keyDown sending the key event to Ghostty directly.
    }

    // MARK: - IME / Marked Text

    private static var markedTextKey: UInt8 = 0

    private var markedText: NSMutableAttributedString {
        get {
            objc_getAssociatedObject(self, &Self.markedTextKey) as? NSMutableAttributedString
                ?? NSMutableAttributedString()
        }
        set {
            objc_setAssociatedObject(self, &Self.markedTextKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        if let s = string as? NSAttributedString {
            markedText = NSMutableAttributedString(attributedString: s)
        } else if let s = string as? String {
            markedText = NSMutableAttributedString(string: s)
        }

        // If not inside keyDown, sync preedit immediately
        if keyTextAccumulator == nil {
            syncPreedit()
        }
    }

    func unmarkText() {
        markedText = NSMutableAttributedString()
        syncPreedit()
    }

    func syncPreedit() {
        guard let surface else { return }
        let text = markedText.string
        if text.isEmpty {
            ghostty_surface_preedit(surface, nil, 0)
        } else {
            text.withCString { ptr in
                ghostty_surface_preedit(surface, ptr, UInt(text.utf8.count))
            }
        }
    }

    func selectedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }

    func markedRange() -> NSRange {
        if markedText.length > 0 {
            return NSRange(location: 0, length: markedText.length)
        }
        return NSRange(location: NSNotFound, length: 0)
    }

    func hasMarkedText() -> Bool { markedText.length > 0 }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let surface, let window else { return .zero }
        var x: Double = 0
        var y: Double = 0
        var width: Double = 0
        var height: Double = 0
        ghostty_surface_ime_point(surface, &x, &y, &width, &height)
        // Convert from Ghostty top-left to AppKit bottom-left
        let viewRect = NSRect(x: x, y: bounds.height - y - height, width: width, height: height)
        let windowRect = convert(viewRect, to: nil)
        let screenOrigin = window.convertPoint(toScreen: windowRect.origin)
        return NSRect(origin: screenOrigin, size: windowRect.size)
    }

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
    let isActive: Bool

    func makeNSView(context: Context) -> NSView {
        guard let app = GhosttyRuntime.shared.app else {
            let v = NSView()
            v.wantsLayer = true
            v.layer?.backgroundColor = GhosttyRuntime.terminalBackgroundColor.cgColor
            v.isHidden = !isActive
            return v
        }
        let view = GhosttyMetalView(app: app, pane: pane)
        view.isHidden = !isActive
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.isHidden = !isActive
    }
}
