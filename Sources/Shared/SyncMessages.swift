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

struct VoiceRecordCommand: Codable, Sendable {
    let control: VoiceRecordControl
    let workspaceID: UUID?
}

enum TerminalInput: String, Codable, Sendable {
    case enter
}

enum SyncMessage: Codable, Sendable {
    case workspaceState(WorkspaceState)
    case selectWorkspace(SelectWorkspace)
    case deviceStatus(DeviceStatus)
    case mouseMove(MouseMove)
    case mouseClick(MouseClick)
    case voiceRecord(VoiceRecordCommand)
    case terminalInput(TerminalInput)
}

struct MouseMove: Codable, Sendable {
    let dx: Float
    let dy: Float
}

struct MouseClick: Codable, Sendable {
    let button: Int // 0 = left
}

struct ConnectedHeadphones: Codable, Sendable, Hashable {
    let kind: ConnectedDeviceKind
    let name: String
}

struct DeviceStatus: Codable, Sendable {
    var isWatchConnected: Bool = false
    var connectedHeadphones: ConnectedHeadphones?
}

enum ConnectedDeviceAppRole: String, Codable, Sendable {
    case pilot
    case copilot
}

enum ConnectedDeviceKind: String, Codable, Sendable, Hashable, Identifiable {
    case computer
    case iphone
    case appleWatch
    case airpods
    case airpodsPro
    case airpodsMax
    case headphonesWired
    case headphonesBluetooth

    var id: String { rawValue }

    var systemImageName: String {
        switch self {
        case .computer: return "laptopcomputer"
        case .iphone: return "iphone"
        case .appleWatch: return "applewatch"
        case .airpods: return "airpods"
        case .airpodsPro: return "airpods.pro"
        case .airpodsMax: return "airpodsmax"
        case .headphonesWired: return "headphones"
        case .headphonesBluetooth: return "headphones"
        }
    }

    var displayName: String {
        switch self {
        case .computer: return "Computer"
        case .iphone: return "iPhone"
        case .appleWatch: return "Apple Watch"
        case .airpods: return "AirPods"
        case .airpodsPro: return "AirPods Pro"
        case .airpodsMax: return "AirPods Max"
        case .headphonesWired: return "Wired Headphones"
        case .headphonesBluetooth: return "Bluetooth Headphones"
        }
    }

    var usesFillVariant: Bool {
        switch self {
        case .computer, .appleWatch:
            return true
        case .iphone, .airpods, .airpodsPro, .airpodsMax, .headphonesWired, .headphonesBluetooth:
            return false
        }
    }

    var isHeadphones: Bool {
        switch self {
        case .airpods, .airpodsPro, .airpodsMax, .headphonesWired, .headphonesBluetooth:
            return true
        case .computer, .iphone, .appleWatch:
            return false
        }
    }
}

struct ConnectedDevice: Codable, Sendable, Hashable, Identifiable {
    let kind: ConnectedDeviceKind
    let isConnected: Bool
    var name: String? = nil

    var id: ConnectedDeviceKind { kind }
}

enum ConnectedDeviceCatalog {
    static func devices(
        for role: ConnectedDeviceAppRole,
        peerConnected: Bool,
        deviceStatus: DeviceStatus
    ) -> [ConnectedDevice] {
        let headphoneDevice = ConnectedDevice(
            kind: deviceStatus.connectedHeadphones?.kind ?? .headphonesBluetooth,
            isConnected: deviceStatus.connectedHeadphones != nil,
            name: deviceStatus.connectedHeadphones?.name
        )
        switch role {
        case .pilot:
            return [
                ConnectedDevice(kind: .iphone, isConnected: peerConnected),
                ConnectedDevice(kind: .appleWatch, isConnected: deviceStatus.isWatchConnected),
                headphoneDevice
            ]
        case .copilot:
            return [
                ConnectedDevice(kind: .computer, isConnected: peerConnected),
                ConnectedDevice(kind: .appleWatch, isConnected: deviceStatus.isWatchConnected),
                headphoneDevice
            ]
        }
    }
}

struct WorkspaceState: Codable, Sendable {
    let workspaces: [WorkspaceSummary]
    let selectedWorkspaceID: UUID?
}

struct SelectWorkspace: Codable, Sendable {
    let workspaceID: UUID
}
