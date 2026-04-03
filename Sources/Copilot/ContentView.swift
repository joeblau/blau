import SwiftUI

struct ContentView: View {
    let syncService: PeerSyncService
    let watchDelegate: PhoneSessionDelegate

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
                let pinned = workspaces.filter(\.isPinned)
                let unpinned = workspaces.filter { !$0.isPinned }

                VolumeScrollListView(
                    items: workspaces,
                    selectedID: $selectedID,
                    onHighlightChanged: { workspace in
                        syncService.send(.selectWorkspace(SelectWorkspace(workspaceID: workspace.id)))
                    }
                ) { workspace, isHighlighted in
                    HStack {
                        if workspace.isPinned {
                            Image(systemName: "pin.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                        }
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
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 4) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(syncService.isConnected ? .green : .red)
                        .frame(width: 8, height: 8)
                    Text(syncService.isConnected ? "Pilot Connected" : "Pilot Disconnected")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    Circle()
                        .fill(watchDelegate.isWatchReachable ? .green : .red)
                        .frame(width: 8, height: 8)
                    Text(watchDelegate.isWatchReachable ? "Wingman Connected" : "Wingman Disconnected")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
        }
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
    ContentView(syncService: PeerSyncService(role: .browser, displayName: "Preview"),
               watchDelegate: PhoneSessionDelegate())
}
