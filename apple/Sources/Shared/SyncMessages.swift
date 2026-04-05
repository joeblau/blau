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

struct AudioOutputDevice: Codable, Sendable, Hashable {
    let kind: ConnectedDeviceKind
    let name: String
}

struct DeviceStatus: Codable, Sendable {
    var isWatchConnected: Bool = false
    var audioOutput: AudioOutputDevice?
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
    case beats
    case headphonesWired
    case headphonesBluetooth
    case usb
    case speaker
    case unknown

    var id: String { rawValue }

    var systemImageName: String {
        switch self {
        case .computer: return "laptopcomputer"
        case .iphone: return "iphone"
        case .appleWatch: return "applewatch"
        case .airpods: return "airpods.gen3"
        case .airpodsPro: return "airpods.pro"
        case .airpodsMax: return "airpods.max"
        case .beats: return "beats.headphones"
        case .headphonesWired: return "headphones"
        case .headphonesBluetooth: return "headphones"
        case .usb: return "cable.connector"
        case .speaker: return "hifispeaker"
        case .unknown: return "speaker.wave.2"
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
        case .beats: return "Beats"
        case .headphonesWired: return "Wired Headphones"
        case .headphonesBluetooth: return "Bluetooth Headphones"
        case .usb: return "USB Audio"
        case .speaker: return "Speaker"
        case .unknown: return "Audio Output"
        }
    }

    var usesFillVariant: Bool {
        switch self {
        case .computer, .appleWatch, .speaker:
            return true
        case .iphone, .airpods, .airpodsPro, .airpodsMax, .beats,
             .headphonesWired, .headphonesBluetooth, .usb, .unknown:
            return false
        }
    }

    var isHeadphones: Bool {
        switch self {
        case .airpods, .airpodsPro, .airpodsMax, .beats,
             .headphonesWired, .headphonesBluetooth, .usb:
            return true
        case .computer, .iphone, .appleWatch, .speaker, .unknown:
            return false
        }
    }

    // Shared classification heuristic used by both iOS (HeadphoneRouteMonitor)
    // and macOS (HeadphoneDetector). Pure function: name string in, kind out.
    //
    //   "airpods max" → .airpodsMax
    //   "airpods pro" → .airpodsPro
    //   "airpods"     → .airpods
    //   "beats"       → .beats
    //   other         → defaultKind
    static func classify(name: String, defaultKind: ConnectedDeviceKind) -> ConnectedDeviceKind {
        let lowered = name.lowercased()
        if lowered.contains("airpods max") { return .airpodsMax }
        if lowered.contains("airpods pro") { return .airpodsPro }
        if lowered.contains("airpods") { return .airpods }
        if lowered.contains("beats") { return .beats }
        return defaultKind
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
            kind: deviceStatus.audioOutput?.kind ?? .headphonesBluetooth,
            isConnected: deviceStatus.audioOutput != nil,
            name: deviceStatus.audioOutput?.name
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
                ConnectedDevice(kind: .appleWatch, isConnected: deviceStatus.isWatchConnected)
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
