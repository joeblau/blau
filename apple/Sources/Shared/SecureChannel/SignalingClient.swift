import Foundation

/// HTTPS client for the rendezvous worker. Pairing material is always sent in
/// bounded JSON POST bodies, never in URLs or error descriptions.
struct SignalingClient {
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
            case .badURL: return "Use an HTTPS rendezvous URL."
            case .http(let code): return "Rendezvous server returned HTTP \(code)."
            case .decode: return "Could not parse the rendezvous response."
            case .pairFull: return "This pairing token already has two devices."
            }
        }
    }

    private struct SignalBody: Encodable {
        let token: String
        let publicKey: String
        let port: UInt16?
    }

    private static let productionURL = URL(string: "https://rendezvous.blau.app")!

    let baseURL: URL
    private let session: URLSession

    init(
        baseURL: URL = productionURL,
        session: URLSession = .shared,
        allowInsecureLocalhost: Bool = false
    ) throws {
        guard Self.isAllowed(baseURL, allowInsecureLocalhost: allowInsecureLocalhost) else {
            throw SignalingError.badURL
        }
        self.baseURL = baseURL
        self.session = session
    }

    init(
        baseURLString: String?,
        session: URLSession = .shared,
        allowInsecureLocalhost: Bool = false
    ) throws {
        let trimmed = baseURLString?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard trimmed.isEmpty || URL(string: trimmed) != nil else { throw SignalingError.badURL }
        try self.init(
            baseURL: trimmed.isEmpty ? Self.productionURL : URL(string: trimmed)!,
            session: session,
            allowInsecureLocalhost: allowInsecureLocalhost
        )
    }

    func register(
        token: String,
        publicKeyBase64: String,
        port: UInt16
    ) async throws -> PeerEndpoint? {
        let request = try makeRequest(
            path: "register",
            body: SignalBody(token: token, publicKey: publicKeyBase64, port: port)
        )
        return try await perform(request, pairCanBeFull: true)
    }

    func getPeer(token: String, publicKeyBase64: String) async throws -> PeerEndpoint? {
        let request = try makeRequest(
            path: "get-peer",
            body: SignalBody(token: token, publicKey: publicKeyBase64, port: nil)
        )
        return try await perform(request, pairCanBeFull: false)
    }

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

    private func makeRequest(path: String, body: SignalBody) throws -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.httpBody = try JSONEncoder().encode(body)
        return request
    }

    private func perform(_ request: URLRequest, pairCanBeFull: Bool) async throws -> PeerEndpoint? {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SignalingError.decode }
        if http.statusCode == 204 { return nil }
        if pairCanBeFull && http.statusCode == 409 { throw SignalingError.pairFull }
        guard (200..<300).contains(http.statusCode) else {
            throw SignalingError.http(http.statusCode)
        }
        guard let peer = Self.parsePeer(data) else { throw SignalingError.decode }
        return peer
    }

    private static func isAllowed(_ url: URL, allowInsecureLocalhost: Bool) -> Bool {
        guard url.user == nil,
              url.password == nil,
              url.query == nil,
              url.fragment == nil,
              url.path.isEmpty || url.path == "/",
              let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased()
        else { return false }
        if scheme == "https" { return true }
        let localHosts = ["localhost", "127.0.0.1", "::1"]
        return allowInsecureLocalhost && scheme == "http" && localHosts.contains(host)
    }

    private static func parsePeer(_ data: Data) -> PeerEndpoint? {
        guard !data.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let publicKey = object["publicKey"] as? String,
              DeviceIdentity.parsePeerPublicKey(publicKey) != nil,
              let ip = object["ip"] as? String,
              !ip.isEmpty
        else { return nil }
        let portValue: UInt16?
        if let port = object["port"] as? Int {
            portValue = UInt16(exactly: port)
        } else if let port = object["port"] as? Double {
            portValue = UInt16(exactly: port)
        } else {
            portValue = nil
        }
        guard let port = portValue else { return nil }
        return PeerEndpoint(publicKey: publicKey, ip: ip, port: port)
    }
}
