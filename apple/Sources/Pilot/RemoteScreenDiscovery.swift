import Foundation
import Network

/// Discovers machines offering Screen Sharing / Remote Management on the LAN.
/// macOS (and most VNC servers) advertise the RFB service over Bonjour as
/// `_rfb._tcp`, so an `NWBrowser` over that type is the live "computers you can
/// connect to" list behind the new-tab picker. Mirrors the `NWBrowser` idiom
/// in `FrameLink`, but stays on the main actor so SwiftUI can observe `services`
/// directly (the browse callback is cheap; only the brief endpoint resolution
/// hops to a background queue).
@Observable
@MainActor
final class RemoteScreenDiscovery {
    /// One discovered RFB service. `endpoint` is the Bonjour service endpoint we
    /// resolve to a concrete host/port when the user picks it.
    struct Service: Identifiable, Hashable {
        let id: String        // unique Bonjour service name
        let name: String      // display name (usually the computer name)
        let endpoint: NWEndpoint

        static func == (lhs: Service, rhs: Service) -> Bool { lhs.id == rhs.id }
        func hash(into hasher: inout Hasher) { hasher.combine(id) }
    }

    /// A resolved address ready to hand to the VNC client.
    struct ResolvedAddress: Sendable {
        let host: String
        let port: Int
    }

    /// What the browser is doing, so the picker can show an actionable message
    /// rather than an endless spinner when discovery is blocked.
    enum BrowseState: Equatable {
        case idle
        case browsing                 // `.ready` — searching the network
        case needsPermission(String)  // `.waiting` — Local Network access not granted
        case failed(String)
    }
    private(set) var browseState: BrowseState = .idle

    private(set) var services: [Service] = []
    private var browser: NWBrowser?

    /// Start (idempotent) browsing for `_rfb._tcp`. Safe to call on every picker
    /// open; a no-op while a browser is already live.
    func start() {
        guard browser == nil else { return }
        let parameters = NWParameters()
        parameters.includePeerToPeer = false
        let browser = NWBrowser(for: .bonjour(type: "_rfb._tcp", domain: nil), using: parameters)

        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in self?.apply(results) }
        }
        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .ready:
                    self.browseState = .browsing
                case .waiting(let error):
                    // `.waiting` here almost always means macOS hasn't granted
                    // Pilot Local Network access (or `_rfb._tcp` isn't allowed in
                    // NSBonjourServices yet) — surface it instead of spinning.
                    self.browseState = .needsPermission(error.localizedDescription)
                case .failed(let error):
                    self.browseState = .failed(error.localizedDescription)
                    self.restart()
                case .cancelled:
                    break
                default:
                    break
                }
            }
        }

        self.browser = browser
        browser.start(queue: .main)
    }

    func stop() {
        browser?.cancel()
        browser = nil
        services = []
        browseState = .idle
    }

    private func restart() {
        browser = nil
        start()
    }

    private func apply(_ results: Set<NWBrowser.Result>) {
        services = results.compactMap { result -> Service? in
            guard case let .service(name, _, _, _) = result.endpoint else { return nil }
            return Service(id: name, name: name, endpoint: result.endpoint)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Resolve a discovered Bonjour service to a concrete host + port. RoyalVNC
    /// connects by hostname, so we briefly open a connection to the service
    /// endpoint and read back the resolved remote address, then cancel.
    func resolve(_ service: Service) async -> ResolvedAddress? {
        await Self.resolveEndpoint(service.endpoint)
    }

    nonisolated private static let resolveQueue = DispatchQueue(label: "app.blau.remotedesktop.resolve")

    /// One-shot resolver. The `Box` (with a lock) guarantees the continuation is
    /// resumed exactly once across the connection's state callback and the
    /// safety timeout, which may fire on different threads.
    nonisolated private static func resolveEndpoint(_ endpoint: NWEndpoint) async -> ResolvedAddress? {
        final class Box: @unchecked Sendable {
            let lock = NSLock()
            var finished = false
            var connection: NWConnection?
        }
        let box = Box()

        return await withCheckedContinuation { (continuation: CheckedContinuation<ResolvedAddress?, Never>) in
            let connection = NWConnection(to: endpoint, using: .tcp)
            box.connection = connection

            @Sendable func finish(_ result: ResolvedAddress?) {
                box.lock.lock()
                let isFirst = !box.finished
                box.finished = true
                box.lock.unlock()
                guard isFirst else { return }
                box.connection?.cancel()
                box.connection = nil
                continuation.resume(returning: result)
            }

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if case let .hostPort(host, port)? = box.connection?.currentPath?.remoteEndpoint {
                        finish(ResolvedAddress(host: hostString(host), port: Int(port.rawValue)))
                    } else {
                        finish(nil)
                    }
                case .failed, .cancelled:
                    finish(nil)
                default:
                    break
                }
            }

            connection.start(queue: resolveQueue)
            resolveQueue.asyncAfter(deadline: .now() + 4) { finish(nil) }
        }
    }

    /// A printable host string for an `NWEndpoint.Host`, dropping any IPv6 zone
    /// suffix (`%en0`) that a raw client wouldn't accept.
    nonisolated private static func hostString(_ host: NWEndpoint.Host) -> String {
        switch host {
        case .name(let name, _):
            return name
        case .ipv4(let address):
            return address.debugDescription.components(separatedBy: "%").first ?? address.debugDescription
        case .ipv6(let address):
            return address.debugDescription.components(separatedBy: "%").first ?? address.debugDescription
        @unknown default:
            return ""
        }
    }
}
