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

    @AppStorage("ui.zoom") private var uiZoom: Double = UIZoomLadder.default

    init() {
        let schema = Schema([Workspace.self, Pane.self, BrowserState.self, Note.self])
        let configuration = ModelConfiguration(schema: schema, url: Self.persistentStoreURL())
        let container = try! ModelContainer(for: schema, configurations: configuration)
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

    /// Pilot runs unsandboxed so Ghostty can launch real shell processes, but
    /// older builds wrote SwiftData into the app container. Keep using that
    /// stable location so notes/workspaces survive the sandbox change.
    private static func persistentStoreURL() -> URL {
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        let directory = home
            .appendingPathComponent("Library/Containers/app.blau.pilot/Data/Library/Application Support", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("default.store")
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
                    frameSender.onClientCountChanged = { count in
                        Task { @MainActor in
                            plotterClientCount = count
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
                    annotationReceiver.onMessage = { message in
                        Task { @MainActor in
                            remoteInkModel.handle(message)
                        }
                    }
                    // Always mirror Pilot's window over the high-bandwidth
                    // frame channel while running; gating on a connected peer
                    // comes in a later phase.
                    frameSender.start()
                    screenMirror.start()
                    annotationReceiver.start()
                }
                .onChange(of: headphoneDetector.audioOutput) {
                    sendLocalDeviceStatus()
                }
                .onChange(of: syncService.isConnected) {
                    guard syncService.isConnected else { return }
                    sendLocalDeviceStatus()
                }
        }
        .modelContainer(modelContainer)
        .commands {
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
            }
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

        syncService.onReceive = { (message: SyncMessage) in
            switch message {
            case .selectWorkspace(let sel):
                store.isNotesMode = false
                store.selectedWorkspaceID = sel.workspaceID
                // Ensure the workspace's terminal is selected and focused
                if let workspace = store.workspaces.first(where: { $0.id == sel.workspaceID }),
                   let terminalPane = workspace.frontmostTerminalPane {
                    workspace.selectedPaneID = terminalPane.id
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        _ = GhosttyMetalView.focus(paneID: terminalPane.id)
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
            }
        }
        syncService.start()

        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            Task { @MainActor in
                guard syncService.isConnected else { return }
                let state = WorkspaceState(
                    workspaces: store.summaries,
                    selectedWorkspaceID: store.selectedWorkspaceID
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
