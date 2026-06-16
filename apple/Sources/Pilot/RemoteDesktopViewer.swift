import AppKit
import SwiftUI
// RoyalVNCKit predates Swift 6 strict concurrency; `@preconcurrency` keeps its
// non-Sendable types (VNCConnection/VNCFramebuffer/…) from tripping the actor
// checks when we bridge its delegate callbacks back onto the main actor.
@preconcurrency import RoyalVNCKit

/// Live status of a single embedded VNC session, observed by the SwiftUI pane.
enum RemoteConnectionStatus: Sendable, Equatable {
    case idle
    case connecting
    case connected
    case disconnected
    case failed(String)
}

/// Main-actor box the viewer publishes its connection status through, so the
/// SwiftUI pane can switch between the connect form, a spinner, and the live
/// framebuffer without the AppKit coordinator reaching into SwiftUI state.
@Observable
@MainActor
final class RemoteConnectionSession {
    var status: RemoteConnectionStatus = .idle
}

/// Embeds RoyalVNCKit's ready-made macOS framebuffer view (`VNCCAFramebufferView`,
/// which renders the remote screen and forwards keyboard/mouse) inside a tab.
/// The connection is opened in `makeNSView` and torn down in `dismantleNSView`.
struct RemoteDesktopViewer: NSViewRepresentable {
    let host: String
    let port: Int
    let username: String
    let password: String
    let session: RemoteConnectionSession

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        context.coordinator.connect(in: container,
                                    host: host,
                                    port: port,
                                    username: username,
                                    password: password)
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.disconnect()
    }

    func makeCoordinator() -> Coordinator { Coordinator(session: session) }

    /// Owns the `VNCConnection` and bridges its (off-main) delegate callbacks
    /// onto the main actor. `@unchecked Sendable` so it can be captured into the
    /// `Task { @MainActor in … }` hops; all UI work happens on the main actor.
    final class Coordinator: NSObject, VNCConnectionDelegate, @unchecked Sendable {
        private let session: RemoteConnectionSession
        private weak var container: NSView?
        private var connection: VNCConnection?
        private var framebufferView: VNCCAFramebufferView?
        private var username = ""
        private var password = ""

        init(session: RemoteConnectionSession) {
            self.session = session
        }

        @MainActor
        func connect(in container: NSView, host: String, port: Int, username: String, password: String) {
            self.container = container
            self.username = username
            self.password = password

            let settings = VNCConnection.Settings(
                isDebugLoggingEnabled: false,
                hostname: host,
                port: UInt16(clamping: port),
                isShared: true,
                isScalingEnabled: true,
                useDisplayLink: true,
                inputMode: .forwardKeyboardShortcutsEvenIfInUseLocally,
                isClipboardRedirectionEnabled: true,
                colorDepth: .depth24Bit,
                frameEncodings: .default
            )
            let connection = VNCConnection(settings: settings)
            connection.delegate = self
            self.connection = connection
            session.status = .connecting
            connection.connect()
        }

        func disconnect() {
            connection?.disconnect()
            connection = nil
            let view = framebufferView
            framebufferView = nil
            Task { @MainActor in view?.removeFromSuperview() }
        }

        // MARK: - VNCConnectionDelegate

        func connection(_ connection: VNCConnection,
                        stateDidChange connectionState: VNCConnection.ConnectionState) {
            let status: RemoteConnectionStatus
            switch connectionState.status {
            case .connecting:
                status = .connecting
            case .connected:
                status = .connected
            case .disconnecting:
                status = .connecting
            case .disconnected:
                if let error = connectionState.error {
                    status = .failed(error.localizedDescription)
                } else {
                    status = .disconnected
                }
            }
            let session = self.session
            Task { @MainActor in session.status = status }
        }

        func connection(_ connection: VNCConnection,
                        credentialFor authenticationType: VNCAuthenticationType,
                        completion: @escaping (VNCCredential?) -> Void) {
            let credential: VNCCredential?
            if authenticationType.requiresUsername {
                credential = VNCUsernamePasswordCredential(username: username, password: password)
            } else if authenticationType.requiresPassword {
                credential = VNCPasswordCredential(password: password)
            } else {
                credential = nil
            }
            completion(credential)
        }

        func connection(_ connection: VNCConnection, didCreateFramebuffer framebuffer: VNCFramebuffer) {
            Task { @MainActor in self.installFramebuffer(framebuffer, connection: connection) }
        }

        func connection(_ connection: VNCConnection, didResizeFramebuffer framebuffer: VNCFramebuffer) {}

        func connection(_ connection: VNCConnection,
                        didUpdateFramebuffer framebuffer: VNCFramebuffer,
                        x: UInt16, y: UInt16, width: UInt16, height: UInt16) {}

        func connection(_ connection: VNCConnection, didUpdateCursor cursor: VNCCursor) {}

        @MainActor
        private func installFramebuffer(_ framebuffer: VNCFramebuffer, connection: VNCConnection) {
            guard let container else { return }
            framebufferView?.removeFromSuperview()
            let view = VNCCAFramebufferView(
                frame: container.bounds,
                framebuffer: framebuffer,
                connection: connection,
                connectionDelegate: self
            )
            view.autoresizingMask = [.width, .height]
            container.addSubview(view)
            framebufferView = view
            // Take first responder so keyboard input is forwarded immediately.
            container.window?.makeFirstResponder(view)
        }
    }
}
