import Foundation

/// Shared (Plotter app + widget extension) access to the latest mirror
/// snapshot, persisted in the App Group container so the widget process can
/// read what the app wrote. Foundation-only on purpose so it compiles cleanly
/// in both the app and the lightweight widget extension.
public enum PlotterSnapshotStore {
    public static let appGroupID = "group.app.blau.plotter"

    /// Connection + freshness metadata shown alongside the snapshot image.
    public struct Status: Codable, Sendable, Hashable {
        public var isConnected: Bool
        /// Human label for the session (e.g. the Mac name), shown in the widget.
        public var title: String
        public var updatedAt: Date

        public init(isConnected: Bool, title: String, updatedAt: Date) {
            self.isConnected = isConnected
            self.title = title
            self.updatedAt = updatedAt
        }
    }

    private static var container: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
    }

    private static var imageURL: URL? { container?.appendingPathComponent("snapshot.jpg") }
    private static var statusURL: URL? { container?.appendingPathComponent("status.json") }

    /// Write a fresh JPEG frame + status. Called (throttled) by the app as
    /// snapshots arrive from Pilot.
    public static func writeSnapshot(jpeg: Data, status: Status) {
        if let imageURL { try? jpeg.write(to: imageURL, options: .atomic) }
        writeStatus(status)
    }

    /// Update just the status (e.g. on connect/disconnect) without a new image.
    public static func writeStatus(_ status: Status) {
        guard let statusURL, let data = try? JSONEncoder().encode(status) else { return }
        try? data.write(to: statusURL, options: .atomic)
    }

    public static func readImageData() -> Data? {
        guard let imageURL else { return nil }
        return try? Data(contentsOf: imageURL)
    }

    public static func readStatus() -> Status? {
        guard let statusURL, let data = try? Data(contentsOf: statusURL) else { return nil }
        return try? JSONDecoder().decode(Status.self, from: data)
    }
}
