import SwiftData
import SwiftUI

@main
struct PilotApp: App {
    let modelContainer: ModelContainer

    @State private var store: WorkspaceStore
    @State private var deviceStatus = DeviceStatus()
    @State private var audioPlayback = AudioPlaybackService()
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
            ContentView(store: store, syncService: syncService, deviceStatus: deviceStatus)
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

    private func setupSync() {
        syncService.onReceive = { (message: SyncMessage) in
            switch message {
            case .selectWorkspace(let sel):
                store.selectedWorkspaceID = sel.workspaceID
            case .workspaceState:
                break
            case .deviceStatus(let status):
                deviceStatus = status
            case .audioControl(let control):
                switch control {
                case .start: audioPlayback.startPlayback()
                case .stop:  audioPlayback.stopPlayback()
                }
            case .audioChunk(let data):
                audioPlayback.enqueue(data)
            case .mouseMove(let m):
                MouseBridge.shared.move(dx: m.dx, dy: m.dy)
            case .mouseClick:
                MouseBridge.shared.click()
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
