import SwiftUI

struct ContentView: View {
    let syncService: PeerSyncService
    let watchDelegate: PhoneSessionDelegate

    @State private var workspaces: [WorkspaceSummary] = []
    @State private var selectedID: UUID?

    var body: some View {
        NavigationStack {
            Group {
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
                            if workspace.isPinned {
                                Image(systemName: "pin.fill")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.secondary)
                            }
                            Text(workspace.name)
                                .fontWeight(isHighlighted ? .semibold : .regular)
                            if workspace.badgeCount > 0 {
                                Text("\(workspace.badgeCount)")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(.red, in: Capsule())
                            }
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
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    DeviceStatusButton(emoji: "💻", isConnected: syncService.isConnected)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    DeviceStatusButton(emoji: "⌚", isConnected: watchDelegate.isWatchReachable)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    DeviceStatusButton(emoji: "🎧", isConnected: false)
                }
            }
        }
        .task { setupSync() }
        .onChange(of: watchDelegate.isWatchReachable) {
            sendDeviceStatus()
        }
    }

    private func setupSync() {
        syncService.onReceive = { message in
            switch message {
            case .workspaceState(let state):
                workspaces = state.workspaces
                selectedID = state.selectedWorkspaceID
            case .selectWorkspace:
                break
            case .deviceStatus:
                break
            }
        }
        syncService.start()
    }

    private func sendDeviceStatus() {
        let status = DeviceStatus(
            isWatchConnected: watchDelegate.isWatchReachable,
            isAirPodsConnected: false
        )
        syncService.send(.deviceStatus(status))
    }
}

private struct DeviceStatusButton: View {
    let emoji: String
    let isConnected: Bool

    var body: some View {
        Button {} label: {
            Text(emoji)
                .overlay(alignment: .topTrailing) {
                    Circle()
                        .fill(isConnected ? .green : .red)
                        .frame(width: 12, height: 12)
                        .offset(x: 6, y: -6)
                }
        }
    }
}

#Preview {
    ContentView(syncService: PeerSyncService(role: .browser, displayName: "Preview"),
               watchDelegate: PhoneSessionDelegate())
}
