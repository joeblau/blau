import SwiftUI
import WatchConnectivity

private struct WingmanDoublePinchPayload: Sendable {
    let commandID: UUID
    let source: String
    let sentAt: Double

    var dictionary: [String: Any] {
        [
            "gesture": "doublePinch",
            "commandID": commandID.uuidString,
            "source": source,
            "sentAt": sentAt
        ]
    }
}

@Observable
final class WatchSessionDelegate: NSObject, WCSessionDelegate, @unchecked Sendable {
    var isReachable = false
    var deliveryStatus = "Ready"

    nonisolated func session(_ session: WCSession,
                             activationDidCompleteWith activationState: WCSessionActivationState,
                             error: Error?) {
        if error == nil {
            let isReachable = session.isReachable
            Task { @MainActor in
                self.updateReachability(isReachable)
            }
        }
    }

    // `WCSessionDelegate` declares these as required in the Swift import
    // even though the headers mark them `__WATCHOS_UNAVAILABLE`. Empty
    // stubs satisfy the conformance for any iOS slice (e.g. Designed
    // for iPad) that ever picks up this file. Compiling them under
    // watchOS would fail with "marked unavailable", so the iOS guard.
    #if os(iOS)
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) {}
    #endif

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let isReachable = session.isReachable
        Task { @MainActor in
            self.updateReachability(isReachable)
        }
    }

    @MainActor
    private func updateReachability(_ isReachable: Bool) {
        self.isReachable = isReachable
    }

    func sendDoublePinch(source: String) {
        let session = WCSession.default
        let payload = WingmanDoublePinchPayload(
            commandID: UUID(),
            source: source,
            sentAt: Date().timeIntervalSince1970
        )
        let dictionary = payload.dictionary

        guard session.activationState == .activated else {
            deliveryStatus = "Copilot unavailable"
            return
        }

        // `isCompanionAppInstalled` only exists on watchOS — the
        // counterpart iPhone always has the Watch app considered
        // "installed" from its perspective.
        #if os(watchOS)
        guard session.isCompanionAppInstalled else {
            deliveryStatus = "Install Copilot first"
            return
        }
        #endif

        if session.isReachable {
            deliveryStatus = "Sending…"
            session.sendMessage(dictionary, replyHandler: { [weak self] reply in
                let accepted = reply["status"] as? String == "accepted"
                Task { @MainActor in
                    self?.deliveryStatus = accepted ? "Delivered" : "Rejected"
                }
            }, errorHandler: { [weak self] _ in
                // Terminal commands are deliberately never queued: a delayed
                // Enter after reconnection could submit unrelated shell input.
                Task { @MainActor in self?.deliveryStatus = "Not delivered" }
            })
        } else {
            deliveryStatus = "Copilot unavailable"
        }
    }
}

@main
struct WingmanApp: App {
    @State private var sessionDelegate = WatchSessionDelegate()

    var body: some Scene {
        WindowGroup {
            ContentView(sessionDelegate: sessionDelegate)
        }
    }

    init() {
        let delegate = WatchSessionDelegate()
        _sessionDelegate = State(initialValue: delegate)

        // Demo mode: skip activating the live WatchConnectivity session
        // so the app renders fixture content with no real peer. Guarded
        // so a normal launch (no arg) activates the session as before.
        let isDemoMode = UserDefaults.standard.bool(forKey: "demoMode")
        if !isDemoMode, WCSession.isSupported() {
            WCSession.default.delegate = delegate
            WCSession.default.activate()
        }
    }
}
