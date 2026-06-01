import Foundation
import ActivityKit

/// Live Activity describing an active Plotter mirror session. Shared between the
/// Plotter app (which starts/updates/ends it) and the widget extension (which
/// renders it on the lock screen / Dynamic Island).
public struct PlotterActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable, Sendable {
        public var isConnected: Bool
        public var title: String
        public var updatedAt: Date

        public init(isConnected: Bool, title: String, updatedAt: Date) {
            self.isConnected = isConnected
            self.title = title
            self.updatedAt = updatedAt
        }
    }

    /// Static label for the activity (set once when the session starts).
    public var sessionName: String

    public init(sessionName: String) {
        self.sessionName = sessionName
    }
}
