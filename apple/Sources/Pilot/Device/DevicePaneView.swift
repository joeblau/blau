import AVFoundation
import AppKit
import SwiftUI

struct DevicePaneView: View {
    let paneID: UUID
    let isActive: Bool
    let isSelected: Bool

    @State private var toast: DeviceToast?
    @State private var toastDismissWorkItem: DispatchWorkItem?

    var body: some View {
        let session = DeviceCaptureRegistry.shared.session(for: paneID)
        ZStack {
            PreviewCanvasBackground()
            DeviceCaptureContainerView(session: session)
            DeviceStatusOverlay(session: session)
                .opacity(session.status == .streaming ? 0 : 1)
                .allowsHitTesting(session.status != .streaming)
                .animation(.easeInOut(duration: 0.2), value: session.status)

            if let toast {
                DeviceToastView(toast: toast)
                    .transition(.opacity.combined(with: .scale(scale: 0.85)))
                    .allowsHitTesting(false)
                    .zIndex(20)
            }
        }
        .onChange(of: session.clipboardCopyCount) { _, _ in
            flash(DeviceToast(text: "Screenshot Copied", systemImage: "checkmark.circle.fill"))
        }
        .onChange(of: session.recordingWithoutAudioCount) { _, _ in
            // Held a touch longer than the copy toast since it's a heads-up, not
            // a confirmation.
            flash(
                DeviceToast(text: "Recording without audio", systemImage: "mic.slash.fill", tint: .orange),
                duration: 2.5
            )
        }
    }

    private func flash(_ content: DeviceToast, duration: TimeInterval = 1.0) {
        toastDismissWorkItem?.cancel()
        withAnimation(.snappy(duration: 0.18)) {
            toast = content
        }
        let work = DispatchWorkItem {
            withAnimation(.snappy(duration: 0.3)) {
                toast = nil
            }
        }
        toastDismissWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }
}

private struct DeviceToast {
    let text: String
    let systemImage: String
    var tint: Color = .primary
}

private struct DeviceToastView: View {
    let toast: DeviceToast

    var body: some View {
        Label(toast.text, systemImage: toast.systemImage)
            .font(.headline)
            .foregroundStyle(toast.tint)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.separator.opacity(0.4), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
    }
}

private struct DeviceStatusOverlay: View {
    let session: DeviceCaptureSession

    var body: some View {
        Group {
            switch session.status {
            case .waiting:
                statusBlock(
                    icon: "apps.iphone",
                    title: "Connect an iPhone",
                    detail: "Plug in an iPhone via USB and trust this Mac. The screen will mirror here, like QuickTime."
                )
            case .connecting:
                statusBlock(
                    icon: "arrow.triangle.2.circlepath",
                    title: "Connecting…",
                    detail: session.deviceName
                )
            case .streaming:
                Color.clear
            case .failed(let message):
                statusBlock(
                    icon: "exclamationmark.triangle",
                    title: "Capture failed",
                    detail: message,
                    // Self-heal polls in the background, but give the user an
                    // immediate way out too — start() re-requests access and
                    // re-attaches without waiting for the next poll tick.
                    retry: { session.start() }
                )
            }
        }
    }

    private func statusBlock(
        icon: String,
        title: String,
        detail: String?,
        retry: (() -> Void)? = nil
    ) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .scaledFont(size: 36)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            if let retry {
                Button("Retry", action: retry)
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 8)
            }
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(PreviewCanvasBackground())
    }
}

private struct DeviceCaptureContainerView: NSViewRepresentable {
    let session: DeviceCaptureSession

    func makeNSView(context: Context) -> DeviceCaptureHostView {
        DeviceCaptureHostView(session: session)
    }

    func updateNSView(_ nsView: DeviceCaptureHostView, context: Context) {}
}

final class DeviceCaptureHostView: NSView {
    private let captureSession: DeviceCaptureSession
    private let previewLayer = AVCaptureVideoPreviewLayer()

    init(session: DeviceCaptureSession) {
        self.captureSession = session
        super.init(frame: .zero)
        wantsLayer = true
        let host = CALayer()
        host.backgroundColor = NSColor.clear.cgColor
        layer = host

        previewLayer.session = captureSession.session
        previewLayer.videoGravity = .resizeAspect
        previewLayer.backgroundColor = NSColor.clear.cgColor
        host.addSublayer(previewLayer)
    }

    @MainActor required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        previewLayer.frame = bounds
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            captureSession.start()
        }
        // Don't tear down on window detach — the SwiftUI host view may be
        // briefly removed when the workspace re-renders. The registry owns
        // teardown when the pane itself is removed.
    }
}
