import SwiftUI

struct ContentView: View {
    let syncService: PeerSyncService
    let watchDelegate: PhoneSessionDelegate

    @State private var workspaces: [WorkspaceSummary] = []
    @State private var selectedID: UUID?

    var body: some View {
        NavigationStack {
            mainContent
            .navigationTitle("Copilot")
            .toolbarTitleDisplayMode(.inlineLarge)
            .toolbar {
                deviceToolbar
            }
            .safeAreaInset(edge: .bottom) {
                trackpadInset
            }
        }
        .task { setupSync() }
        .onChange(of: watchDelegate.isWatchReachable) {
            sendDeviceStatus()
        }
        .onChange(of: syncService.isConnected) {
            guard syncService.isConnected else { return }
            sendDeviceStatus()
        }
    }

    @ViewBuilder
    private var mainContent: some View {
        if !syncService.isConnected && workspaces.isEmpty {
            ContentUnavailableView {
                Label("Looking for Pilot...", systemImage: "antenna.radiowaves.left.and.right")
            } description: {
                Text("Make sure Pilot is running on your Mac.")
            } actions: {
                ProgressView()
            }
        } else if workspaces.isEmpty {
            ContentUnavailableView(
                "No Workspaces",
                systemImage: "rectangle.on.rectangle.slash",
                description: Text("Create a workspace in Pilot.")
            )
        } else {
            workspaceList
        }
    }

    private var workspaceList: some View {
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
            workspaceRow(workspace, isHighlighted: isHighlighted)
        }
    }

    @ViewBuilder
    private func workspaceRow(_ workspace: WorkspaceSummary, isHighlighted: Bool) -> some View {
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
        }
        .padding(.vertical, 4)
    }

    @ToolbarContentBuilder
    private var deviceToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            ForEach(connectedDevices) { device in
                deviceIcon(device)
            }
        }
    }

    @ViewBuilder
    private func deviceIcon(_ device: ConnectedDevice) -> some View {
        Image(systemName: device.kind.systemImageName)
            .symbolVariant(device.kind.usesFillVariant ? .fill : .none)
            .foregroundStyle(device.isConnected ? .green : .red)
    }

    @ViewBuilder
    private var trackpadInset: some View {
        if syncService.isConnected {
            TrackpadView(syncService: syncService)
        }
    }

    private var localDeviceStatus: DeviceStatus {
        DeviceStatus(
            isWatchConnected: watchDelegate.isWatchReachable,
            isAirPodsConnected: false
        )
    }

    private var connectedDevices: [ConnectedDevice] {
        ConnectedDeviceCatalog.devices(
            for: .copilot,
            peerConnected: syncService.isConnected,
            deviceStatus: localDeviceStatus
        )
    }

    private func setupSync() {
        syncService.onReceive = { message in
            switch message {
            case .workspaceState(let state):
                workspaces = state.workspaces
                selectedID = state.selectedWorkspaceID
            case .selectWorkspace, .deviceStatus, .mouseMove, .mouseClick, .voiceRecord, .terminalInput:
                break
            }
        }
        syncService.start()
    }

    private func sendDeviceStatus() {
        syncService.send(.deviceStatus(localDeviceStatus))
    }
}

#Preview {
    ContentView(syncService: PeerSyncService(role: .browser, displayName: "Preview"),
               watchDelegate: PhoneSessionDelegate())
}
