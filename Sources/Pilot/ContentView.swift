import SwiftUI

struct ContentView: View {
    @State private var store = WorkspaceStore()

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
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button(action: store.addWorkspace) {
                    Label("New Workspace", systemImage: "plus")
                }
            }
        }
    }
}

#Preview {
    ContentView()
}
