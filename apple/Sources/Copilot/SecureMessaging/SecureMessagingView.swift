#if os(iOS)
import SwiftUI
import CryptoKit

/// Copilot's peer-to-peer secure messaging screen (issue #51, Phase 3).
///
/// Lets the user paste the peer's pinned static public key + a shared pairing
/// token, then Connect: the ``SecureChannelTransport`` walks signaling ->
/// hole-punch -> Noise IK handshake -> connected and exposes a live status, the
/// decrypted message log, and send paths for reliable text and a best-effort
/// test blob. Reached from the shared Identity & Keys section in `SettingsView`.
struct SecureMessagingView: View {
    @AppStorage("p2p.rendezvousURL") private var rendezvousURL = "https://rendezvous.blau.app"
    @AppStorage("p2p.allowInsecureLocalhost") private var allowInsecureLocalhost = false

    @State private var peerKeyInput = ""
    @State private var tokenInput = ""
    @State private var transport: SecureChannelTransport?
    @State private var outgoing = ""
    @State private var errorMessage: String?

    private var myPublicKey: String { DeviceIdentity.publicKeyBase64() ?? "—" }
    private let pairingStore = SecurePairingStore()

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
        .navigationTitle("Secure Messaging")
        .navigationBarTitleDisplayMode(.inline)
        .task { loadPairingSecrets() }
        .onDisappear { savePairingSecrets() }
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
            ShareLink(item: myPublicKey) {
                Label("Share my key", systemImage: "key")
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
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .lineLimit(1...3)
            TextField("Pairing token", text: $tokenInput)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Generate secure pairing token") { generateToken() }
            TextField("Rendezvous URL", text: $rendezvousURL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
            Toggle("Allow HTTP for localhost development", isOn: $allowInsecureLocalhost)

            if let transport, !transport.state.isFailed {
                Button(transport.state == .signaling ? "Cancel connection" : "Disconnect", role: .destructive) {
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
            Text("The pairing token must match on both devices. Peer key is pinned and authenticated by the handshake.")
        }
    }

    private func messagingSection(_ transport: SecureChannelTransport) -> some View {
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

    private func logSection(_ transport: SecureChannelTransport) -> some View {
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
            && SecurePairingStore.isValidIdentifier(
                tokenInput.trimmingCharacters(in: .whitespacesAndNewlines)
            )
    }

    private func connect() {
        guard let peerKey = DeviceIdentity.parsePeerPublicKey(peerKeyInput) else {
            errorMessage = "Peer public key is not a valid base64 X25519 key."
            return
        }
        let token = tokenInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard SecurePairingStore.isValidIdentifier(token) else {
            errorMessage = "Use a randomly generated pairing token."
            return
        }
        do {
            try pairingStore.setPeerPublicKey(peerKeyInput)
            try pairingStore.setToken(token)
            let identity = try DeviceIdentity.loadOrCreate()
            let client = try SignalingClient(
                baseURLString: rendezvousURL,
                allowInsecureLocalhost: allowInsecureLocalhost
            )
            let t = SecureChannelTransport(
                signaling: client,
                token: token,
                staticKey: identity,
                peerStatic: peerKey
            )
            replaceActiveConnection(&transport, with: t) { $0.disconnect() }
            t.connect()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func loadPairingSecrets() {
        do {
            let secrets = try pairingStore.loadMigratingLegacy()
            peerKeyInput = secrets.peerPublicKey
            tokenInput = secrets.token
        } catch {
            errorMessage = "Could not load secure pairing settings."
        }
    }

    private func savePairingSecrets() {
        do {
            try pairingStore.setPeerPublicKey(peerKeyInput)
            try pairingStore.setToken(tokenInput)
        } catch {
            errorMessage = "Could not save secure pairing settings."
        }
    }

    private func generateToken() {
        do {
            tokenInput = try SecurePairingStore.generateToken()
            try pairingStore.setToken(tokenInput)
        } catch {
            errorMessage = "Could not generate a secure pairing token."
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
