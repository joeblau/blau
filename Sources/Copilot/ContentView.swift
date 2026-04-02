import SwiftUI

struct ContentView: View {
    let syncService: PeerSyncService

    @State private var workspaces: [WorkspaceSummary] = []
    @State private var selectedID: UUID?

    var body: some View {
        NavigationStack {
            if !syncService.isConnected && workspaces.isEmpty {
                ContentUnavailableView {
                    Label("Looking for Pilot...", systemImage: "antenna.radiowaves.left.and.right")
                } description: {
                    Text("Make sure Pilot is running on your Mac.")
                } actions: {
                    ProgressView()
                }
            } else if workspaces.isEmpty {
                ContentUnavailableView("No Workspaces",
                                       systemImage: "rectangle.on.rectangle.slash",
                                       description: Text("Create a workspace in Pilot."))
            } else {
                VolumeScrollListView(
                    items: workspaces,
                    selectedID: $selectedID,
                    onHighlightChanged: { workspace in
                        syncService.send(.selectWorkspace(SelectWorkspace(workspaceID: workspace.id)))
                    }
                ) { workspace, isHighlighted in
                    HStack {
                        Text(workspace.name)
                            .fontWeight(isHighlighted ? .semibold : .regular)
                        Spacer()
                        if isHighlighted {
                            Image(systemName: "chevron.right")
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .navigationTitle("Copilot")
        .task { setupSync() }
    }

    private func setupSync() {
        syncService.onReceive = { message in
            switch message {
            case .workspaceState(let state):
                workspaces = state.workspaces
                selectedID = state.selectedWorkspaceID
            case .selectWorkspace:
                break
            }
        }
        syncService.start()
    }
}

#Preview {
    ContentView(syncService: PeerSyncService(role: .browser, displayName: "Preview"))
}
