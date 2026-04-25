import AppKit
import Metal
import MetalKit
import OSLog
import QuartzCore
import SwiftUI

// SimulatorPaneView — NSViewRepresentable hosting a CAMetalLayer that
// displays IOSurface frames from `SimulatorFramebufferClient`. Also
// routes `NSEvent`s through `SimulatorInputBridge`.
//
// While SPI is not yet wired, the pane shows a placeholder state
// explaining what's pending and surfaces the current `SimulatorError`
// if one was captured.

struct SimulatorPaneView: View {
    @Bindable var state: SimulatorState
    let isActive: Bool
    let isSelected: Bool

    var body: some View {
        if state.needsProvisioning {
            SimulatorProvisioningView(state: state)
        } else {
            ZStack {
                SimulatorMetalContainerView(
                    udid: state.deviceUDID,
                    isActive: isActive,
                    isSelected: isSelected,
                    state: state
                )
                SimulatorStatusOverlay(state: state)
            }
        }
    }
}

private struct SimulatorStatusOverlay: View {
    @Bindable var state: SimulatorState

    var body: some View {
        VStack(spacing: 12) {
            switch state.connectionStatus {
            case .disconnected, .connecting:
                statusBlock(icon: "iphone", title: "Preparing simulator…", detail: state.displayName)
            case .booting:
                statusBlock(icon: "power", title: "Booting \(state.displayName)…", detail: "First boot can take 15-30 seconds.")
            case .streaming:
                // Booted, but the framebuffer SPI is still TODO — show a friendly
                // placeholder instead of an empty black Metal layer.
                statusBlock(
                    icon: "checkmark.circle",
                    title: "\(state.displayName) is booted",
                    detail: "Pane stream is pending the SimulatorKit framebuffer SPI port. Use Apple's Simulator window to see the screen for now; logs and lifecycle work."
                )
            case .reconnecting:
                statusBlock(icon: "arrow.clockwise", title: "Reconnecting…", detail: nil)
            case .failed(let msg):
                statusBlock(icon: "exclamationmark.triangle", title: "Simulator error", detail: msg)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.4))
    }

    private func statusBlock(icon: String, title: String, detail: String?) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
            if let detail {
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
        }
        .foregroundStyle(.white)
    }
}

// MARK: - Provisioning placeholder (before a device is chosen)

private struct SimulatorProvisioningView: View {
    @Bindable var state: SimulatorState
    @State private var pickerPresented: Bool = true

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            VStack(spacing: 12) {
                Image(systemName: "iphone")
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)
                Text("No simulator selected")
                    .font(.headline)
                Text("Choose a device type and iOS runtime to begin.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button("Choose Device…") {
                    pickerPresented = true
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
        }
        .sheet(isPresented: $pickerPresented) {
            SimulatorDevicePicker(state: state, isPresented: $pickerPresented)
        }
    }
}

// MARK: - Metal-backed NSViewRepresentable

private struct SimulatorMetalContainerView: NSViewRepresentable {
    let udid: String
    let isActive: Bool
    let isSelected: Bool
    let state: SimulatorState

    func makeNSView(context: Context) -> SimulatorMetalHostView {
        let view = SimulatorMetalHostView(udid: udid, state: state)
        view.isActive = isActive
        return view
    }

    func updateNSView(_ nsView: SimulatorMetalHostView, context: Context) {
        nsView.isActive = isActive
        nsView.isPaneSelected = isSelected
    }
}

final class SimulatorMetalHostView: NSView, SimulatorFramebufferClientDelegate {
    private let logger = Logger(subsystem: "app.blau.pilot.simulator", category: "pane-view")
    private let metalLayer = CAMetalLayer()
    private let device: MTLDevice?
    private let udid: String
    private let state: SimulatorState
    private let inputBridge = SimulatorInputBridge()
    private var framebuffer: SimulatorFramebufferClient?
    private var pinchSeparation: Double = 100

    var isActive: Bool = false {
        didSet { updateSubscription() }
    }
    var isPaneSelected: Bool = false

    init(udid: String, state: SimulatorState) {
        self.udid = udid
        self.state = state
        self.device = MTLCreateSystemDefaultDevice()
        super.init(frame: .zero)
        wantsLayer = true
        metalLayer.device = device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = false
        metalLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
        layer = metalLayer
    }

    @MainActor required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { true }

    // MARK: - Lifecycle

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            Task { @MainActor in await bringUp() }
        } else {
            Task { @MainActor in await tearDown() }
        }
    }

    private func bringUp() async {
        state.connectionStatus = .booting
        do {
            try await SimulatorRuntime.shared.bootOffMainThread(udid: udid)
            // Framebuffer SPI is still TODO — the pane will show a placeholder
            // explaining that until SimulatorKit's IOSurface bridge is wired.
            state.connectionStatus = .streaming
            state.lastError = nil
        } catch let error as SimulatorError {
            state.connectionStatus = .failed(error.localizedDescription)
            state.lastError = error.localizedDescription
            logger.error("bringUp failed: \(error.localizedDescription)")
        } catch {
            state.connectionStatus = .failed(error.localizedDescription)
            state.lastError = error.localizedDescription
        }
    }

    private func tearDown() async {
        framebuffer?.unsubscribe()
        framebuffer = nil
        await SimulatorRuntime.shared.shutdownOffMainThread(udid: udid)
    }

    private func updateSubscription() {
        // If the pane goes inactive (focus-mode collapse), we keep the sim
        // running and just let CAMetalLayer short-circuit updates.
    }

    // MARK: - Events

    override func keyDown(with event: NSEvent) {
        forward(event: event)
    }

    override func keyUp(with event: NSEvent) {
        forward(event: event)
    }

    override func mouseDown(with event: NSEvent) {
        forward(event: event)
    }

    override func mouseDragged(with event: NSEvent) {
        forward(event: event)
    }

    override func mouseUp(with event: NSEvent) {
        forward(event: event)
    }

    override func scrollWheel(with event: NSEvent) {
        forward(event: event)
    }

    private func forward(event: NSEvent) {
        let payloads = inputBridge.translate(
            event: event,
            in: bounds,
            pinchSeparation: pinchSeparation
        )
        guard !payloads.isEmpty else { return }
        Task { @MainActor in
            guard let set = try? SimulatorRuntime.shared.sharedDeviceSet(),
                  let device = try? set.device(forUDID: udid)
            else { return }
            for payload in payloads {
                do {
                    try await device.sendHIDEvent(payload)
                } catch {
                    // Logged once; avoid drowning the system log.
                    logger.debug("HID send failed: \(error.localizedDescription)")
                    break
                }
            }
        }
    }

    // MARK: - Framebuffer delivery

    func framebufferClient(
        _ client: SimulatorFramebufferClient,
        didReceiveSurface surface: IOSurfaceRef,
        size: CGSize
    ) {
        // TODO(render): Bind `surface` as an MTLTexture via MTLTextureDescriptor
        // ioSurface init, then blit to metalLayer.nextDrawable. Zero-copy path.
    }

    func framebufferClientDidDisconnect(_ client: SimulatorFramebufferClient) {
        state.connectionStatus = .failed(SimulatorError.framebufferDisconnected.localizedDescription)
    }
}
