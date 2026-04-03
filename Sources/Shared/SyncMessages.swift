import Foundation

struct WorkspaceSummary: Identifiable, Codable, Sendable, Hashable {
    let id: UUID
    var name: String
    var isPinned: Bool = false
    var badgeCount: Int = 0
}

enum VoiceRecordControl: String, Codable, Sendable {
    case start, stop
}

enum SyncMessage: Codable, Sendable {
    case workspaceState(WorkspaceState)
    case selectWorkspace(SelectWorkspace)
    case deviceStatus(DeviceStatus)
    case mouseMove(MouseMove)
    case mouseClick(MouseClick)
    case voiceRecord(VoiceRecordControl)
}

struct MouseMove: Codable, Sendable {
    let dx: Float
    let dy: Float
}

struct MouseClick: Codable, Sendable {
    let button: Int // 0 = left
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
