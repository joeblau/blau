import Foundation

// DeviceCaptureRegistry — keyed by Pane.id so the SwiftUI toolbar in
// `ContentView` and the `DevicePaneView` it lives next to share the
// same `DeviceCaptureSession`. Mirrors the pattern used by the Ghostty
// terminal views which look themselves up by paneID.
@MainActor
final class DeviceCaptureRegistry {
    static let shared = DeviceCaptureRegistry()

    private var sessions: [UUID: DeviceCaptureSession] = [:]

    func session(for paneID: UUID) -> DeviceCaptureSession {
        if let existing = sessions[paneID] {
            return existing
        }
        let session = DeviceCaptureSession()
        sessions[paneID] = session
        return session
    }

    func existingSession(for paneID: UUID) -> DeviceCaptureSession? {
        sessions[paneID]
    }

    func remove(paneID: UUID) {
        guard let session = sessions.removeValue(forKey: paneID) else { return }
        session.stop()
    }
}
