import AppKit
import SwiftData
import SwiftUI

@main
struct PilotApp: App {
    let modelContainer: ModelContainer

    @State private var store: WorkspaceStore
    @State private var peerDeviceStatus = DeviceStatus()
    @State private var headphoneDetector = HeadphoneDetector()
    @State private var syncService = PeerSyncService(
        role: .advertiser,
        displayName: Host.current().localizedName ?? "Mac"
    )
    /// High-bandwidth frame channel that live-mirrors Pilot's window to Plotter.
    @State private var frameSender = FrameSender()
    @State private var screenMirror: ScreenMirror
    @State private var plotterClientCount = 0
    @State private var annotationReceiver = AnnotationReceiver()
    @State private var remoteInkModel = RemoteInkModel()
    @State private var recordingTargetPaneID: UUID?
    /// True while a Copilot peer is currently push-to-talking. Flipped
    /// from `.voiceRecord(.start | .stop)` messages so the Mac UI can
    /// show a "listening" hint even though the audio + transcription
    /// happen on the iPhone now.
    @State private var isPeerRecording: Bool = false
    @State private var didSetupSync = false
    /// Badges background workspaces when their GitHub Actions complete.
    @State private var actionWatcher = WorkspaceActionWatcher()
    /// Auto-generated identity key, auto-exchanged with Copilot over the
    /// encrypted channel (issue #51).
    @State private var secureIdentity = SecureIdentity(role: .pilot)

    @AppStorage("ui.zoom") private var uiZoom: Double = UIZoomLadder.default

    init() {
        // Build the schema from the newest versioned schema so the store is
        // stamped with a version and `PilotMigrationPlan` governs upgrades.
        let schema = Schema(versionedSchema: PilotSchemaV1.self)
        let storeURL = Self.persistentStoreURL()
        // Safety net: copy the on-disk store aside BEFORE opening it, so a failed
        // open or migration can never be the only thing standing between the user
        // and their workspaces/notes. Runs before `makeModelContainer` on purpose.
        Self.backUpStore(at: storeURL, fileManager: .default)
        let configuration = ModelConfiguration(schema: schema, url: storeURL)
        let container = Self.makeModelContainer(
            schema: schema,
            migrationPlan: PilotMigrationPlan.self,
            configuration: configuration,
            storeURL: storeURL
        )
        self.modelContainer = container
        let store = WorkspaceStore(modelContext: container.mainContext)
        // Demo mode (screenshots/UITests): launch arg pair ["-demoMode", "YES"]
        // sets the "demoMode" UserDefaults bool. When on, seed representative
        // workspaces so the sidebar/layout looks intentional with no live peer.
        // Guarded so a normal launch (no arg) is completely unchanged — the
        // seed is also a no-op whenever real workspaces already exist.
        if UserDefaults.standard.bool(forKey: "demoMode") {
            store.seedDemoWorkspacesIfNeeded()
        }
        self._store = State(initialValue: store)
        let sender = FrameSender()
        self._frameSender = State(initialValue: sender)
        self._screenMirror = State(initialValue: ScreenMirror(sender: sender))
    }

    /// Pilot runs unsandboxed (so Ghostty can launch real shell processes), so
    /// it owns `~/Library/Application Support` directly. Earlier builds wrote the
    /// SwiftData store into the *sandbox container* at
    /// `~/Library/Containers/app.blau.pilot/Data/…`; once unsandboxed, every
    /// access to that path makes macOS treat us as reaching into another app's
    /// data and throws a "would like to access data from other apps" prompt — on
    /// every launch, since the store reopens each time. Keep the store in
    /// Application Support instead, and migrate the old one over once so existing
    /// notes/workspaces carry across.
    private static func persistentStoreURL() -> URL {
        let fileManager = FileManager.default
        let appSupport = (try? fileManager.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )) ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        let directory = appSupport.appendingPathComponent("Pilot", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let storeURL = directory.appendingPathComponent("default.store")

        migrateLegacyStoreIfNeeded(to: directory, storeURL: storeURL, fileManager: fileManager)
        return storeURL
    }

    /// One-time copy of the SwiftData store out of an older location, run only
    /// when the new store is absent.
    ///
    /// There are two legacy locations to rescue, because the store has moved
    /// twice:
    ///   1. `~/Library/Application Support/default.store` — the unsandboxed-era
    ///      store, written there by `ModelConfiguration` before the move into
    ///      the `Pilot/` subdirectory. This is where most existing users' data
    ///      actually lives, and missing it orphaned real workspaces/notes.
    ///   2. `~/Library/Containers/app.blau.pilot/.../default.store` — the
    ///      original sandbox-container store (pre-unsandboxing).
    /// Whichever exists and was modified most recently wins, so the freshest
    /// data is the one carried across.
    ///
    /// It *copies* (never moves) so a denied or failed migration leaves the
    /// legacy data intact and retryable rather than destroyed, and it commits the
    /// base `.store` LAST via an atomic same-volume rename: SQLite only ever sees
    /// the new store appear with its WAL/SHM sidecars already in place, never an
    /// orphan `-wal` next to an empty store (which it would read as a malformed
    /// image and crash on). Any failure rolls the partial copy back so the next
    /// launch retries from a clean slate.
    private static func migrateLegacyStoreIfNeeded(to directory: URL, storeURL: URL, fileManager: FileManager) {
        guard !fileManager.fileExists(atPath: storeURL.path) else { return }

        let stagedStore = directory.appendingPathComponent("default.store.import")
        let sidecars = ["-wal", "-shm"].map { directory.appendingPathComponent("default.store\($0)") }
        func rollback() {
            try? fileManager.removeItem(at: stagedStore)
            for sidecar in sidecars { try? fileManager.removeItem(at: sidecar) }
        }
        // The base store is absent, so any sidecars/staging present here are
        // orphans from a prior aborted run. Clear them up front — before the
        // legacy-present check below can early-return — so SQLite is never handed
        // a `-wal` next to a missing base (a "malformed image"), whatever happens
        // to the legacy source.
        rollback()

        // Candidate legacy stores. `directory` is `…/Application Support/Pilot`,
        // so its parent is the unsandboxed-era root location.
        let rootAppSupportStore = directory.deletingLastPathComponent()
            .appendingPathComponent("default.store")
        let sandboxStore = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Library/Containers/app.blau.pilot/Data/Library/Application Support/default.store", isDirectory: true)

        func modificationDate(_ url: URL) -> Date {
            let attributes = try? fileManager.attributesOfItem(atPath: url.path)
            return (attributes?[.modificationDate] as? Date) ?? .distantPast
        }
        let candidates = [rootAppSupportStore, sandboxStore]
            .filter { fileManager.fileExists(atPath: $0.path) }
        guard let legacyStore = candidates.max(by: { modificationDate($0) < modificationDate($1) }) else { return }
        let legacyDirectory = legacyStore.deletingLastPathComponent()

        do {
            // Copy the base to a staging name and the sidecars to their final
            // names; the base is committed last so it never appears half-built.
            try fileManager.copyItem(at: legacyStore, to: stagedStore)
            for suffix in ["-wal", "-shm"] {
                let source = legacyDirectory.appendingPathComponent("default.store\(suffix)")
                guard fileManager.fileExists(atPath: source.path) else { continue }
                try fileManager.copyItem(at: source, to: directory.appendingPathComponent("default.store\(suffix)"))
            }
            // Commit: the base store appears only now, with sidecars in place.
            try fileManager.moveItem(at: stagedStore, to: storeURL)
        } catch {
            rollback()
        }
    }

    /// Number of timestamped store backups to retain. Enough that a handful of
    /// rapid relaunches can't prune away the last known-good copy.
    private static let maxStoreBackups = 15

    /// Copy the on-disk store (base + WAL + SHM) into a timestamped folder under
    /// `Pilot/Backups/` before it is opened, then prune to `maxStoreBackups`.
    ///
    /// This is the data-loss backstop: notes and workspaces can only be lost if
    /// *every* copy is gone, and this guarantees a recent copy always survives an
    /// open or migration that goes wrong — independent of the corruption handler.
    /// It copies (never moves) and tolerates every failure silently: a backup is
    /// best-effort insurance and must never block the app from launching.
    private static func backUpStore(at storeURL: URL, fileManager: FileManager) {
        guard fileManager.fileExists(atPath: storeURL.path) else { return }
        let directory = storeURL.deletingLastPathComponent()
        let backupsRoot = directory.appendingPathComponent("Backups", isDirectory: true)

        // Skip if the newest backup already matches the current store (size +
        // mtime), so repeated launches with no changes don't churn the history.
        let currentSignature = storeSignature(storeURL, fileManager: fileManager)
        if let newest = (try? fileManager.contentsOfDirectory(at: backupsRoot, includingPropertiesForKeys: nil))?
            .filter({ (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true })
            .max(by: { $0.lastPathComponent < $1.lastPathComponent }),
           storeSignature(newest.appendingPathComponent("default.store"), fileManager: fileManager) == currentSignature {
            return
        }

        let stamp = Int(Date().timeIntervalSince1970)
        let destination = backupsRoot.appendingPathComponent(String(format: "%012d", stamp), isDirectory: true)
        guard (try? fileManager.createDirectory(at: destination, withIntermediateDirectories: true)) != nil else { return }
        for suffix in ["", "-wal", "-shm"] {
            let source = directory.appendingPathComponent("default.store\(suffix)")
            guard fileManager.fileExists(atPath: source.path) else { continue }
            try? fileManager.copyItem(at: source, to: destination.appendingPathComponent("default.store\(suffix)"))
        }

        // Prune oldest backups beyond the retention count.
        if let backups = try? fileManager.contentsOfDirectory(at: backupsRoot, includingPropertiesForKeys: nil) {
            let sorted = backups
                .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            if sorted.count > maxStoreBackups {
                for old in sorted.prefix(sorted.count - maxStoreBackups) {
                    try? fileManager.removeItem(at: old)
                }
            }
        }
    }

    /// Cheap content fingerprint (byte size + modification time) for the store
    /// base file, used to avoid making identical back-to-back backups.
    private static func storeSignature(_ url: URL, fileManager: FileManager) -> String? {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path) else { return nil }
        let size = (attributes[.size] as? Int) ?? -1
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1
        return "\(size)-\(modified)"
    }

    /// Open the store, but never let a corrupt/unreadable one crash every launch:
    /// on failure, quarantine the on-disk store aside and start fresh so the app
    /// still opens. The quarantined files are preserved for manual recovery, and
    /// `backUpStore` has already saved a copy aside before this runs.
    ///
    /// Quarantine names are unique per failure (timestamped). A fixed
    /// `default.store.corrupt` name was catastrophic: a *second* failed open
    /// would delete the first quarantine before writing its own, so two bad
    /// launches in a row (e.g. across two schema changes) destroyed the only
    /// surviving copy of the user's data. Never delete an existing quarantine.
    private static func makeModelContainer(
        schema: Schema,
        migrationPlan: (any SchemaMigrationPlan.Type)?,
        configuration: ModelConfiguration,
        storeURL: URL
    ) -> ModelContainer {
        do {
            return try ModelContainer(for: schema, migrationPlan: migrationPlan, configurations: configuration)
        } catch {
            let fileManager = FileManager.default
            let directory = storeURL.deletingLastPathComponent()
            let stamp = Int(Date().timeIntervalSince1970)
            for suffix in ["", "-wal", "-shm"] {
                let file = directory.appendingPathComponent("default.store\(suffix)")
                guard fileManager.fileExists(atPath: file.path) else { continue }
                // Find a quarantine name that does not already exist; never
                // overwrite a prior quarantine — it may be the last good copy.
                var quarantined = directory.appendingPathComponent("default.store\(suffix).\(stamp).corrupt")
                var bump = 1
                while fileManager.fileExists(atPath: quarantined.path) {
                    quarantined = directory.appendingPathComponent("default.store\(suffix).\(stamp)-\(bump).corrupt")
                    bump += 1
                }
                try? fileManager.moveItem(at: file, to: quarantined)
            }
            if let fresh = try? ModelContainer(for: schema, migrationPlan: migrationPlan, configurations: configuration) {
                return fresh
            }
            // Last resort when even a fresh on-disk store can't be created (disk
            // full, unwritable directory): an ephemeral in-memory store so the
            // app still opens this session instead of crash-looping every launch.
            return try! ModelContainer(
                for: schema,
                configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            )
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView(
                store: store,
                syncService: syncService,
                peerDeviceStatus: peerDeviceStatus,
                localAudioOutput: headphoneDetector.audioOutput,
                isPlotterConnected: plotterClientCount > 0,
                remoteInkModel: remoteInkModel,
                isPeerRecording: isPeerRecording
            )
                .environment(\.uiZoom, uiZoom)
                .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
                // Report Pilot's light/dark appearance to connected Plotters so
                // they can match it; fires on connect and whenever the Mac's
                // appearance changes.
                .background {
                    AppearanceReporter(isConnected: plotterClientCount > 0) { isDark in
                        frameSender.send(.appearance(isDark: isDark))
                    }
                }
                .onChange(of: uiZoom) { _, newValue in
                    GhosttyRuntime.shared.userZoomFactor = newValue
                }
                .task {
                    GhosttyRuntime.shared.userZoomFactor = uiZoom
                    // Skip services that prompt for permissions when XCTest is host-running us.
                    guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
                    _ = MouseBridge.shared.ensurePermissions()
                    headphoneDetector.start()
                    setupSync()
                    actionWatcher.start(store: store)
                    frameSender.onClientCountChanged = { count in
                        Task { @MainActor in
                            let wasConnected = plotterClientCount > 0
                            plotterClientCount = count
                            // Only capture the screen — which lights up the macOS
                            // "your screen is being shared" indicator — while a
                            // Plotter is actually connected. Start on the first
                            // client, stop when the last one disconnects.
                            if count > 0 && !wasConnected {
                                screenMirror.start()
                            } else if count == 0 && wasConnected {
                                screenMirror.stop()
                            }
                        }
                    }
                    frameSender.onAnnotationMessage = { seq, message in
                        Task { @MainActor in
                            remoteInkModel.handle(message)
                            // Confirm acceptance so Plotter can stop drawing
                            // its now-redundant local copy and defer to the
                            // mirrored render.
                            frameSender.sendAnnotationAck(seq)
                        }
                    }
                    // Undo/clear performed on Pilot are forwarded to the iPad,
                    // which owns the authoritative PencilKit drawing and echoes
                    // the corrected drawing back via onAnnotationMessage.
                    remoteInkModel.onLocalEdit = { message in
                        frameSender.sendAnnotation(message)
                    }
                    annotationReceiver.onMessage = { message in
                        Task { @MainActor in
                            remoteInkModel.handle(message)
                        }
                    }
                    // Advertise the frame channel immediately so a Plotter can
                    // discover and connect, but DON'T start screen capture yet —
                    // capture begins on the first connected client (see
                    // onClientCountChanged) so the macOS screen-sharing indicator
                    // isn't lit whenever Pilot is merely running.
                    frameSender.start()
                    annotationReceiver.start()
                }
                .onChange(of: headphoneDetector.audioOutput) {
                    sendLocalDeviceStatus()
                }
                .onChange(of: syncService.isConnected) {
                    guard syncService.isConnected else { return }
                    sendLocalDeviceStatus()
                    // Auto-exchange device keys with Copilot once connected.
                    secureIdentity.announce()
                }
                .environment(secureIdentity)
                .onReceive(NotificationCenter.default.publisher(for: .pilotSendIssuePrompt)) { note in
                    // Issues inspector / Browser Annotate → paste a prompt into
                    // the selected workspace's active terminal and submit it so
                    // the agent starts working on the task.
                    guard let prompt = note.userInfo?["prompt"] as? String else { return }
                    guard let terminal = activeTerminalView else {
                        // No terminal to receive it — beep rather than silently
                        // swallowing the request the user just dispatched.
                        NSSound.beep()
                        return
                    }
                    terminal.pasteText(prompt)
                    terminal.sendEnter()
                }
        }
        .modelContainer(modelContainer)
        .commands {
            // New Terminal / New Browser as real main-menu commands. As toolbar
            // ControlGroup button shortcuts they were swallowed by a focused
            // WKWebView; menu key-equivalents take precedence over the web view.
            CommandGroup(after: .newItem) {
                Button("New Terminal") {
                    store.selectedWorkspace?.addPane(kind: .terminal, side: .right)
                }
                .keyboardShortcut("t", modifiers: .command)
                .disabled(store.selectedWorkspace == nil || store.isNotesMode)

                Button("New Browser") {
                    store.selectedWorkspace?.addPane(kind: .browser, side: .right)
                }
                .keyboardShortcut("b", modifiers: .command)
                .disabled(store.selectedWorkspace == nil || store.isNotesMode)
            }
            CommandGroup(replacing: .pasteboard) {
                Button("Cut") {
                    sendStandardEditAction(#selector(NSText.cut(_:)))
                }
                .keyboardShortcut("x", modifiers: .command)

                Button("Copy") {
                    copyOrCaptureScreenshot()
                }
                .keyboardShortcut("c", modifiers: .command)

                Button("Paste") {
                    pasteIntoSelectedPane()
                }
                .keyboardShortcut("v", modifiers: .command)

                // Replacing `.pasteboard` drops the stock Select All too;
                // re-add it so ⌘A works in the notes editor and other fields.
                Button("Select All") {
                    sendStandardEditAction(#selector(NSText.selectAll(_:)))
                }
                .keyboardShortcut("a", modifiers: .command)
            }
            CommandGroup(after: .sidebar) {
                Button(store.selectedWorkspace?.isInspectorPresented == true ? "Hide Inspector" : "Show Inspector") {
                    guard let workspace = store.selectedWorkspace else { return }
                    workspace.setInspectorPresented(!workspace.isInspectorPresented)
                }
                .keyboardShortcut("i", modifiers: .command)
                .disabled(store.selectedWorkspace == nil)

                Button(store.isNotesMode ? "Hide Notes" : "Show Notes") {
                    store.toggleNotesMode()
                }
                .keyboardShortcut("0", modifiers: .command)

                Button(store.isRemoteDesktopMode ? "Hide Remote Desktop" : "Show Remote Desktop") {
                    store.toggleRemoteDesktopMode()
                }
                .keyboardShortcut("0", modifiers: [.command, .shift])

                Button("Focus Selected Pane") {
                    guard let workspace = store.selectedWorkspace,
                          let pane = workspace.selectedPane else { return }
                    workspace.focusPane(pane)
                }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(store.selectedWorkspace?.selectedPane == nil)
            }
            CommandGroup(after: .toolbar) {
                Button("Increase Text Size") {
                    uiZoom = UIZoomLadder.next(after: uiZoom)
                }
                .keyboardShortcut("=", modifiers: .command)

                Button("Decrease Text Size") {
                    uiZoom = UIZoomLadder.previous(before: uiZoom)
                }
                .keyboardShortcut("-", modifiers: .command)

                Button("Actual Size") {
                    uiZoom = UIZoomLadder.default
                }
                .keyboardShortcut("0", modifiers: [.command, .option])
            }
            CommandMenu("Browser") {
                Button("Reload") {
                    selectedBrowserState?.requestNavigationCommand("blau://reload")
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(selectedBrowserState == nil)

                Button("Focus Address Bar") {
                    selectFirstBrowserPaneIfNeeded()
                    NotificationCenter.default.post(name: .pilotFocusBrowserAddressBar, object: nil)
                }
                .keyboardShortcut("l", modifiers: .command)
                .disabled(!hasBrowserPaneInActiveWorkspace)

                Divider()

                // One-click jump to web debugging for the mobile app (#75).
                // Enabled only while an iPhone peer is connected; activates
                // Safari, where iOS remote Web Inspector lives.
                Button("Debug Mobile App in Browser") {
                    SafariWebInspector.open()
                }
                .keyboardShortcut("d", modifiers: [.command, .option])
                .disabled(!syncService.isConnected)
            }
        }

        // Standard macOS Settings window (⌘,). A thin, extensible shell; the
        // first real use is peer key sharing (#51), which drops into the
        // shared Identity & Keys section.
        Settings {
            PilotSettingsView()
                .environment(secureIdentity)
        }
    }

    private func activeTerminalPane(in workspaceID: UUID?) -> Pane? {
        guard let workspaceID,
              let workspace = store.workspaces.first(where: { $0.id == workspaceID }) else { return nil }
        return workspace.frontmostTerminalPane
    }

    private func terminalView(for paneID: UUID?) -> GhosttyMetalView? {
        guard let paneID else { return nil }
        return GhosttyMetalView.view(for: paneID)
    }

    private var activeTerminalView: GhosttyMetalView? {
        terminalView(for: activeTerminalPane(in: store.selectedWorkspaceID)?.id)
    }

    private var selectedTerminalView: GhosttyMetalView? {
        guard let pane = store.selectedWorkspace?.selectedPane,
              pane.kind == .terminal else { return nil }
        return terminalView(for: pane.id)
    }

    private var selectedBrowserState: BrowserState? {
        guard let pane = store.selectedWorkspace?.selectedPane,
              pane.kind == .browser else { return nil }
        return pane.browserState
    }

    private var hasBrowserPaneInActiveWorkspace: Bool {
        store.selectedWorkspace?.panes.contains { $0.kind == .browser } ?? false
    }

    /// If the currently selected pane isn't a browser, hand selection to the
    /// first browser pane in the workspace so ⌘L (and the rest of the
    /// browser toolbar) has something to operate on. This makes ⌘L work
    /// even when the user just clicked into another pane.
    private func selectFirstBrowserPaneIfNeeded() {
        guard let workspace = store.selectedWorkspace else { return }
        if let selected = workspace.selectedPane, selected.kind == .browser { return }
        if let firstBrowser = workspace.sortedPanes.first(where: { $0.kind == .browser }) {
            workspace.selectedPaneID = firstBrowser.id
        }
    }

    private func copyOrCaptureScreenshot() {
        // If a text editor (sheet field, address bar, etc.) is the
        // first responder, let it handle the standard copy.
        if let responder = NSApp.keyWindow?.firstResponder,
           responder is NSText {
            sendStandardEditAction(#selector(NSText.copy(_:)))
            return
        }

        // In a device pane: ⌘C grabs a screenshot to the clipboard. The
        // session's `clipboardCopyCount` increment drives the toast.
        if let pane = store.selectedWorkspace?.selectedPane,
           pane.kind == .device {
            DeviceCaptureRegistry.shared.session(for: pane.id)
                .copyScreenshotToClipboard()
            return
        }

        sendStandardEditAction(#selector(NSText.copy(_:)))
    }

    private func pasteIntoSelectedPane() {
        // If a text editor (sheet field, alert, address bar, etc.) is the
        // first responder, let it handle paste normally — otherwise the
        // terminal beneath the sheet would steal the keystroke.
        if let responder = NSApp.keyWindow?.firstResponder,
           responder is NSText {
            sendStandardEditAction(#selector(NSText.paste(_:)))
            return
        }

        if let terminal = selectedTerminalView {
            terminal.paste(nil)
            return
        }

        sendStandardEditAction(#selector(NSText.paste(_:)))
    }

    private func sendStandardEditAction(_ selector: Selector) {
        NSApp.sendAction(selector, to: nil, from: nil)
    }

    private func setupSync() {
        guard !didSetupSync else { return }
        didSetupSync = true

        secureIdentity.send = { syncService.send($0) }
        syncService.onReceive = { (message: SyncMessage) in
            switch message {
            case .selectWorkspace(let sel):
                store.isNotesMode = false
                store.isRemoteDesktopMode = false
                store.selectedWorkspaceID = sel.workspaceID
                // Ensure the workspace's terminal is selected and focused
                if let workspace = store.workspaces.first(where: { $0.id == sel.workspaceID }),
                   let terminalPane = workspace.frontmostTerminalPane {
                    workspace.selectedPaneID = terminalPane.id
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        _ = GhosttyMetalView.focus(paneID: terminalPane.id)
                    }
                }
            case .selectTab(let sel):
                // Copilot tab selector picked a pane: focus that workspace and
                // make the chosen pane its active tab.
                store.isNotesMode = false
                store.isRemoteDesktopMode = false
                store.selectedWorkspaceID = sel.workspaceID
                if let workspace = store.workspaces.first(where: { $0.id == sel.workspaceID }) {
                    workspace.selectedPaneID = sel.tabID
                    // Only terminal panes are focusable in the Ghostty registry;
                    // harmless no-op for browser/device panes.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        _ = GhosttyMetalView.focus(paneID: sel.tabID)
                    }
                }
            case .workspaceState:
                break
            case .deviceStatus(let status):
                peerDeviceStatus = status
            case .mouseMove(let m):
                MouseBridge.shared.move(dx: m.dx, dy: m.dy)
            case .mouseClick:
                MouseBridge.shared.click()
            case .voiceRecord(let command):
                // Audio capture + transcription now live on Copilot.
                // Pilot uses this message only to switch to the
                // workspace whose button is being held (snappy UI) and
                // to remember which terminal pane should receive the
                // text when the iPhone sends `.transcribedSpeech`.
                switch command.control {
                case .start:
                    let targetWorkspaceID = command.workspaceID ?? store.selectedWorkspaceID
                    if let targetWorkspaceID {
                        store.selectedWorkspaceID = targetWorkspaceID
                    }
                    recordingTargetPaneID = activeTerminalPane(in: targetWorkspaceID)?.id
                    isPeerRecording = true
                case .stop:
                    isPeerRecording = false
                }
            case .transcribedSpeech(let speech):
                let trimmed = speech.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    recordingTargetPaneID = nil
                    return
                }
                // Prefer the pane captured at hold-start, fall back to
                // the current active terminal of the workspace whose
                // button was held (or the workspace selected when the
                // message arrives, in case Pilot was launched mid-hold).
                let targetPaneID = recordingTargetPaneID
                    ?? activeTerminalPane(in: speech.workspaceID ?? store.selectedWorkspaceID)?.id
                recordingTargetPaneID = nil
                terminalView(for: targetPaneID)?.pasteText(trimmed)
            case .terminalInput(let input):
                switch input {
                case .enter:
                    activeTerminalView?.sendEnter()
                }
            case .deviceKey(let announce):
                // Auto-exchange device keys with Copilot (issue #51).
                secureIdentity.receive(announce)
            }
        }
        syncService.start()

        // Re-broadcast workspace state only when it actually changed; the 1s
        // tick otherwise encoded + sent an identical payload to Copilot every
        // second for the whole session. Reset on disconnect so a reconnecting
        // peer always gets a fresh snapshot.
        @MainActor final class LastBroadcast {
            var summaries: [WorkspaceSummary]?
            var selectedID: UUID?
        }
        let lastBroadcast = LastBroadcast()
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            Task { @MainActor in
                guard syncService.isConnected else {
                    lastBroadcast.summaries = nil
                    return
                }
                let summaries = store.summaries
                let selectedID = store.selectedWorkspaceID
                guard summaries != lastBroadcast.summaries
                        || selectedID != lastBroadcast.selectedID else { return }
                lastBroadcast.summaries = summaries
                lastBroadcast.selectedID = selectedID
                let state = WorkspaceState(
                    workspaces: summaries,
                    selectedWorkspaceID: selectedID
                )
                syncService.send(.workspaceState(state), reliable: false)
            }
        }
    }

    private func sendLocalDeviceStatus() {
        let status = DeviceStatus(audioOutput: headphoneDetector.audioOutput)
        syncService.send(.deviceStatus(status))
    }
}

/// Invisible helper that observes Pilot's effective light/dark appearance and
/// reports it to connected Plotters. Sends on first connect (via the
/// `isConnected` transition) and whenever the Mac's appearance changes, so a
/// connected Plotter mirrors Pilot's mode rather than its own.
private struct AppearanceReporter: View {
    @Environment(\.colorScheme) private var colorScheme
    let isConnected: Bool
    let send: (Bool) -> Void

    var body: some View {
        Color.clear
            .onChange(of: colorScheme) { _, scheme in
                if isConnected { send(scheme == .dark) }
            }
            .onChange(of: isConnected) { _, connected in
                if connected { send(colorScheme == .dark) }
            }
    }
}

/// Pilot's Settings window contents (⌘,). Reuses the shared `SettingsSections`
/// (Identity & Keys + About) in a grouped macOS form. Extend by adding more
/// sections here or in `SettingsSections`.
private struct PilotSettingsView: View {
    var body: some View {
        Form {
            SettingsSections()
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 380)
    }
}

// MARK: - Versioned schema & migration plan

/// Versioned schema + migration plan for Pilot's local SwiftData store.
///
/// Declaring an explicit version and plan makes app upgrades migrate the store
/// deterministically instead of failing to open (which previously caused the
/// corruption handler to quarantine — and once, destroy — real user data).
///
/// SwiftData handles *additive* changes (a new `@Model`, or a new stored
/// property that has a default value) automatically as a lightweight migration.
/// *Non-additive* changes (renaming a property, changing a type, changing a
/// uniqueness constraint or relationship) are NOT automatic and must be given an
/// explicit `MigrationStage` here, or the store will fail to open on upgrade.
///
/// To evolve the schema safely:
///   1. Copy the current models' shape into a new `PilotSchemaV2` enum
///      (snapshot — do not just point at the live types if they changed).
///   2. Append `PilotSchemaV2.self` to `schemas` (newest last).
///   3. Add a `MigrationStage` from V1 to V2 in `stages`:
///      `.lightweight` for additive changes, `.custom` otherwise.
///   4. Point `PilotApp`'s `Schema(versionedSchema:)` at the newest version.
/// Never edit a shipped version's `models` in place — that is exactly what
/// breaks upgrades and risks data loss.
enum PilotSchemaV1: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }

    static var models: [any PersistentModel.Type] {
        [
            Workspace.self,
            Pane.self,
            BrowserState.self,
            EditorState.self,
            Note.self,
            RemoteDesktopConnection.self,
        ]
    }
}

enum PilotMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [PilotSchemaV1.self] }

    /// One stage per version-to-version upgrade. Empty today (only V1 exists);
    /// append a stage whenever a new `PilotSchemaV*` is added above.
    static var stages: [MigrationStage] { [] }
}
