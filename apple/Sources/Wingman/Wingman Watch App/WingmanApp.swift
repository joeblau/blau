import SwiftUI
import WatchConnectivity

private struct WingmanDoublePinchPayload: Sendable {
    let source: String
    let sentAt: Double

    var dictionary: [String: Any] {
        [
            "gesture": "doublePinch",
            "source": source,
            "sentAt": sentAt
        ]
    }
}

@Observable
final class WatchSessionDelegate: NSObject, WCSessionDelegate, @unchecked Sendable {
    var isReachable = false

    func session(_ session: WCSession,
                 activationDidCompleteWith activationState: WCSessionActivationState,
                 error: Error?) {
        if error == nil {
            let isReachable = session.isReachable
            Task { @MainActor in
                self.updateReachability(isReachable)
            }
        }
    }

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
            source: source,
            sentAt: Date().timeIntervalSince1970
        )
        let dictionary = payload.dictionary

        guard session.activationState == .activated else {
            return
        }

        guard session.isCompanionAppInstalled else {
            return
        }

        if session.isReachable {
            session.sendMessage(dictionary, replyHandler: { _ in
            }, errorHandler: { _ in
                let fallbackSession = WCSession.default
                fallbackSession.transferUserInfo(dictionary)
            })
        } else {
            session.transferUserInfo(dictionary)
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
        if WCSession.isSupported() {
            WCSession.default.delegate = delegate
            WCSession.default.activate()
        }
    }
}
