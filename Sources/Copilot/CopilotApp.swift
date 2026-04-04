import SwiftUI
import AVFAudio
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
    var syncService: PeerSyncService?

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
        copilotConnectivityLogger.info("Received double pinch over \(transport, privacy: .public). Forwarding as Enter to Pilot.")
        Task { @MainActor in
            PhoneSessionDelegate.playDoublePinchHaptic()
            syncService?.send(.terminalInput(.enter))
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

@Observable
@MainActor
final class HeadphoneRouteMonitor {
    var audioOutput: AudioOutputDevice?

    private let session = AVAudioSession.sharedInstance()
    private var routeChangeObserver: NSObjectProtocol?

    func start() {
        refresh()
        guard routeChangeObserver == nil else { return }
        routeChangeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: session,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }
    }

    private func refresh() {
        audioOutput = Self.detectAudioOutput(in: session.currentRoute.outputs)
    }

    private static func detectAudioOutput(
        in outputs: [AVAudioSessionPortDescription]
    ) -> AudioOutputDevice? {
        for output in outputs {
            if let device = classifyOutput(output) {
                return device
            }
        }
        return nil
    }

    private static func classifyOutput(_ output: AVAudioSessionPortDescription) -> AudioOutputDevice? {
        let kind: ConnectedDeviceKind
        switch output.portType {
        case .headphones:
            kind = ConnectedDeviceKind.classify(name: output.portName, defaultKind: .headphonesWired)
        case .bluetoothA2DP, .bluetoothLE, .bluetoothHFP:
            kind = ConnectedDeviceKind.classify(name: output.portName, defaultKind: .headphonesBluetooth)
        default:
            return nil
        }

        let trimmedName = output.portName.trimmingCharacters(in: .whitespacesAndNewlines)
        return AudioOutputDevice(
            kind: kind,
            name: trimmedName.isEmpty ? kind.displayName : trimmedName
        )
    }
}

@main
struct CopilotApp: App {
    @State private var syncService = PeerSyncService(
        role: .browser,
        displayName: UIDevice.current.name
    )
    @State private var phoneSessionDelegate = PhoneSessionDelegate()
    @State private var headphoneRouteMonitor = HeadphoneRouteMonitor()

    var body: some Scene {
        WindowGroup {
            ContentView(
                syncService: syncService,
                watchDelegate: phoneSessionDelegate,
                headphoneRouteMonitor: headphoneRouteMonitor
            )
            .task {
                phoneSessionDelegate.syncService = syncService
                headphoneRouteMonitor.start()
            }
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
