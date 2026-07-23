import Foundation
import Network

// LocalServerProbe — answers "is anything listening on localhost:N?"
// using a short TCP connect probe. Faster and more permissive than an
// HTTP GET because dev servers often return non-2xx on the bare root,
// and a TCP handshake is enough to know the port is bound.
enum LocalServerProbe {
    static func isLive(port: Int, timeout: TimeInterval = 0.4) async -> Bool {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else { return false }
        let connection = NWConnection(host: "127.0.0.1", port: nwPort, using: .tcp)
        defer { connection.cancel() }

        return await withCheckedContinuation { continuation in
            let resolved = ResultBox()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    resolved.deliver(true, to: continuation)
                case .failed, .cancelled:
                    resolved.deliver(false, to: continuation)
                case .waiting:
                    // No listener yet — give up rather than retrying past the timeout.
                    resolved.deliver(false, to: continuation)
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                resolved.deliver(false, to: continuation)
            }
        }
    }
}

// Re-probes the discovered ports while the browser start page is visible.
// Discovery only needs to happen once, but liveness must remain dynamic because
// developers commonly open the preview before starting a dev server.
enum LocalServerLivenessMonitor {
    static let defaultInterval: Duration = .seconds(2)

    static func monitor(
        servers: [LocalServer],
        interval: Duration = defaultInterval,
        probe: @escaping @Sendable (Int) async -> Bool = { port in
            await LocalServerProbe.isLive(port: port)
        },
        onUpdate: @escaping @MainActor ([Int: Bool]) -> Void
    ) async {
        while !Task.isCancelled {
            let latest = await snapshot(servers: servers, probe: probe)
            guard !Task.isCancelled else { return }
            await onUpdate(latest)

            do {
                try await Task.sleep(for: interval)
            } catch {
                // SwiftUI cancels the view task when the start page disappears.
                return
            }
        }
    }

    private static func snapshot(
        servers: [LocalServer],
        probe: @escaping @Sendable (Int) async -> Bool
    ) async -> [Int: Bool] {
        let ports = Set(servers.map(\.port))
        return await withTaskGroup(
            of: (Int, Bool).self,
            returning: [Int: Bool].self
        ) { group in
            for port in ports {
                group.addTask {
                    (port, await probe(port))
                }
            }

            var result: [Int: Bool] = [:]
            for await (port, isLive) in group {
                result[port] = isLive
            }
            return result
        }
    }
}

private final class ResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func deliver(_ value: Bool, to continuation: CheckedContinuation<Bool, Never>) {
        lock.lock()
        defer { lock.unlock() }
        guard !done else { return }
        done = true
        continuation.resume(returning: value)
    }
}
