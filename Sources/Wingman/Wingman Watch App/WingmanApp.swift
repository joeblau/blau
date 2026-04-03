import SwiftUI
import WatchConnectivity
import OSLog

private let wingmanAppLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "app.blau.wingman",
    category: "WatchSession"
)

private let wingmanConnectivityLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "app.blau.wingman",
    category: "WatchConnectivity"
)

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
        if let error {
            wingmanAppLogger.error("WCSession activation failed: \(error.localizedDescription, privacy: .public)")
        } else {
            let isReachable = session.isReachable
            wingmanAppLogger.info(
                """
                WCSession activated. state=\(String(describing: activationState), privacy: .public) \
                reachable=\(isReachable, privacy: .public) \
                companionInstalled=\(session.isCompanionAppInstalled, privacy: .public)
                """
            )
            Task { @MainActor in
                self.updateReachability(isReachable)
            }
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let isReachable = session.isReachable
        wingmanAppLogger.info("Reachability changed. reachable=\(isReachable, privacy: .public)")
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

        wingmanConnectivityLogger.info("Double pinch action fired via \(source, privacy: .public)")
        wingmanConnectivityLogger.info(
            """
            Sending double pinch source=\(source, privacy: .public) activation=\(String(describing: session.activationState), privacy: .public) \
            reachable=\(session.isReachable, privacy: .public) \
            companionInstalled=\(session.isCompanionAppInstalled, privacy: .public)
            """
        )

        guard session.activationState == .activated else {
            wingmanConnectivityLogger.error("WCSession not activated. Aborting double pinch send.")
            return
        }

        guard session.isCompanionAppInstalled else {
            wingmanConnectivityLogger.error("Companion app is not installed on the paired phone.")
            return
        }

        if session.isReachable {
            session.sendMessage(dictionary, replyHandler: { reply in
                let replyDescription = String(describing: reply)
                wingmanConnectivityLogger.info(
                    "sendMessage reply received: \(replyDescription, privacy: .public)"
                )
            }, errorHandler: { error in
                let message = error.localizedDescription
                let fallbackSession = WCSession.default
                fallbackSession.transferUserInfo(dictionary)
                wingmanConnectivityLogger.error(
                    "sendMessage failed with error: \(message, privacy: .public). Falling back to transferUserInfo."
                )
                wingmanConnectivityLogger.info(
                    "Queued transferUserInfo fallback. outstandingTransfers=\(fallbackSession.outstandingUserInfoTransfers.count, privacy: .public)"
                )
            })
        } else {
            session.transferUserInfo(dictionary)
            wingmanConnectivityLogger.info(
                "Phone not reachable. Queued transferUserInfo. outstandingTransfers=\(session.outstandingUserInfoTransfers.count, privacy: .public)"
            )
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
            wingmanAppLogger.info("Activating default WCSession for Wingman.")
            WCSession.default.delegate = delegate
            WCSession.default.activate()
        } else {
            wingmanAppLogger.error("WCSession is not supported on this device.")
        }
    }
}
