import SwiftUI
import WatchConnectivity
import OSLog

private let wingmanAppLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "app.blau.wingman",
    category: "WatchSession"
)

final class WatchSessionDelegate: NSObject, WCSessionDelegate {
    func session(_ session: WCSession,
                 activationDidCompleteWith activationState: WCSessionActivationState,
                 error: Error?) {
        if let error {
            wingmanAppLogger.error("WCSession activation failed: \(error.localizedDescription, privacy: .public)")
        } else {
            wingmanAppLogger.info(
                """
                WCSession activated. state=\(String(describing: activationState), privacy: .public) \
                reachable=\(session.isReachable, privacy: .public) \
                companionInstalled=\(session.isCompanionAppInstalled, privacy: .public)
                """
            )
        }
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        wingmanAppLogger.info("Reachability changed. reachable=\(session.isReachable, privacy: .public)")
    }
}

@main
struct WingmanApp: App {
    @State private var sessionDelegate = WatchSessionDelegate()

    var body: some Scene {
        WindowGroup {
            ContentView()
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
