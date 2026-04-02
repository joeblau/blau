import SwiftUI

struct ContentView: View {
    @State private var store = WorkspaceStore()
    @State private var showInspector = false
    @State private var gitStore = GitCommitStore()

    var body: some View {
        let activeInspectorRepoPath = selectedTerminalRepoPath

        NavigationSplitView {
            List(store.workspaces, selection: $store.selectedWorkspaceID) { workspace in
                TextField("Name", text: Bindable(workspace).name)
                    .contextMenu {
                        Button("Delete", role: .destructive) {
                            store.deleteWorkspace(workspace)
                        }
                    }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 220)
        } detail: {
            if let workspace = store.selectedWorkspace {
                WorkspaceView(workspace: workspace)
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
            if showInspector {
                syncInspectorRepo(activeInspectorRepoPath)
            } else {
                gitStore.stopWatching()
            }
        }
        .onChange(of: activeInspectorRepoPath) {
            guard showInspector else { return }
            syncInspectorRepo(activeInspectorRepoPath)
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button(action: store.addWorkspace) {
                    Label("New Workspace", systemImage: "plus")
                }
            }
            ToolbarItem(placement: .secondaryAction) {
                HStack(spacing: 0) {
                    Spacer()
                    Button {
                        store.selectedWorkspace?.addPane(kind: .terminal, side: .right)
                    } label: {
                        Label("New Terminal", systemImage: "terminal")
                    }
                    .disabled(store.selectedWorkspace == nil)

                    Button {
                        store.selectedWorkspace?.addPane(kind: .browser, side: .right)
                    } label: {
                        Label("New Browser", systemImage: "safari")
                    }
                    .disabled(store.selectedWorkspace == nil)
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showInspector.toggle()
                } label: {
                    Label("Inspector", systemImage: "sidebar.trailing")
                }
            }
        }
    }

    private var selectedTerminalRepoPath: String? {
        guard let pane = store.selectedWorkspace?.selectedPane else { return nil }
        guard pane.kind == .terminal else { return nil }

        let directory = pane.terminalState.currentDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
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

#Preview {
    ContentView()
}
