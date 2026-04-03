import SwiftUI
import WatchConnectivity
import UserNotifications
import OSLog
import UIKit

private let copilotConnectivityLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "app.blau.copilot",
    category: "WatchConnectivity"
)

private enum WingmanGesturePayload {
    static let gestureKey = "gesture"
    static let doublePinch = "doublePinch"

    static func isDoublePinch(_ payload: [String: Any]) -> Bool {
        payload[gestureKey] as? String == doublePinch
    }
}

@Observable
final class PhoneSessionDelegate: NSObject, WCSessionDelegate, UNUserNotificationCenterDelegate, @unchecked Sendable {
    var isWatchReachable = false

    func session(_ session: WCSession,
                 activationDidCompleteWith activationState: WCSessionActivationState,
                 error: Error?) {
        if let error {
            copilotConnectivityLogger.error("WCSession activation failed: \(error.localizedDescription, privacy: .public)")
        } else {
            let isWatchReachable = session.isReachable
            copilotConnectivityLogger.info(
                """
                WCSession activated. state=\(String(describing: activationState), privacy: .public) \
                reachable=\(isWatchReachable, privacy: .public)
                """
            )
            Task { @MainActor in
                self.updateWatchReachability(isWatchReachable)
            }
        }
    }

    func sessionDidBecomeInactive(_ session: WCSession) {
        copilotConnectivityLogger.info("WCSession became inactive.")
    }

    func sessionDidDeactivate(_ session: WCSession) {
        copilotConnectivityLogger.info("WCSession deactivated. Reactivating default session.")
        WCSession.default.activate()
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        handleWingmanPayload(message, transport: "sendMessage")
    }

    func session(_ session: WCSession,
                 didReceiveMessage message: [String: Any],
                 replyHandler: @escaping ([String: Any]) -> Void) {
        handleWingmanPayload(message, transport: "sendMessageWithReply")
        replyHandler([
            "status": "received",
            "receivedAt": Date().timeIntervalSince1970
        ])
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        handleWingmanPayload(userInfo, transport: "transferUserInfo")
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        handleWingmanPayload(applicationContext, transport: "applicationContext")
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let isWatchReachable = session.isReachable
        copilotConnectivityLogger.info("Reachability changed. reachable=\(isWatchReachable, privacy: .public)")
        Task { @MainActor in
            self.updateWatchReachability(isWatchReachable)
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        copilotConnectivityLogger.info("Presenting Wingman notification while app is foregrounded.")
        completionHandler([.banner, .list, .sound])
    }

    private func handleWingmanPayload(_ payload: [String: Any], transport: String) {
        guard WingmanGesturePayload.isDoublePinch(payload) else { return }
        let source = payload["source"] as? String ?? "unknown"
        let sentAt = payload["sentAt"] as? Double ?? 0
        copilotConnectivityLogger.info(
            """
            Received double pinch over \(transport, privacy: .public). source=\(source, privacy: .public) \
            sentAt=\(sentAt, privacy: .public)
            """
        )
        Task { @MainActor in
            PhoneSessionDelegate.playDoublePinchHaptic()
        }

        let content = UNMutableNotificationContent()
        content.title = "Wingman"
        content.body = "Double Pinch"
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                copilotConnectivityLogger.error("Failed to enqueue Wingman notification: \(error.localizedDescription, privacy: .public)")
            } else {
                copilotConnectivityLogger.info("Wingman notification enqueued successfully.")
            }
        }
    }

    @MainActor
    private static func playDoublePinchHaptic() {
        copilotConnectivityLogger.info("Playing double pinch haptic feedback.")
        let feedback = UINotificationFeedbackGenerator()
        feedback.prepare()
        feedback.notificationOccurred(.success)
    }

    @MainActor
    private func updateWatchReachability(_ isReachable: Bool) {
        self.isWatchReachable = isReachable
    }
}

@main
struct CopilotApp: App {
    @State private var syncService = PeerSyncService(
        role: .browser,
        displayName: UIDevice.current.name
    )
    @State private var phoneSessionDelegate = PhoneSessionDelegate()

    var body: some Scene {
        WindowGroup {
            ContentView(syncService: syncService, watchDelegate: phoneSessionDelegate)
        }
    }

    init() {
        let delegate = PhoneSessionDelegate()
        _phoneSessionDelegate = State(initialValue: delegate)

        let notificationCenter = UNUserNotificationCenter.current()
        notificationCenter.delegate = delegate

        if WCSession.isSupported() {
            copilotConnectivityLogger.info("Activating default WCSession for Copilot.")
            WCSession.default.delegate = delegate
            WCSession.default.activate()
        } else {
            copilotConnectivityLogger.error("WCSession is not supported on this device.")
        }

        notificationCenter.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if let error {
                copilotConnectivityLogger.error("Notification authorization failed: \(error.localizedDescription, privacy: .public)")
            } else {
                copilotConnectivityLogger.info("Notification authorization granted=\(granted, privacy: .public)")
            }
        }
    }
}
