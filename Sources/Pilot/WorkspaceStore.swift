import SwiftData
import SwiftUI

@Observable
@MainActor
final class WorkspaceStore {
    let modelContext: ModelContext
    var changeCount: Int = 0
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
        _ = changeCount // access to establish observation dependency
        let descriptor = FetchDescriptor<Workspace>()
        let items = (try? modelContext.fetch(descriptor)) ?? []

        return items.sorted { lhs, rhs in
            if lhs.isPinned != rhs.isPinned {
                return lhs.isPinned && !rhs.isPinned
            }

            if lhs.workspaceSortOrder != rhs.workspaceSortOrder {
                return lhs.workspaceSortOrder < rhs.workspaceSortOrder
            }

            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    func togglePin(_ workspace: Workspace) {
        let remaining = workspaces.filter { $0.id != workspace.id }

        workspace.isPinned.toggle()

        var pinned = remaining.filter(\.isPinned)
        var unpinned = remaining.filter { !$0.isPinned }

        if workspace.isPinned {
            pinned.insert(workspace, at: 0)
        } else {
            unpinned.insert(workspace, at: 0)
        }

        normalizeWorkspaceSortOrder(pinned + unpinned)
        try? modelContext.save()
        changeCount += 1
    }

    var selectedWorkspace: Workspace? {
        workspaces.first { $0.id == selectedWorkspaceID }
    }

    var summaries: [WorkspaceSummary] {
        workspaces.map { WorkspaceSummary(id: $0.id, name: $0.name, isPinned: $0.isPinned) }
    }

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
        if let stored = UserDefaults.standard.string(forKey: "selectedWorkspaceID") {
            self.selectedWorkspaceID = UUID(uuidString: stored)
        }
        cleanupBadDirectories()
    }

    private func cleanupBadDirectories() {
        let home = NSHomeDirectory()
        let descriptor = FetchDescriptor<Pane>()
        guard let allPanes = try? modelContext.fetch(descriptor) else { return }
        for pane in allPanes {
            let dir = pane.currentDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
            if dir == "/" || dir == home {
                pane.currentDirectory = ""
            }
        }
    }

    func addWorkspace() {
        let workspace = Workspace(name: "Workspace \(workspaces.count + 1)")
        workspace.workspaceSortOrder = workspaces.count
        modelContext.insert(workspace)
        try? modelContext.save()
        selectedWorkspaceID = workspace.id
    }

    func deleteWorkspace(_ workspace: Workspace) {
        let wasSelected = selectedWorkspaceID == workspace.id
        modelContext.delete(workspace)
        normalizeWorkspaceSortOrder(workspaces.filter { $0.id != workspace.id })
        try? modelContext.save()
        if wasSelected {
            selectedWorkspaceID = workspaces.first?.id
        }
    }

    private func normalizeWorkspaceSortOrder(_ orderedWorkspaces: [Workspace]) {
        for (index, workspace) in orderedWorkspaces.enumerated() {
            workspace.workspaceSortOrder = index
        }
    }
}
