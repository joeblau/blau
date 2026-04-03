import Foundation

struct WorkspaceSummary: Identifiable, Codable, Sendable, Hashable {
    let id: UUID
    var name: String
    var isPinned: Bool = false
    var badgeCount: Int = 0
}

enum AudioControl: String, Codable, Sendable {
    case start, stop
}

enum SyncMessage: Codable, Sendable {
    case workspaceState(WorkspaceState)
    case selectWorkspace(SelectWorkspace)
    case deviceStatus(DeviceStatus)
    case audioControl(AudioControl)
    case audioChunk(Data)
}

struct DeviceStatus: Codable, Sendable {
    var isWatchConnected: Bool = false
    var isAirPodsConnected: Bool = false
}

struct WorkspaceState: Codable, Sendable {
    let workspaces: [WorkspaceSummary]
    let selectedWorkspaceID: UUID?
}

struct SelectWorkspace: Codable, Sendable {
    let workspaceID: UUID
}
