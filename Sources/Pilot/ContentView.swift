import SwiftUI

struct ContentView: View {
    @State private var store = WorkspaceStore()
    @State private var showInspector = false
    @State private var gitStore = GitCommitStore()

    var body: some View {
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
                // Default to this project's repo
                let fallback = "/Users/joeblau/Developer/joeblau/src/blau"
                let home = FileManager.default.homeDirectoryForCurrentUser.path
                let dir = GitCommitStore.findGitRoot(from: home) ?? fallback
                gitStore.startWatching(directory: dir)
            } else {
                gitStore.stopWatching()
            }
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
}

#Preview {
    ContentView()
}
