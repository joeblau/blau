#if os(macOS)
import SwiftUI
import AppKit
import CryptoKit

/// Pilot's peer-to-peer secure messaging screen (issue #51, Phase 4).
///
/// The macOS counterpart of Copilot's `SecureMessagingView`: Pilot is the
/// **responder**. The user pastes the peer's pinned static public key (the
/// initiator's) plus the shared pairing token, then Connect: the
/// ``SecureChannelResponder`` walks signaling -> hole-punch -> Noise IK
/// handshake (authenticating the initiator against the pinned key) -> connected,
/// and exposes a live status, the decrypted message log, and send paths for
/// reliable text and a best-effort test blob.
///
/// Reached from the shared Identity & Keys section in `SettingsView`
/// (Pilot's Settings window, ⌘,).
struct PilotSecureMessagingView: View {
    @AppStorage("p2p.peerPublicKey") private var peerKeyInput = ""
    @AppStorage("p2p.token") private var tokenInput = ""
    @AppStorage("p2p.rendezvousURL") private var rendezvousURL = "https://rendezvous.blau.app"

    @State private var transport: SecureChannelResponder?
    @State private var outgoing = ""
    @State private var errorMessage: String?

    private var myPublicKey: String { DeviceIdentity.publicKeyBase64() ?? "—" }

    var body: some View {
        Form {
            statusSection
            identitySection
            pairingSection
            if let transport, transport.state.isConnected {
                messagingSection(transport)
            }
            if let transport {
                logSection(transport)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Secure Messaging")
        .frame(minWidth: 480, minHeight: 560)
        .alert("Connection error", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: - Sections

    private var statusSection: some View {
        Section("Status") {
            LabeledContent("Connection") {
                HStack(spacing: 6) {
                    Circle().fill(statusColor).frame(width: 8, height: 8)
                    Text(statusText)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var identitySection: some View {
        Section {
            LabeledContent("This device") {
                Text(myPublicKey)
                    .font(.system(.footnote, design: .monospaced))
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(myPublicKey, forType: .string)
            } label: {
                Label("Copy my key", systemImage: "key")
            }
        } header: {
            Text("My public key")
        } footer: {
            Text("Send this to your peer; they paste it as the peer key on their device.")
        }
    }

    private var pairingSection: some View {
        Section {
            TextField("Peer public key (base64)", text: $peerKeyInput, axis: .vertical)
                .font(.system(.footnote, design: .monospaced))
                .autocorrectionDisabled()
                .lineLimit(1...3)
            TextField("Pairing token", text: $tokenInput)
                .autocorrectionDisabled()
            TextField("Rendezvous URL", text: $rendezvousURL)
                .autocorrectionDisabled()

            if let transport, !transport.state.isFailed, transport.state != .signaling {
                Button("Disconnect", role: .destructive) {
                    transport.disconnect()
                    self.transport = nil
                }
            } else {
                Button("Connect") { connect() }
                    .disabled(!canConnect)
            }
        } header: {
            Text("Peer")
        } footer: {
            Text("The pairing token must match on both devices. The peer key is pinned and authenticated by the handshake.")
        }
    }

    private func messagingSection(_ transport: SecureChannelResponder) -> some View {
        Section("Send") {
            HStack {
                TextField("Message", text: $outgoing)
                    .onSubmit(send)
                Button("Send", action: send)
                    .disabled(outgoing.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Button {
                transport.sendTestBlob()
            } label: {
                Label("Send test blob (best-effort)", systemImage: "shippingbox")
            }
        }
    }

    private func logSection(_ transport: SecureChannelResponder) -> some View {
        Section("Session log") {
            if transport.log.isEmpty {
                Text("No activity yet.").foregroundStyle(.secondary)
            } else {
                ForEach(transport.log.reversed()) { entry in
                    Text(entry.text)
                        .font(.system(.footnote, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    // MARK: - Actions

    private var canConnect: Bool {
        DeviceIdentity.parsePeerPublicKey(peerKeyInput) != nil
            && !tokenInput.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func connect() {
        guard let peerKey = DeviceIdentity.parsePeerPublicKey(peerKeyInput) else {
            errorMessage = "Peer public key is not a valid base64 X25519 key."
            return
        }
        let token = tokenInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            errorMessage = "Enter a pairing token."
            return
        }
        do {
            let identity = try DeviceIdentity.loadOrCreate()
            let client = SignalingClient(baseURLString: rendezvousURL)
            let t = SecureChannelResponder(
                signaling: client,
                token: token,
                staticKey: identity,
                peerStatic: peerKey
            )
            transport = t
            t.connect()
        } catch {
            errorMessage = "Could not load device identity: \(error.localizedDescription)"
        }
    }

    private func send() {
        let text = outgoing.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        transport?.sendText(text)
        outgoing = ""
    }

    // MARK: - Status presentation

    private var statusText: String {
        switch transport?.state {
        case .none: return "Idle"
        case .signaling: return "Signaling…"
        case .holePunching: return "Hole punching…"
        case .handshake: return "Handshaking…"
        case .connected: return "Connected"
        case .failed(let reason): return "Failed: \(reason)"
        }
    }

    private var statusColor: Color {
        switch transport?.state {
        case .connected: return .green
        case .failed: return .red
        case .none: return .gray
        default: return .orange
        }
    }
}
#endif
