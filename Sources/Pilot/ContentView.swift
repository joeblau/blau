import AppKit
import SwiftData
import SwiftUI

struct ContentView: View {
    @Bindable var store: WorkspaceStore
    var syncService: PeerSyncService
    @State private var showInspector = false
    @State private var gitStore = GitCommitStore()

    var body: some View {
        let activeInspectorRepoPath = selectedTerminalRepoPath
        let workspaces = store.workspaces

        NavigationSplitView {
            List(workspaces, selection: $store.selectedWorkspaceID) { workspace in
                TextField("Name", text: Bindable(workspace).name)
                    .contextMenu {
                        Button("Delete", role: .destructive) {
                            store.deleteWorkspace(workspace)
                        }
                    }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 220)
        } detail: {
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
        .inspector(isPresented: $showInspector) {
            InspectorPanelView(gitStore: gitStore)
                .inspectorColumnWidth(min: 220, ideal: 280, max: 400)
        }
        .onChange(of: showInspector) {
            syncInspectorRepo(activeInspectorRepoPath)
        }
        .onChange(of: activeInspectorRepoPath) {
            syncInspectorRepo(activeInspectorRepoPath)
        }
        .task {
            syncInspectorRepo(activeInspectorRepoPath)
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

                    Button {
                        store.selectedWorkspace?.addPane(kind: .browser, side: .right)
                    } label: {
                        Label("New Browser", systemImage: "safari")
                    }
                }
                .disabled(store.selectedWorkspace == nil)

                Button {
                    showInspector.toggle()
                } label: {
                    Label("Inspector", systemImage: "sidebar.trailing")
                }
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
        syncService: PeerSyncService(role: .advertiser, displayName: "Preview")
    )
    .modelContainer(ContentViewPreviewData.container)
}
