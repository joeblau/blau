import SwiftData
import SwiftUI

@Observable
@MainActor
final class WorkspaceStore {
    let modelContext: ModelContext
    var selectedWorkspaceID: UUID? {
        didSet {
            if let id = selectedWorkspaceID {
                UserDefaults.standard.set(id.uuidString, forKey: "selectedWorkspaceID")
            } else {
                UserDefaults.standard.removeObject(forKey: "selectedWorkspaceID")
            }
        }
    }

    var workspaces: [Workspace] {
        let descriptor = FetchDescriptor<Workspace>(sortBy: [SortDescriptor(\.name)])
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    var selectedWorkspace: Workspace? {
        workspaces.first { $0.id == selectedWorkspaceID }
    }

    var summaries: [WorkspaceSummary] {
        workspaces.map { WorkspaceSummary(id: $0.id, name: $0.name) }
    }

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
        if let stored = UserDefaults.standard.string(forKey: "selectedWorkspaceID") {
            self.selectedWorkspaceID = UUID(uuidString: stored)
        }
    }

    func addWorkspace() {
        let workspace = Workspace(name: "Workspace \(workspaces.count + 1)")
        modelContext.insert(workspace)
        selectedWorkspaceID = workspace.id
    }

    func deleteWorkspace(_ workspace: Workspace) {
        let wasSelected = selectedWorkspaceID == workspace.id
        modelContext.delete(workspace)
        if wasSelected {
            selectedWorkspaceID = workspaces.first?.id
        }
    }
}
