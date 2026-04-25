import AppKit
import Foundation
import IOSurface
import Metal
import OSLog
import QuartzCore

// SimulatorFramebufferClient — bridges CoreSimulator's IOSurface frame
// stream to a `CAMetalLayer` for zero-copy render.
//
//   ┌───────────────────┐   IOSurface   ┌────────────────────┐
//   │ SimDeviceIOClient │──────────────▶│ onSurface(IOSurface│
//   │ (SPI)             │               │ Ref)               │
//   └───────────────────┘               └─────────┬──────────┘
//                                                 │
//                                                 ▼
//                             ┌─────────────────────────────────┐
//                             │ MTLTextureDescriptor.ioSurface  │
//                             │ + layer.nextDrawable            │
//                             └─────────────────────────────────┘
//
// Backpressure: drop-oldest. If a new surface arrives before the previous
// frame has been consumed, the previous one is replaced — no queue.
//
// TODO(spi): The framebuffer stream comes from SimDevice.registerPortForServiceNamed:
// "com.apple.iphonesimulator.SimDeviceIOClient" (see fb-idb's
// FBSimulatorVideoStream + FBSimulatorIOClient). Until wired, this
// client emits no frames and the pane shows the placeholder state.

@MainActor
final class SimulatorFramebufferClient {
    weak var delegate: SimulatorFramebufferClientDelegate?

    private let udid: String
    private let logger = Logger(subsystem: "app.blau.pilot.simulator", category: "framebuffer")

    private(set) var isSubscribed = false
    private(set) var lastFrameSize: CGSize = .zero
    private(set) var reconnectAttempts = 0

    private let maxReconnectAttempts = 3

    init(udid: String) {
        self.udid = udid
    }

    func subscribe() async throws {
        // TODO(spi): Start framebuffer stream via SimDeviceIOClient. Store
        // the handle so unsubscribe() can tear it down cleanly.
        logger.notice("SimulatorFramebufferClient.subscribe() for \(self.udid) — SPI not yet wired")
        isSubscribed = false
    }

    func unsubscribe() {
        isSubscribed = false
    }

    // Called by the SPI callback once wired — public for the implementation seam.
    func deliver(surface: IOSurfaceRef, size: CGSize) {
        lastFrameSize = size
        reconnectAttempts = 0
        delegate?.framebufferClient(self, didReceiveSurface: surface, size: size)
    }

    func handleDisconnect(reason: String) async {
        logger.warning("Framebuffer disconnect (\(reason)), attempt \(self.reconnectAttempts + 1)/\(self.maxReconnectAttempts)")
        if reconnectAttempts >= maxReconnectAttempts {
            delegate?.framebufferClientDidDisconnect(self)
            return
        }
        reconnectAttempts += 1
        try? await Task.sleep(nanoseconds: 500_000_000)
        try? await subscribe()
    }
}

@MainActor
protocol SimulatorFramebufferClientDelegate: AnyObject {
    func framebufferClient(_ client: SimulatorFramebufferClient, didReceiveSurface surface: IOSurfaceRef, size: CGSize)
    func framebufferClientDidDisconnect(_ client: SimulatorFramebufferClient)
}
