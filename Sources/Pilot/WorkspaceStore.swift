import SwiftUI

@Observable
final class WorkspaceStore {
    var workspaces: [Workspace] = []
    var selectedWorkspaceID: UUID?

    var selectedWorkspace: Workspace? {
        workspaces.first { $0.id == selectedWorkspaceID }
    }

    var summaries: [WorkspaceSummary] {
        workspaces.map { WorkspaceSummary(id: $0.id, name: $0.name) }
    }

    func addWorkspace() {
        let workspace = Workspace(name: "Workspace \(workspaces.count + 1)")
        workspaces.append(workspace)
        selectedWorkspaceID = workspace.id
    }

    func deleteWorkspace(_ workspace: Workspace) {
        workspaces.removeAll { $0.id == workspace.id }
        if selectedWorkspaceID == workspace.id {
            selectedWorkspaceID = workspaces.first?.id
        }
    }
}
