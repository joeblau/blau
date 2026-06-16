import Foundation
import SwiftData

/// A saved remote-desktop connection — one tab in the global Remote Desktop
/// section. Each connects to a machine's built-in VNC / Screen-Sharing server
/// (macOS advertises this as the Bonjour service `_rfb._tcp`).
///
/// Only non-secret connection metadata is persisted. The password is never
/// stored in the model — it's entered at connect time and held in memory for
/// the session only (mirrors how the editor never persists secrets).
@Model
final class RemoteDesktopConnection {
    #Unique([\RemoteDesktopConnection.id])

    var id: UUID = UUID()
    /// Hostname or IP of the VNC server (e.g. "studio.local" or "192.168.1.20").
    var host: String = ""
    /// VNC port; macOS Screen Sharing listens on 5900 by default.
    var port: Int = 5900
    /// Optional friendly label; falls back to the host for the tab title.
    var nickname: String = ""
    /// Optional username for Apple Remote Desktop ("macOS") authentication.
    var username: String = ""
    var sortOrder: Int = 0
    var createdAt: Date = Date()
    var lastConnectedAt: Date?

    init(host: String = "", port: Int = 5900, nickname: String = "", username: String = "", sortOrder: Int = 0) {
        self.id = UUID()
        self.host = host
        self.port = port
        self.nickname = nickname
        self.username = username
        self.sortOrder = sortOrder
        self.createdAt = Date()
    }

    /// Tab label: the nickname if set, else the host, else a placeholder.
    var displayTitle: String {
        let trimmedNickname = nickname.trimmingCharacters(in: .whitespaces)
        if !trimmedNickname.isEmpty { return trimmedNickname }
        let trimmedHost = host.trimmingCharacters(in: .whitespaces)
        return trimmedHost.isEmpty ? "New Connection" : trimmedHost
    }
}
