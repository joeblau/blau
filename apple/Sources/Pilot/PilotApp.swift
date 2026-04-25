import AppKit
import SwiftData
import SwiftUI

@main
struct PilotApp: App {
    let modelContainer: ModelContainer

    @State private var store: WorkspaceStore
    @State private var peerDeviceStatus = DeviceStatus()
    @State private var headphoneDetector = HeadphoneDetector()
    @State private var remoteTranscription = TranscriptionService()
    @State private var syncService = PeerSyncService(
        role: .advertiser,
        displayName: Host.current().localizedName ?? "Mac"
    )
    @State private var recordingTargetPaneID: UUID?
    @State private var didSetupSync = false

    init() {
        let schema = Schema([Workspace.self, Pane.self, BrowserState.self, SimulatorState.self])
        let container = try! ModelContainer(for: schema)
        self.modelContainer = container
        self._store = State(initialValue: WorkspaceStore(modelContext: container.mainContext))
    }

    var body: some Scene {
        WindowGroup {
            ContentView(store: store, syncService: syncService, peerDeviceStatus: peerDeviceStatus, localAudioOutput: headphoneDetector.audioOutput, remoteTranscription: remoteTranscription)
                .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
                .task {
                    // Skip services that prompt for permissions when XCTest is host-running us.
                    guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
                    _ = MouseBridge.shared.ensurePermissions()
                    headphoneDetector.start()
                    setupSync()
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
                    sendStandardEditAction(#selector(NSText.copy(_:)))
                }
                .keyboardShortcut("c", modifiers: .command)

                Button("Paste") {
                    pasteIntoSelectedPane()
                }
                .keyboardShortcut("v", modifiers: .command)
            }
            CommandGroup(after: .sidebar) {
                Button(store.selectedWorkspace?.isInspectorPresented == true ? "Hide Inspector" : "Show Inspector") {
                    guard let workspace = store.selectedWorkspace else { return }
                    workspace.setInspectorPresented(!workspace.isInspectorPresented)
                }
                .keyboardShortcut("i", modifiers: .command)
                .disabled(store.selectedWorkspace == nil)

                Button("Focus Selected Pane") {
                    guard let workspace = store.selectedWorkspace,
                          let pane = workspace.selectedPane else { return }
                    workspace.focusPane(pane)
                }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(store.selectedWorkspace?.selectedPane == nil)
            }
            CommandMenu("Browser") {
                Button("Reload") {
                    selectedBrowserState?.requestNavigationCommand("blau://reload")
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(selectedBrowserState == nil)

                Button("Focus Address Bar") {
                    NotificationCenter.default.post(name: .pilotFocusBrowserAddressBar, object: nil)
                }
                .keyboardShortcut("l", modifiers: .command)
                .disabled(selectedBrowserState == nil)
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

    private func pasteIntoSelectedPane() {
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
                switch command.control {
                case .start:
                    let targetWorkspaceID = command.workspaceID ?? store.selectedWorkspaceID
                    if let targetWorkspaceID {
                        store.selectedWorkspaceID = targetWorkspaceID
                    }
                    recordingTargetPaneID = activeTerminalPane(in: targetWorkspaceID)?.id
                    Task { await remoteTranscription.start() }
                case .stop:
                    let targetPaneID = recordingTargetPaneID
                    recordingTargetPaneID = nil
                    Task {
                        await remoteTranscription.stop()
                        let text = [remoteTranscription.finalText, remoteTranscription.partialText]
                            .filter { !$0.isEmpty }
                            .joined(separator: " ")
                            .replacingOccurrences(of: "Waiting for speech...", with: "")
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !text.isEmpty else { return }
                        terminalView(for: targetPaneID)?.pasteText(text)
                    }
                }
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
