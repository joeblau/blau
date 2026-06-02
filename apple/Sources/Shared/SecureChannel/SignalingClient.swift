import Foundation

/// HTTP client for the rendezvous signaling worker (issue #51).
///
/// The worker introduces two devices that share a pairing `token`: each device
/// POSTs `/register` with its public key + the local UDP port it is listening
/// on, and the edge records the *observed* public IP. Either device then polls
/// `GET /get-peer` until the other has registered, at which point both learn
/// each other's `{ ip, port }` and can start UDP hole punching.
///
/// The worker never sees plaintext or session keys — only the routing metadata
/// (public key, IP, port). Authentication of the peer happens entirely in the
/// Noise IK handshake against the manually-pinned static key.
struct SignalingClient {

    /// A peer endpoint returned by the worker.
    struct PeerEndpoint: Equatable, Sendable {
        let publicKey: String
        let ip: String
        let port: UInt16
    }

    enum SignalingError: Error, LocalizedError {
        case badURL
        case http(Int)
        case decode
        case pairFull

        var errorDescription: String? {
            switch self {
            case .badURL: return "Invalid rendezvous URL."
            case .http(let code): return "Rendezvous server returned HTTP \(code)."
            case .decode: return "Could not parse the rendezvous response."
            case .pairFull: return "This pairing token already has two devices."
            }
        }
    }

    /// Base URL of the rendezvous worker. Defaults to production.
    let baseURL: URL
    private let session: URLSession

    init(baseURL: URL = URL(string: "https://rendezvous.blau.app")!,
         session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    /// Convenience initializer from a user-entered string; falls back to the
    /// default when the string is empty or unparseable.
    init(baseURLString: String?, session: URLSession = .shared) {
        let trimmed = baseURLString?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let url = trimmed.isEmpty ? nil : URL(string: trimmed)
        self.init(baseURL: url ?? URL(string: "https://rendezvous.blau.app")!,
                  session: session)
    }

    // MARK: - Register

    /// POST `/register`. Records this device under `token` and returns the peer
    /// endpoint if the other device has already registered, otherwise `nil`.
    func register(token: String, publicKeyBase64: String, port: UInt16) async throws -> PeerEndpoint? {
        let url = baseURL.appendingPathComponent("register")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let payload: [String: Any] = [
            "token": token,
            "publicKey": publicKeyBase64,
            "port": Int(port),
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SignalingError.decode }
        if http.statusCode == 409 { throw SignalingError.pairFull }
        guard (200..<300).contains(http.statusCode) else { throw SignalingError.http(http.statusCode) }

        // The register response echoes the *other* peer if present. When this
        // device is first to register, the worker returns this device's own
        // record; we filter that out by comparing public keys.
        guard let peer = Self.parsePeer(data) else { return nil }
        if peer.publicKey == publicKeyBase64 { return nil }
        return peer
    }

    // MARK: - Get peer

    /// GET `/get-peer`. Returns the other peer's endpoint or `nil` (HTTP 204)
    /// if it has not registered yet.
    func getPeer(token: String, publicKeyBase64: String) async throws -> PeerEndpoint? {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("get-peer"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "token", value: token),
            URLQueryItem(name: "publicKey", value: publicKeyBase64),
        ]
        guard let url = components?.url else { throw SignalingError.badURL }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SignalingError.decode }
        if http.statusCode == 204 { return nil }
        guard (200..<300).contains(http.statusCode) else { throw SignalingError.http(http.statusCode) }
        return Self.parsePeer(data)
    }

    /// Poll `/get-peer` until the peer registers or the deadline elapses.
    func waitForPeer(
        token: String,
        publicKeyBase64: String,
        pollInterval: Duration = .seconds(1),
        timeout: Duration = .seconds(30)
    ) async throws -> PeerEndpoint {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if let peer = try await getPeer(token: token, publicKeyBase64: publicKeyBase64) {
                return peer
            }
            try await Task.sleep(for: pollInterval)
        }
        throw SignalingError.http(408)
    }

    // MARK: - Parsing

    private static func parsePeer(_ data: Data) -> PeerEndpoint? {
        guard !data.isEmpty,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let publicKey = obj["publicKey"] as? String,
              let ip = obj["ip"] as? String
        else { return nil }
        let portValue: UInt16?
        if let p = obj["port"] as? Int { portValue = UInt16(exactly: p) }
        else if let p = obj["port"] as? Double { portValue = UInt16(exactly: p) }
        else { portValue = nil }
        guard let port = portValue, !publicKey.isEmpty, !ip.isEmpty else { return nil }
        return PeerEndpoint(publicKey: publicKey, ip: ip, port: port)
    }
}
