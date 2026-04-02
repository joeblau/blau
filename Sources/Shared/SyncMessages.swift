import Foundation

struct WorkspaceSummary: Identifiable, Codable, Sendable, Hashable {
    let id: UUID
    var name: String
}

enum SyncMessage: Codable, Sendable {
    case workspaceState(WorkspaceState)
    case selectWorkspace(SelectWorkspace)
}

struct WorkspaceState: Codable, Sendable {
    let workspaces: [WorkspaceSummary]
    let selectedWorkspaceID: UUID?
}

struct SelectWorkspace: Codable, Sendable {
    let workspaceID: UUID
}
