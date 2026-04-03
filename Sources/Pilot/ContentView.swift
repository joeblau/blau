import AppKit
import SwiftData
import SwiftUI

struct ContentView: View {
    @Bindable var store: WorkspaceStore
    var syncService: PeerSyncService
    var deviceStatus: DeviceStatus
    @State private var gitStore = GitCommitStore()
    @State private var showInspector = false
    @State private var transcriptionService = TranscriptionService()
    @State private var showTranscription = false
    @FocusState private var isBrowserURLFieldFocused: Bool

    var body: some View {
        let activeInspectorRepoPath = showInspector ? selectedTerminalRepoPath : nil
        let _ = store.changeCount  // observation dependency for pin/unpin re-sort
        let workspaces = store.workspaces

        NavigationSplitView {
            List(selection: $store.selectedWorkspaceID) {
                let pinned = workspaces.filter(\.isPinned)
                let unpinned = workspaces.filter { !$0.isPinned }

                if !pinned.isEmpty {
                    Section("Pinned") {
                        ForEach(pinned) { workspace in
                            workspaceRow(workspace)
                        }
                    }
                }

                Section("Workspaces") {
                    ForEach(unpinned) { workspace in
                        workspaceRow(workspace)
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 12) {
                    DeviceStatusIndicator(emoji: "📱", isConnected: syncService.isConnected)
                    DeviceStatusIndicator(emoji: "⌚", isConnected: deviceStatus.isWatchConnected)
                    DeviceStatusIndicator(emoji: "🎧", isConnected: deviceStatus.isAirPodsConnected)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
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
                            WorkspaceView(workspace: workspace)
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

                if showTranscription && transcriptionService.isTranscribing {
                    TranscriptionOverlay(service: transcriptionService)
                }
            }
        }
        .inspector(isPresented: $showInspector) {
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
            if let workspace = store.selectedWorkspace {
                for pane in workspace.panes where pane.kind == .terminal {
                    pane.resetBellCount()
                }
            }
        }
        .task {
            syncInspectorRepo(activeInspectorRepoPath)
        }
        .onReceive(NotificationCenter.default.publisher(for: .pilotFocusBrowserAddressBar)) { _ in
            focusBrowserAddressBar()
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
                }
                .disabled(store.selectedWorkspace == nil)

                Button {
                    showTranscription.toggle()
                    if showTranscription {
                        Task { await transcriptionService.start() }
                    } else {
                        Task { await transcriptionService.stop() }
                    }
                } label: {
                    Label("Transcription",
                          systemImage: showTranscription ? "waveform.circle.fill" : "waveform.circle")
                }

                Button {
                    showInspector.toggle()
                } label: {
                    Label("Inspector", systemImage: "sidebar.trailing")
                }
            }
        }
        .background {
            ForEach(1...9, id: \.self) { index in
                Button("") {
                    let ws = workspaces
                    guard index - 1 < ws.count else { return }
                    store.selectedWorkspaceID = ws[index - 1].id
                }
                .keyboardShortcut(KeyEquivalent(Character("\(index)")), modifiers: .command)
                .hidden()
            }
            Button("") {
                guard let workspace = store.selectedWorkspace,
                      let pane = workspace.selectedPane else { return }
                workspace.removePane(pane)
            }
            .keyboardShortcut("w", modifiers: .command)
            .hidden()
        }
    }

    private func workspaceRow(_ workspace: Workspace) -> some View {
        HStack {
            TextField("Name", text: Bindable(workspace).name)
            if workspace.isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
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

        TextField("URL", text: Bindable(state).urlText)
            .textFieldStyle(.plain)
            .font(.system(size: 13, weight: .medium))
            .focused($isBrowserURLFieldFocused)
            .onSubmit { state.navigate() }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .frame(minWidth: 240, idealWidth: 420, maxWidth: 560)

        Button {
            if state.isLoading {
                state.requestNavigationCommand("blau://stop")
            } else {
                state.requestNavigationCommand("blau://reload")
            }
        } label: {
            Label(state.isLoading ? "Stop" : "Reload",
                  systemImage: state.isLoading ? "xmark" : "arrow.clockwise")
        }

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

    private var selectedTerminalRepoPath: String? {
        guard let pane = store.selectedWorkspace?.selectedPane else { return nil }
        guard pane.kind == .terminal else { return nil }

        let directory = pane.currentDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !directory.isEmpty else { return nil }

        return GitCommitStore.findGitRoot(from: directory)
    }

    private func syncInspectorRepo(_ repoPath: String?) {
        guard let repoPath else {
            gitStore.stopWatching()
            return
        }

        gitStore.startWatching(directory: repoPath)
    }
}

private struct DeviceStatusIndicator: View {
    let emoji: String
    let isConnected: Bool

    var body: some View {
        Text(emoji)
            .overlay(alignment: .topTrailing) {
                Circle()
                    .fill(isConnected ? .green : .red)
                    .frame(width: 8, height: 8)
                    .offset(x: 3, y: -3)
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
        deviceStatus: DeviceStatus()
    )
    .modelContainer(ContentViewPreviewData.container)
}
