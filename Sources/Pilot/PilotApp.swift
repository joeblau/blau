import SwiftUI

@main
struct PilotApp: App {
    @State private var store = WorkspaceStore()
    @State private var syncService = PeerSyncService(
        role: .advertiser,
        displayName: Host.current().localizedName ?? "Mac"
    )

    var body: some Scene {
        WindowGroup {
            ContentView(store: store, syncService: syncService)
                .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
                .task { setupSync() }
        }
    }

    private func setupSync() {
        syncService.onReceive = { (message: SyncMessage) in
            switch message {
            case .selectWorkspace(let sel):
                store.selectedWorkspaceID = sel.workspaceID
            case .workspaceState:
                break
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
