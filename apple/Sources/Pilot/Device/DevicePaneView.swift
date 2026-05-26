import AVFoundation
import AppKit
import SwiftUI

struct DevicePaneView: View {
    let paneID: UUID
    let isActive: Bool
    let isSelected: Bool

    @State private var showCopiedToast = false
    @State private var toastDismissWorkItem: DispatchWorkItem?

    var body: some View {
        let session = DeviceCaptureRegistry.shared.session(for: paneID)
        ZStack {
            DeviceCaptureContainerView(session: session)
            DeviceStatusOverlay(session: session)
                .opacity(session.status == .streaming ? 0 : 1)
                .allowsHitTesting(session.status != .streaming)
                .animation(.easeInOut(duration: 0.2), value: session.status)

            if showCopiedToast {
                CopiedToast()
                    .transition(.opacity.combined(with: .scale(scale: 0.85)))
                    .allowsHitTesting(false)
                    .zIndex(20)
            }
        }
        .background(Color.black)
        .onChange(of: session.clipboardCopyCount) { _, _ in
            flashCopiedToast()
        }
    }

    private func flashCopiedToast() {
        toastDismissWorkItem?.cancel()
        withAnimation(.snappy(duration: 0.18)) {
            showCopiedToast = true
        }
        let work = DispatchWorkItem {
            withAnimation(.snappy(duration: 0.3)) {
                showCopiedToast = false
            }
        }
        toastDismissWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }
}

private struct CopiedToast: View {
    var body: some View {
        Label("Screenshot Copied", systemImage: "checkmark.circle.fill")
            .font(.headline)
            .foregroundStyle(.primary)
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
                    icon: "iphone.gen3",
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
                    detail: message
                )
            }
        }
    }

    private func statusBlock(icon: String, title: String, detail: String?) -> some View {
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
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.85))
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
        host.backgroundColor = NSColor.black.cgColor
        layer = host

        previewLayer.session = captureSession.session
        previewLayer.videoGravity = .resizeAspect
        previewLayer.backgroundColor = NSColor.black.cgColor
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
