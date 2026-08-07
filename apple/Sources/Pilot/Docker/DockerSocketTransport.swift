import Foundation
import Network

/// Finds the Engine API socket.
///
/// Pilot deliberately does not ship or supervise a container runtime — it talks
/// to whichever one the user already runs. Docker Desktop, Colima, Rancher
/// Desktop, and Podman's Docker-compatible service all expose the same HTTP API
/// on a Unix domain socket, just in different places, so discovery is a short
/// ordered search rather than a hard-coded path.
enum DockerSocketLocator {
    /// Candidate paths in priority order, relative to a home directory.
    /// `DOCKER_HOST` (when it names a Unix socket) always wins — that's the
    /// switch users flip to point at a non-default runtime.
    static func candidates(environment: [String: String], home: String) -> [String] {
        var paths: [String] = []
        if let host = environment["DOCKER_HOST"], let path = unixPath(fromDockerHost: host) {
            paths.append(path)
        }
        paths.append(contentsOf: [
            "\(home)/.docker/run/docker.sock",                                  // Docker Desktop
            "/var/run/docker.sock",                                             // system default / classic
            "\(home)/.colima/default/docker.sock",                              // Colima
            "\(home)/.rd/docker.sock",                                          // Rancher Desktop
            "\(home)/.local/share/containers/podman/machine/podman.sock"        // Podman compat
        ])
        // Preserve order while dropping duplicates (DOCKER_HOST often repeats a default).
        var seen = Set<String>()
        return paths.filter { seen.insert($0).inserted }
    }

    /// `unix:///var/run/docker.sock` → `/var/run/docker.sock`. Returns nil for
    /// `tcp://` and `ssh://` hosts: those are remote daemons, which this section
    /// intentionally does not reach out to.
    static func unixPath(fromDockerHost host: String) -> String? {
        let trimmed = host.trimmingCharacters(in: .whitespaces)
        guard trimmed.lowercased().hasPrefix("unix://") else {
            // A bare path is also accepted; anything else names a remote daemon.
            return trimmed.hasPrefix("/") ? trimmed : nil
        }
        let path = String(trimmed.dropFirst("unix://".count))
        return path.hasPrefix("/") ? path : nil
    }

    /// Darwin's `sockaddr_un.sun_path` holds 104 bytes. `NWEndpoint.unix(path:)`
    /// accepts a longer path without complaint, but the resulting connection
    /// never reports *any* state — it neither succeeds nor fails — and the async
    /// read path traps. Paths past the limit are therefore rejected up front
    /// rather than handed to Network.
    static let maxSocketPathBytes = 104

    /// Whether a path can be used as an AF_UNIX endpoint at all. A malformed
    /// `DOCKER_HOST`, or a socket under an unusually deep home directory, would
    /// otherwise take the app down.
    static func isUsablePath(_ path: String) -> Bool {
        !path.isEmpty && path.hasPrefix("/") && path.utf8.count <= maxSocketPathBytes
    }

    /// First usable candidate that exists on disk.
    static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: String = NSHomeDirectory(),
        exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> String? {
        candidates(environment: environment, home: home)
            .first { isUsablePath($0) && exists($0) }
    }
}

/// HTTP/1.1 over a Unix domain socket.
///
/// `URLSession` has no AF_UNIX transport, so this drives `NWConnection` against
/// an `.unix(path:)` endpoint and frames the response with
/// ``DockerHTTPResponseParser``. Each request opens and closes its own
/// connection: the API is local and cheap to reconnect to, and a per-request
/// socket keeps a stuck streaming read from wedging unrelated calls.
struct DockerSocketTransport: Sendable {
    let socketPath: String
    var maxResponseBytes: Int = 8 * 1024 * 1024
    var timeout: Duration = .seconds(15)

    /// Collect a complete response. Bounded by ``timeout`` — `NWConnection` will
    /// otherwise wait indefinitely on a daemon that accepts the connection and
    /// then goes quiet.
    func send(_ request: DockerRequest) async throws -> DockerResponse {
        try await withDockerTimeout(timeout) {
            var status: Int?
            var body = Data()
            for try await event in stream(request) {
                switch event {
                case .head(let code, _):
                    status = code
                case .body(let chunk):
                    body.append(chunk)
                }
            }
            guard let status else {
                throw DockerTransportError.malformedResponse("no status line")
            }
            return DockerResponse(status: status, body: body)
        }
    }

    /// Stream a response as it arrives. Used for `/events`, which never ends on
    /// its own; the stream terminates when the consuming task is cancelled.
    func stream(_ request: DockerRequest) -> AsyncThrowingStream<DockerStreamEvent, any Error> {
        let path = socketPath
        let wire = request.serialized()
        let ceiling = maxResponseBytes

        return AsyncThrowingStream { continuation in
            guard DockerSocketLocator.isUsablePath(path) else {
                continuation.finish(
                    throwing: DockerTransportError.daemonUnreachable(
                        "“\(UntrustedText.sanitized(path, limit: 120))” is not a usable socket path"
                    )
                )
                return
            }

            let queue = DispatchQueue(label: "app.blau.pilot.docker-socket")
            let connection = NWConnection(to: .unix(path: path), using: .tcp)
            let state = ParserBox(parser: DockerHTTPResponseParser(maxBodyBytes: ceiling))

            @Sendable func fail(_ error: any Error) {
                connection.cancel()
                continuation.finish(throwing: error)
            }

            @Sendable func finish() {
                connection.cancel()
                continuation.finish()
            }

            /// The peer went away. Whether that is success or truncation is the
            /// parser's call: a complete message (or a close-delimited one) ends
            /// cleanly, anything else was cut short.
            @Sendable func concludeAfterClose(networkError: (any Error)?) {
                if state.parser.isBodyComplete {
                    finish()
                    return
                }
                do {
                    try state.parser.finishOnEOF()
                    finish()
                } catch {
                    // Once a status line has been read the socket clearly worked,
                    // so the parser's "cut short" reason is the useful one.
                    fail(state.parser.statusCode == nil && networkError != nil
                         ? DockerTransportError.daemonUnreachable(networkError!.localizedDescription)
                         : error)
                }
            }

            @Sendable func receiveNext() {
                connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
                    // Bytes can arrive alongside the error that ends the stream,
                    // so they are always consumed before the error is acted on.
                    if let data, !data.isEmpty {
                        do {
                            let bodyChunk = try state.parser.consume(data)
                            if !state.didEmitHead, let code = state.parser.statusCode {
                                state.didEmitHead = true
                                continuation.yield(.head(status: code, headers: state.parser.headers))
                            }
                            if !bodyChunk.isEmpty {
                                continuation.yield(.body(bodyChunk))
                            }
                            if state.parser.isBodyComplete {
                                finish()
                                return
                            }
                        } catch {
                            fail(error)
                            return
                        }
                    }
                    if let error {
                        concludeAfterClose(networkError: error)
                        return
                    }
                    if isComplete {
                        concludeAfterClose(networkError: nil)
                        return
                    }
                    receiveNext()
                }
            }

            connection.stateUpdateHandler = { newState in
                switch newState {
                case .ready:
                    state.didBecomeReady = true
                    connection.send(content: wire, completion: .contentProcessed { error in
                        if let error {
                            fail(DockerTransportError.daemonUnreachable(error.localizedDescription))
                        }
                    })
                    receiveNext()
                case .waiting(let error), .failed(let error):
                    // Before the handshake this means there is nothing listening:
                    // for AF_UNIX a missing socket parks the connection in
                    // `.waiting` and retries forever, so report it now rather
                    // than hanging.
                    //
                    // After it, this is just the daemon hanging up on a
                    // `Connection: close` response — which Network reports as a
                    // failed state (ENETDOWN) rather than a clean end, and often
                    // *ahead* of the last bytes it has already buffered for us.
                    // The receive loop owns that ending; concluding here would
                    // discard the tail of a perfectly good response.
                    guard !state.didBecomeReady else { break }
                    fail(DockerTransportError.daemonUnreachable(error.localizedDescription))
                case .cancelled:
                    continuation.finish()
                case .setup, .preparing:
                    break
                @unknown default:
                    break
                }
            }

            continuation.onTermination = { _ in connection.cancel() }
            connection.start(queue: queue)
        }
    }
}

/// The parser is touched only from the connection's serial queue, which owns
/// every `NWConnection` callback, so sharing it with those `@Sendable` closures
/// is safe without additional locking.
private final class ParserBox: @unchecked Sendable {
    var parser: DockerHTTPResponseParser
    var didEmitHead = false
    var didBecomeReady = false

    init(parser: DockerHTTPResponseParser) {
        self.parser = parser
    }
}

/// Race an operation against a deadline, cancelling whichever loses.
func withDockerTimeout<T: Sendable>(
    _ duration: Duration,
    _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: duration)
            throw DockerTransportError.timedOut
        }
        guard let result = try await group.next() else {
            throw DockerTransportError.timedOut
        }
        group.cancelAll()
        return result
    }
}
