import SwiftUI

struct BrowserStartPageView: View {
    let rootPath: String?
    let onSelect: (LocalServer) -> Void

    @State private var servers: [LocalServer] = []
    @State private var liveness: [Int: Bool] = [:]
    @State private var hasScanned = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Spacer(minLength: 0)
            if hasScanned {
                if servers.isEmpty {
                    emptyState
                } else {
                    serverList
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(20)
        .task(id: rootPath ?? "") { await refresh() }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Local")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("No dev servers found in this workspace.")
                .font(.callout)
                .foregroundStyle(.tertiary)
        }
    }

    private var serverList: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Local")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            VStack(spacing: 10) {
                ForEach(servers) { server in
                    LocalServerCard(
                        server: server,
                        isLive: liveness[server.port] ?? false,
                        onTap: { onSelect(server) }
                    )
                }
            }
        }
    }

    private func refresh() async {
        let path = rootPath ?? ""
        let discovered = await LocalServerScanner.scan(rootPath: path)
        servers = discovered
        hasScanned = true
        await probe(servers: discovered)
    }

    private func probe(servers: [LocalServer]) async {
        await withTaskGroup(of: (Int, Bool).self) { group in
            for server in servers {
                group.addTask {
                    let live = await LocalServerProbe.isLive(port: server.port)
                    return (server.port, live)
                }
            }
            for await (port, live) in group {
                liveness[port] = live
            }
        }
    }
}

private struct LocalServerCard: View {
    let server: LocalServer
    let isLive: Bool
    let onTap: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 14) {
                BrowserPreviewThumbnail(name: server.name, displayURL: server.displayURL)
                VStack(alignment: .leading, spacing: 2) {
                    Text(server.name)
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(1)
                    Text(server.displayURL)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Circle()
                    .fill(isLive ? .green : Color(nsColor: .tertiaryLabelColor))
                    .frame(width: 8, height: 8)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor)
                        .opacity(isHovering ? 0.9 : 0.6))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

private struct BrowserPreviewThumbnail: View {
    let name: String
    let displayURL: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 3) {
                Circle().fill(.red).frame(width: 5, height: 5)
                Circle().fill(.yellow).frame(width: 5, height: 5)
                Circle().fill(.green).frame(width: 5, height: 5)
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: 3) {
                Capsule().fill(Color.secondary.opacity(0.35)).frame(height: 3)
                Capsule().fill(Color.secondary.opacity(0.25)).frame(width: 38, height: 3)
            }
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                    .font(.system(size: 8, weight: .semibold))
                    .lineLimit(1)
                Text(displayURL)
                    .font(.system(size: 6.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(6)
        .frame(width: 96, height: 60)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.black.opacity(0.15), lineWidth: 0.5)
        }
        .foregroundStyle(.black)
    }
}
