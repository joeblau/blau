import AppKit
import SwiftData
import SwiftUI

@main
struct PilotApp: App {
    let modelContainer: ModelContainer

    @State private var store: WorkspaceStore
    @State private var deviceStatus = DeviceStatus()
    @State private var remoteTranscription = TranscriptionService()
    @State private var syncService = PeerSyncService(
        role: .advertiser,
        displayName: Host.current().localizedName ?? "Mac"
    )

    init() {
        let schema = Schema([Workspace.self, Pane.self, BrowserState.self])
        let container = try! ModelContainer(for: schema)
        self.modelContainer = container
        self._store = State(initialValue: WorkspaceStore(modelContext: container.mainContext))
    }

    var body: some Scene {
        WindowGroup {
            ContentView(store: store, syncService: syncService, deviceStatus: deviceStatus, remoteTranscription: remoteTranscription)
                .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
                .task {
                    _ = MouseBridge.shared.ensurePermissions()
                    setupSync()
                }
        }
        .modelContainer(modelContainer)
        .commands {
            CommandMenu("Browser") {
                Button("Focus Address Bar") {
                    NotificationCenter.default.post(name: .pilotFocusBrowserAddressBar, object: nil)
                }
                .keyboardShortcut("l", modifiers: .command)
                .disabled(store.selectedWorkspace?.selectedPane?.kind != .browser)
            }
        }
    }

    private var activeTerminalView: GhosttyMetalView? {
        guard let pane = store.selectedWorkspace?.selectedPane,
              pane.kind == .terminal else { return nil }
        return GhosttyMetalView.view(for: pane.id)
    }

    private func setupSync() {
        syncService.onReceive = { (message: SyncMessage) in
            switch message {
            case .selectWorkspace(let sel):
                store.selectedWorkspaceID = sel.workspaceID
            case .workspaceState:
                break
            case .deviceStatus(let status):
                deviceStatus = status
            case .mouseMove(let m):
                MouseBridge.shared.move(dx: m.dx, dy: m.dy)
            case .mouseClick:
                MouseBridge.shared.click()
            case .voiceRecord(let control):
                switch control {
                case .start:
                    Task { await remoteTranscription.start() }
                case .stop:
                    Task {
                        await remoteTranscription.stop()
                        let text = [remoteTranscription.finalText, remoteTranscription.partialText]
                            .filter { !$0.isEmpty }
                            .joined(separator: " ")
                            .replacingOccurrences(of: "Waiting for speech...", with: "")
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !text.isEmpty else { return }
                        activeTerminalView?.pasteText(text)
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

        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            Task { @MainActor in
                guard syncService.isConnected else { return }
                let state = WorkspaceState(
                    workspaces: store.summaries,
                    selectedWorkspaceID: store.selectedWorkspaceID
                )
                syncService.send(.workspaceState(state))
            }
        }
    }
}
