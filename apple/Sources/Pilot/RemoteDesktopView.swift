import AppKit
import SwiftUI

/// Detail-area view for the global Remote Desktop mode. A horizontal tab bar of
/// saved connections (the same shape as the Notes tab strip) over an embedded
/// VNC viewer. The "+" opens a picker that previews the machines on the network
/// offering Screen Sharing (`_rfb._tcp`) plus a manual host entry — mirroring
/// the editor pane's "new tab → fuzzy finder" gesture.
struct RemoteDesktopView: View {
    @Bindable var store: WorkspaceStore
    @State private var showPicker = false
    @State private var discovery = RemoteScreenDiscovery()

    var body: some View {
        let connections = store.remoteConnections
        VStack(spacing: 0) {
            tabBar(connections: connections)
            Divider()
            content(connections: connections)
        }
        .overlay {
            if showPicker {
                RemoteComputerPicker(
                    discovery: discovery,
                    onPick: { host, port, nickname in
                        store.addRemoteConnection(host: host, port: port, nickname: nickname)
                        store.isRemoteDesktopMode = true
                        showPicker = false
                    },
                    onCancel: { showPicker = false }
                )
                .transition(.opacity)
            }
        }
        .confirmationDialog(
            "Remove this connection?",
            isPresented: Binding(
                get: { store.remoteConnectionPendingClose != nil },
                set: { if !$0 { store.remoteConnectionPendingClose = nil } }
            ),
            presenting: store.remoteConnectionPendingClose
        ) { connection in
            Button("Remove Connection", role: .destructive) {
                store.deleteRemoteConnection(connection)
                store.remoteConnectionPendingClose = nil
            }
            Button("Cancel", role: .cancel) { store.remoteConnectionPendingClose = nil }
        } message: { connection in
            Text("“\(connection.displayTitle)” will be removed from your saved connections.")
        }
        .onChange(of: showPicker) {
            if showPicker { discovery.start() } else { discovery.stop() }
        }
        .onAppear {
            // Entering the section with nothing saved drops straight into the
            // picker so the first thing you see is "which computers can I reach".
            if connections.isEmpty { showPicker = true }
        }
    }

    private func tabBar(connections: [RemoteDesktopConnection]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(connections) { connection in
                    RemoteTab(
                        title: connection.displayTitle,
                        isSelected: connection.id == store.selectedRemoteConnectionID,
                        onSelect: { store.selectedRemoteConnectionID = connection.id },
                        onClose: { store.requestCloseRemoteConnection(connection) }
                    )
                    .draggable(connection.id.uuidString)
                    .dropDestination(for: String.self) { items, _ in
                        guard let raw = items.first,
                              let draggedID = UUID(uuidString: raw) else { return false }
                        store.moveRemoteConnection(draggedID, before: connection.id)
                        return true
                    }
                }

                Button {
                    showPicker = true
                } label: {
                    Image(systemName: "plus")
                        .scaledFont(size: 12, weight: .medium)
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("New Connection")
                .dropDestination(for: String.self) { items, _ in
                    guard let raw = items.first,
                          let draggedID = UUID(uuidString: raw) else { return false }
                    store.moveRemoteConnectionToEnd(draggedID)
                    return true
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private func content(connections: [RemoteDesktopConnection]) -> some View {
        if let connection = store.selectedRemoteConnection {
            RemoteConnectionPane(connection: connection)
                // Re-create the pane (and its VNC session) when the selected
                // connection changes so a tab switch rebinds cleanly.
                .id(connection.id)
        } else {
            ContentUnavailableView {
                Label("No Connection", systemImage: "macbook.and.iphone")
            } description: {
                Text("Add a computer with the + button.")
            } actions: {
                Button("Find Computers") { showPicker = true }
            }
        }
    }
}

/// A single connection tab — same chrome as the Notes `NoteTab`.
private struct RemoteTab: View {
    let title: String
    let isSelected: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "display")
                .scaledFont(size: 10, weight: .medium)
                .foregroundStyle(.secondary)
            Text(title)
                .scaledFont(size: 12, weight: isSelected ? .semibold : .regular)
                .lineLimit(1)

            if isHovering || isSelected {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .scaledFont(size: 9, weight: .bold)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Remove Connection")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .frame(maxWidth: 180, alignment: .leading)
        .background(
            isSelected ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.08),
            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(isSelected ? Color.accentColor.opacity(0.5) : .clear, lineWidth: 1)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { isHovering = $0 }
    }
}

/// One connection's pane: a connect form until the user supplies a password and
/// hits Connect, then the embedded live VNC view (with a spinner while the
/// handshake completes, and an inline error on failure).
private struct RemoteConnectionPane: View {
    @Bindable var connection: RemoteDesktopConnection
    @Environment(\.colorScheme) private var colorScheme

    @State private var session = RemoteConnectionSession()
    @State private var password = ""
    @State private var savePassword = false

    var body: some View {
        ZStack {
            switch session.status {
            case .idle, .disconnected:
                connectForm(error: nil)
            case .failed(let message):
                connectForm(error: message)
            case .connecting, .connected:
                RemoteDesktopViewer(
                    host: connection.host,
                    port: connection.port,
                    username: connection.username,
                    password: password,
                    session: session
                )
                .background(Color.black)

                if session.status == .connecting {
                    connectingOverlay
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Auto-connect on tab switch when a password is saved. The pane (and its
        // `session`) is recreated per connection via `.id(connection.id)`, so this
        // fires once each time you tab to a machine.
        .onAppear(perform: restoreSavedPasswordAndConnect)
    }

    private func restoreSavedPasswordAndConnect() {
        guard password.isEmpty, case .idle = session.status else { return }
        guard let saved = VNCKeychain.load(id: connection.id), !saved.isEmpty else { return }
        password = saved
        savePassword = true
        connect()
    }

    private var connectingOverlay: some View {
        VStack(spacing: 10) {
            ProgressView().controlSize(.large)
            Text("Connecting to \(connection.displayTitle)…")
                .foregroundStyle(.white.opacity(0.85))
                .font(.callout)
            Button("Cancel") { session.status = .idle }
                .buttonStyle(.bordered)
                .tint(.white)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black.opacity(0.55))
    }

    private func connectForm(error: String?) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "display")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.tertiary)

            VStack(spacing: 2) {
                Text(connection.displayTitle)
                    .font(.title3.weight(.semibold))
                Text(verbatim: "\(connection.host):\(connection.port)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 10) {
                TextField("Username (optional)", text: Bindable(connection).username)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 280)
                SecureField("Password", text: $password)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 280)
                    .onSubmit(connect)
                Toggle("Save password & auto-connect", isOn: $savePassword)
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                    .frame(width: 280, alignment: .leading)
            }

            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            }

            Button(action: connect) {
                Text("Connect")
                    .frame(width: 120)
            }
            .keyboardShortcut(.return)
            .buttonStyle(.borderedProminent)
            .disabled(connection.host.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func connect() {
        if savePassword, !password.isEmpty {
            VNCKeychain.save(password, id: connection.id)
        } else if !savePassword {
            VNCKeychain.delete(id: connection.id)
        }
        connection.lastConnectedAt = Date()
        try? connection.modelContext?.save()
        session.status = .connecting
    }
}

/// The "new tab" overlay: a card listing the machines discovered over Bonjour
/// (`_rfb._tcp`) plus a manual host field. Same visual chrome as the editor
/// pane's fuzzy file finder.
private struct RemoteComputerPicker: View {
    let discovery: RemoteScreenDiscovery
    let onPick: (_ host: String, _ port: Int, _ nickname: String) -> Void
    let onCancel: () -> Void

    @State private var manualHost = ""
    @State private var isResolving = false
    @FocusState private var manualFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "wifi")
                    .foregroundStyle(.secondary)
                Text("Computers on this network")
                    .font(.system(size: 14, weight: .medium))
                Spacer()
                Button {
                    onCancel()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            Divider()

            discoveredList
                .frame(maxHeight: 280)

            Divider()

            HStack(spacing: 8) {
                Image(systemName: "network")
                    .foregroundStyle(.secondary)
                TextField("Host or IP (e.g. studio.local)", text: $manualHost)
                    .textFieldStyle(.plain)
                    .focused($manualFocused)
                    .onSubmit(connectManual)
                Button("Connect", action: connectManual)
                    .disabled(manualHost.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
        .frame(width: 520)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color(nsColor: .separatorColor).opacity(0.4), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.25), radius: 24, y: 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.top, 60)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private var discoveredList: some View {
        if discovery.services.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(discovery.services) { service in
                        Button {
                            pick(service)
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "macbook")
                                    .foregroundStyle(.secondary)
                                Text(service.name)
                                    .font(.system(size: 13))
                                    .foregroundStyle(.primary)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 4)
            }
            .disabled(isResolving)
            .opacity(isResolving ? 0.5 : 1)
        }
    }

    /// Shown while no machines are listed. Always offers the actionable next
    /// steps (a Mac needs Screen Sharing on; Pilot needs Local Network access),
    /// and reads as a clear error — not a perpetual spinner — when the browser
    /// reports it's blocked.
    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 12) {
            switch discovery.browseState {
            case .needsPermission, .failed:
                Image(systemName: "wifi.exclamationmark")
                    .font(.system(size: 26))
                    .foregroundStyle(.secondary)
                Text("Pilot can't browse the local network")
                    .font(.callout.weight(.medium))
            default:
                ProgressView().controlSize(.small)
                Text("Looking for computers with Screen Sharing enabled…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Text("The target Mac needs Screen Sharing on (System Settings → General → Sharing), and Pilot needs Local Network access. You can still connect by typing a host below.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)

            Button("Open Local Network Settings") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork") {
                    NSWorkspace.shared.open(url)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private func pick(_ service: RemoteScreenDiscovery.Service) {
        isResolving = true
        Task {
            let resolved = await discovery.resolve(service)
            isResolving = false
            if let resolved {
                onPick(resolved.host, resolved.port, service.name)
            } else {
                // Resolution failed — fall back to the Bonjour name, which is
                // usually reachable as "<name>.local" on the same network.
                onPick(service.name, 5900, service.name)
            }
        }
    }

    private func connectManual() {
        let trimmed = manualHost.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let (host, port) = Self.parseHostPort(trimmed)
        onPick(host, port, "")
    }

    /// Split a "host" or "host:port" string; defaults to the VNC port 5900.
    private static func parseHostPort(_ input: String) -> (String, Int) {
        // Leave bracketed IPv6 literals (and their ports) to the user as-is.
        guard !input.hasPrefix("["),
              let colon = input.lastIndex(of: ":"),
              let port = Int(input[input.index(after: colon)...]) else {
            return (input, 5900)
        }
        return (String(input[..<colon]), port)
    }
}
