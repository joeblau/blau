import SwiftUI

struct WorkspaceView: View {
    let workspace: Workspace

    var body: some View {
        Text(workspace.name)
            .font(.largeTitle)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(workspace.name)
    }
}
