import SwiftUI

struct ContentView: View {
    let syncService: PeerSyncService
    let watchDelegate: PhoneSessionDelegate
    let headphoneRouteMonitor: HeadphoneRouteMonitor

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
                        },
                        onVolumeHoldStart: {
                            syncService.send(.voiceRecord(.start))
                        },
                        onVolumeHoldEnd: {
                            syncService.send(.voiceRecord(.stop))
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
            .toolbarTitleDisplayMode(.inlineLarge)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Image(systemName: "laptopcomputer")
                        .symbolVariant(.fill)
                        .foregroundStyle(syncService.isConnected ? .green : .red)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Image(systemName: "applewatch")
                        .symbolVariant(.fill)
                        .foregroundStyle(watchDelegate.isWatchReachable ? .green : .red)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Image(systemName: "airpods.pro")
                        .foregroundStyle(headphoneRouteMonitor.isHeadphonesConnected ? .green : .red)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if syncService.isConnected {
                TrackpadView(syncService: syncService)
            }
        }
        .task { setupSync() }
        .onChange(of: watchDelegate.isWatchReachable) {
            sendDeviceStatus()
        }
        .onChange(of: headphoneRouteMonitor.isHeadphonesConnected) {
            sendDeviceStatus()
        }
        .onChange(of: syncService.isConnected) {
            guard syncService.isConnected else { return }
            sendDeviceStatus()
        }
    }

    private func setupSync() {
        syncService.onReceive = { message in
            switch message {
            case .workspaceState(let state):
                workspaces = state.workspaces
                selectedID = state.selectedWorkspaceID
            case .selectWorkspace, .deviceStatus, .mouseMove, .mouseClick, .voiceRecord:
                break
            }
        }
        syncService.start()
    }

    private func sendDeviceStatus() {
        let status = DeviceStatus(
            isWatchConnected: watchDelegate.isWatchReachable,
            isAirPodsConnected: headphoneRouteMonitor.isHeadphonesConnected
        )
        syncService.send(.deviceStatus(status))
    }
}

#Preview {
    ContentView(syncService: PeerSyncService(role: .browser, displayName: "Preview"),
               watchDelegate: PhoneSessionDelegate(),
               headphoneRouteMonitor: HeadphoneRouteMonitor())
}
