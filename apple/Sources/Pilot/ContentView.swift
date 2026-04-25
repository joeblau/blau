import AppKit
import SwiftData
import SwiftUI

struct ContentView: View {
    @Bindable var store: WorkspaceStore
    var syncService: PeerSyncService
    var peerDeviceStatus: DeviceStatus
    var localAudioOutput: AudioOutputDevice?
    var remoteTranscription: TranscriptionService
    @State private var gitStore = GitCommitStore()
    @State private var rootPathEditorWorkspaceID: UUID?
    @State private var rootPathEditorText = ""
    @FocusState private var isBrowserURLFieldFocused: Bool

    var body: some View {
        let activeInspectorRepoPath = isInspectorPresentedForSelectedWorkspace ? selectedWorkspaceRootPath : nil
        let _ = store.changeCount  // observation dependency for pin/unpin re-sort
        let workspaces = store.workspaces
        let workspaceShortcutIDs = workspaces.prefix(9).map(\.id)

        NavigationSplitView {
            List(selection: $store.selectedWorkspaceID) {
                let pinned = workspaces.filter(\.isPinned)
                let unpinned = workspaces.filter { !$0.isPinned }

                if !pinned.isEmpty {
                    Section("Pinned") {
                        ForEach(pinned) { workspace in
                            workspaceRow(workspace)
                        }
                        .onMove(perform: store.movePinnedWorkspaces)
                    }
                }

                Section("Workspaces") {
                    ForEach(unpinned) { workspace in
                        workspaceRow(workspace)
                    }
                    .onMove(perform: store.moveUnpinnedWorkspaces)
                }
            }
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 12) {
                    RecordingStatusIndicator(isRecording: remoteTranscription.isTranscribing)

                    Spacer(minLength: 0)

                    HStack(spacing: 12) {
                        ForEach(connectedDevices) { device in
                            Image(systemName: device.kind.systemImageName)
                                .symbolVariant(device.kind.usesFillVariant ? .fill : .none)
                                .foregroundStyle(device.isConnected ? .green : .red)
                                .help(device.name ?? device.kind.displayName)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 220)
        } detail: {
            ZStack {
                if workspaces.isEmpty {
                    ContentUnavailableView("No Workspace Selected",
                                           systemImage: "rectangle.on.rectangle.slash",
                                           description: Text("Create a workspace with the + button."))
                } else if let selectedWorkspaceID = store.selectedWorkspaceID,
                          workspaces.contains(where: { $0.id == selectedWorkspaceID }) {
                    ZStack {
                        ForEach(workspaces) { workspace in
                            let isActive = workspace.id == selectedWorkspaceID
                            WorkspaceView(workspace: workspace, isActive: isActive)
                                .zIndex(isActive ? 1 : 0)
                                .opacity(isActive ? 1 : 0)
                                .allowsHitTesting(isActive)
                                .accessibilityHidden(!isActive)
                        }
                    }
                } else {
                    ContentUnavailableView("No Workspace Selected",
                                           systemImage: "rectangle.on.rectangle.slash",
                                           description: Text("Create a workspace with the + button."))
                }

            }
            .navigationTitle(store.selectedWorkspace?.name ?? "")
        }
        .inspector(isPresented: selectedWorkspaceInspectorPresentedBinding) {
            InspectorPanelView(
                gitStore: gitStore,
                selectedTab: selectedWorkspaceInspectorTabBinding
            )
                .inspectorColumnWidth(min: 220, ideal: 280, max: 400)
        }
        .onChange(of: activeInspectorRepoPath) {
            syncInspectorRepo(activeInspectorRepoPath)
        }
        .onChange(of: store.selectedWorkspaceID) {
            syncSelectedWorkspaceRootPath()
            if let workspace = store.selectedWorkspace {
                for pane in workspace.panes where pane.kind == .terminal {
                    pane.resetBellCount()
                }
            }
            focusSelectedWorkspaceTerminal()
        }
        .task {
            syncSelectedWorkspaceRootPath()
            syncInspectorRepo(activeInspectorRepoPath)
            focusSelectedWorkspaceTerminal()
        }
        .onReceive(NotificationCenter.default.publisher(for: .pilotFocusBrowserAddressBar)) { _ in
            focusBrowserAddressBar()
        }
        .alert("Update Root Path", isPresented: rootPathEditorPresentedBinding) {
            TextField("Root path", text: $rootPathEditorText)

            Button("Cancel", role: .cancel) {
                dismissRootPathEditor()
            }

            Button("Sync") {
                syncEditedRootPath()
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button(action: store.addWorkspace) {
                    Label("New Workspace", systemImage: "plus")
                }
            }
            ToolbarItemGroup(placement: .secondaryAction) {
                if let pane = store.selectedWorkspace?.selectedPane,
                   pane.kind == .browser,
                   let browserState = pane.browserState {
                    browserToolbar(state: browserState)
                }
            }
            ToolbarItemGroup(placement: .primaryAction) {
                ControlGroup {
                    Button {
                        store.selectedWorkspace?.addPane(kind: .terminal, side: .right)
                    } label: {
                        Label("New Terminal", systemImage: "terminal")
                    }
                    .keyboardShortcut("t", modifiers: .command)

                    Button {
                        store.selectedWorkspace?.addPane(kind: .browser, side: .right)
                    } label: {
                        Label("New Browser", systemImage: "safari")
                    }
                    .keyboardShortcut("b", modifiers: .command)

                    Button {
                        store.selectedWorkspace?.addPane(kind: .simulator, side: .right)
                    } label: {
                        Label("New Simulator", systemImage: "iphone")
                    }
                    .keyboardShortcut("i", modifiers: [.command, .shift])
                }
                .disabled(store.selectedWorkspace == nil)
                Button {
                    guard let workspace = store.selectedWorkspace else { return }
                    workspace.setInspectorPresented(!workspace.isInspectorPresented)
                } label: {
                    Label("Inspector", systemImage: "sidebar.trailing")
                }
                .disabled(store.selectedWorkspace == nil)
            }
        }
        .background {
            Group {
                ForEach(1...9, id: \.self) { index in
                    Button("") {
                        guard index - 1 < workspaceShortcutIDs.count else { return }
                        store.selectedWorkspaceID = workspaceShortcutIDs[index - 1]
                    }
                    .keyboardShortcut(KeyEquivalent(Character("\(index)")), modifiers: .command)
                    .hidden()
                }
            }
            .id(workspaceShortcutIDs)
            Button("") {
                guard let workspace = store.selectedWorkspace,
                      let pane = workspace.selectedPane else { return }
                workspace.removePane(pane)
            }
            .keyboardShortcut("w", modifiers: .command)
            .hidden()
        }
    }

    private var connectedDevices: [ConnectedDevice] {
        let audioDevice = ConnectedDevice(
            kind: localAudioOutput?.kind ?? .headphonesBluetooth,
            isConnected: localAudioOutput != nil,
            name: localAudioOutput?.name
        )
        return [
            ConnectedDevice(kind: .iphone, isConnected: syncService.isConnected),
            ConnectedDevice(kind: .appleWatch, isConnected: peerDeviceStatus.isWatchConnected),
            audioDevice
        ]
    }

    private func workspaceRow(_ workspace: Workspace) -> some View {
        HStack {
            TextField("Name", text: Bindable(workspace).name)
            if workspace.badgeCount > 0 {
                Text("\(workspace.badgeCount)")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.red, in: Capsule())
            }
        }
        .tag(workspace.id)
        .contextMenu {
            Button {
                showRootPathEditor(for: workspace)
            } label: {
                Label("Update Root Path", systemImage: "arrow.triangle.2.circlepath")
            }

            Divider()

            Button {
                store.togglePin(workspace)
            } label: {
                Label(
                    workspace.isPinned ? "Unpin" : "Pin to Top",
                    systemImage: workspace.isPinned ? "pin.slash" : "pin"
                )
            }
            Divider()
            Button("Delete", role: .destructive) {
                store.deleteWorkspace(workspace)
            }
        }
    }

    @ViewBuilder
    private func browserToolbar(state: BrowserState) -> some View {
        ControlGroup {
            Button { state.requestNavigationCommand("blau://back") } label: {
                Label("Back", systemImage: "chevron.left")
            }
            .disabled(!state.canGoBack)

            Button { state.requestNavigationCommand("blau://forward") } label: {
                Label("Forward", systemImage: "chevron.right")
            }
            .disabled(!state.canGoForward)
        }

        browserAddressField(state: state)

        Menu {
            ForEach(AppearanceMode.allCases, id: \.self) { mode in
                Button {
                    state.appearanceMode = mode
                } label: {
                    HStack {
                        Text(mode.rawValue)
                        if state.appearanceMode == mode {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            Label("Appearance", systemImage: appearanceIcon(for: state.appearanceMode))
        }

        Menu {
            Button("Default Profile") {}
            Divider()
            Button("Manage Profiles...") {}
        } label: {
            Label("Profile", systemImage: "person.circle")
        }

        Button {
            state.toggleDeveloperTools()
        } label: {
            Label("Developer Tools", systemImage: "hammer")
        }
    }

    private func browserAddressField(state: BrowserState) -> some View {
        TextField("URL", text: Bindable(state).urlText)
            .textFieldStyle(.plain)
            .font(.system(size: 13, weight: .medium))
            .focused($isBrowserURLFieldFocused)
            .onSubmit { state.navigate() }
            .padding(.leading, 14)
            .padding(.trailing, 36)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor).opacity(0.7), lineWidth: 1)
            }
            .overlay(alignment: .trailing) {
                browserReloadButton(state: state)
                    .padding(.trailing, 10)
            }
            .frame(minWidth: 240, idealWidth: 420, maxWidth: 560)
    }

    private func browserReloadButton(state: BrowserState) -> some View {
        Button {
            if state.isLoading {
                state.requestNavigationCommand("blau://stop")
            } else {
                state.requestNavigationCommand("blau://reload")
            }
        } label: {
            ZStack {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .medium))
                    .opacity(state.isLoading ? 0 : 1)

                if state.isLoading {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .frame(width: 14, height: 14)
        }
        .buttonStyle(.plain)
        .help(state.isLoading ? "Stop" : "Reload")
    }

    private func appearanceIcon(for mode: AppearanceMode) -> String {
        switch mode {
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max"
        case .dark: "moon"
        }
    }

    private var selectedWorkspaceInspectorTabBinding: Binding<InspectorTab> {
        Binding(
            get: { self.store.selectedWorkspace?.inspectorTab ?? .actions },
            set: { tab in
                self.store.selectedWorkspace?.setInspectorTab(tab)
            }
        )
    }

    private var selectedWorkspaceInspectorPresentedBinding: Binding<Bool> {
        Binding(
            get: { isInspectorPresentedForSelectedWorkspace },
            set: { isPresented in
                store.selectedWorkspace?.setInspectorPresented(isPresented)
            }
        )
    }

    private var isInspectorPresentedForSelectedWorkspace: Bool {
        store.selectedWorkspace?.isInspectorPresented ?? false
    }

    private var selectedBrowserState: BrowserState? {
        guard let pane = store.selectedWorkspace?.selectedPane,
              pane.kind == .browser else { return nil }
        return pane.browserState
    }

    private func focusBrowserAddressBar() {
        guard selectedBrowserState != nil else { return }
        isBrowserURLFieldFocused = true
        DispatchQueue.main.async {
            NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
        }
    }

    private func focusSelectedWorkspaceTerminal() {
        guard let workspace = store.selectedWorkspace,
              let pane = workspace.frontmostTerminalPane else { return }
        workspace.setFrontmostTerminalPaneID(pane.id)
        DispatchQueue.main.async {
            _ = GhosttyMetalView.focus(paneID: pane.id)
        }
    }

    private var selectedWorkspaceRootPath: String? {
        store.selectedWorkspace?.effectiveRootPath
    }

    private var rootPathEditorPresentedBinding: Binding<Bool> {
        Binding(
            get: { rootPathEditorWorkspaceID != nil },
            set: { isPresented in
                if !isPresented {
                    dismissRootPathEditor()
                }
            }
        )
    }

    private func syncSelectedWorkspaceRootPath() {
        store.selectedWorkspace?.syncDefaultRootPathIfNeeded()
    }

    private func showRootPathEditor(for workspace: Workspace) {
        rootPathEditorWorkspaceID = workspace.id
        rootPathEditorText = workspace.rootPath
    }

    private func dismissRootPathEditor() {
        rootPathEditorWorkspaceID = nil
        rootPathEditorText = ""
    }

    private func syncEditedRootPath() {
        guard let workspace = workspaceForRootPathEditor else {
            dismissRootPathEditor()
            return
        }

        workspace.setRootPath(rootPathEditorText)
        dismissRootPathEditor()
    }

    private var workspaceForRootPathEditor: Workspace? {
        guard let rootPathEditorWorkspaceID else { return nil }
        return store.workspaces.first { $0.id == rootPathEditorWorkspaceID }
    }

    private func syncInspectorRepo(_ repoPath: String?) {
        guard let repoPath else {
            gitStore.stopWatching()
            return
        }

        gitStore.startWatching(directory: repoPath)
    }
}

private struct RecordingStatusIndicator: View {
    let isRecording: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: isRecording ? "waveform.circle.fill" : "waveform.circle")
                .foregroundStyle(isRecording ? .red : .secondary)

            Text(isRecording ? "Recording" : "Mic Idle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

extension Notification.Name {
    static let pilotFocusBrowserAddressBar = Notification.Name("pilotFocusBrowserAddressBar")
}


@MainActor
private enum ContentViewPreviewData {
    static let container: ModelContainer = {
        let schema = Schema([Workspace.self, Pane.self, BrowserState.self])
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        return try! ModelContainer(for: schema, configurations: configuration)
    }()
}

#Preview {
    ContentView(
        store: WorkspaceStore(modelContext: ContentViewPreviewData.container.mainContext),
        syncService: PeerSyncService(role: .advertiser, displayName: "Preview"),
        peerDeviceStatus: DeviceStatus(),
        localAudioOutput: nil,
        remoteTranscription: TranscriptionService()
    )
    .modelContainer(ContentViewPreviewData.container)
}
