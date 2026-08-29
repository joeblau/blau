import AppKit
import SwiftUI
// RoyalVNCKit predates Swift 6 strict concurrency; `@preconcurrency` keeps its
// non-Sendable types (VNCConnection/VNCFramebuffer/…) from tripping the actor
// checks when we bridge its delegate callbacks back onto the main actor.
@preconcurrency import RoyalVNCKit

/// Hosts RoyalVNCKit's ready-made macOS framebuffer view (`VNCCAFramebufferView`,
/// which renders the remote screen and forwards keyboard/mouse) for a session
/// owned by `RemoteDesktopSessionManager`.
///
/// This view owns *no* connection. Mounting it builds a framebuffer view over
/// the session's existing framebuffer and unmounting tears only that view down,
/// so switching tabs costs a view rebuild rather than a reconnect and a second
/// trip through authentication.
struct RemoteDesktopViewer: NSViewRepresentable {
    let session: RemoteDesktopSession
    /// Read from the session in the caller's `body` so SwiftUI re-runs
    /// `updateNSView` when the framebuffer is created, resized, or dropped.
    let framebufferGeneration: Int

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        context.coordinator.attach(to: container, session: session)
        context.coordinator.sync(generation: framebufferGeneration)
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.sync(generation: framebufferGeneration)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        // Detach only. The connection belongs to the session manager and must
        // survive this view so tabbing back does not re-handshake.
        coordinator.detach()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator {
        private weak var container: NSView?
        private var session: RemoteDesktopSession?
        private var framebufferView: VNCCAFramebufferView?
        private var installedGeneration: Int?

        func attach(to container: NSView, session: RemoteDesktopSession) {
            self.container = container
            self.session = session
        }

        /// Rebuild the framebuffer view when the session's framebuffer changes
        /// identity, and drop it when the session has none.
        func sync(generation: Int) {
            guard let session, let container else { return }

            guard let framebuffer = session.framebuffer,
                  let connection = session.activeConnection,
                  let connectionDelegate = session.connectionDelegate else {
                removeFramebufferView()
                return
            }

            guard framebufferView == nil || installedGeneration != generation else { return }

            removeFramebufferView()

            let view = VNCCAFramebufferView(
                frame: container.bounds,
                framebuffer: framebuffer,
                connection: connection,
                connectionDelegate: connectionDelegate
            )
            view.autoresizingMask = [.width, .height]
            container.addSubview(view)
            framebufferView = view
            installedGeneration = generation
            // Take first responder so keyboard input is forwarded immediately.
            container.window?.makeFirstResponder(view)
        }

        func detach() {
            removeFramebufferView()
            session = nil
            container = nil
        }

        private func removeFramebufferView() {
            guard let framebufferView else { return }
            // `VNCCAFramebufferView.init` installs itself as the connection's
            // delegate and forwards through a weak reference. Hand the session's
            // relay back *before* this view dies, or the connection's weak
            // delegate goes nil and every status callback stops arriving.
            session?.restoreConnectionDelegate()
            framebufferView.removeFromSuperview()
            self.framebufferView = nil
            installedGeneration = nil
        }
    }
}
