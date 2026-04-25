import Foundation
import SwiftData

@Model
final class SimulatorState {
    var deviceUDID: String = ""
    var deviceTypeIdentifier: String = ""
    var runtimeIdentifier: String = ""
    var displayName: String = ""
    var createdAt: Date = Date()

    @Transient var connectionStatus: ConnectionStatus = .disconnected
    @Transient var lastError: String? = nil
    @Transient var bootProgress: BootProgress = .idle
    @Transient var logsVisible: Bool = false

    init(
        deviceUDID: String = "",
        deviceTypeIdentifier: String = "",
        runtimeIdentifier: String = "",
        displayName: String = ""
    ) {
        self.deviceUDID = deviceUDID
        self.deviceTypeIdentifier = deviceTypeIdentifier
        self.runtimeIdentifier = runtimeIdentifier
        self.displayName = displayName
        self.createdAt = Date()
    }

    var needsProvisioning: Bool {
        deviceUDID.isEmpty || deviceTypeIdentifier.isEmpty || runtimeIdentifier.isEmpty
    }
}

enum ConnectionStatus: Sendable, Equatable {
    case disconnected
    case connecting
    case booting
    case streaming
    case reconnecting
    case failed(String)
}

enum BootProgress: Sendable, Equatable {
    case idle
    case creatingDevice
    case booting(elapsedSeconds: Int)
    case startingFramebuffer
    case ready
}
