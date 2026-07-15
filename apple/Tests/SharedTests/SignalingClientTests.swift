import CryptoKit
import Foundation
import XCTest
@testable import Copilot

final class SignalingClientTests: XCTestCase {
    private final class RequestProtocol: URLProtocol {
        nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            do {
                guard let handler = Self.handler else { throw URLError(.badServerResponse) }
                let (response, data) = try handler(request)
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
            }
        }

        override func stopLoading() {}
    }

    override func tearDown() {
        RequestProtocol.handler = nil
        super.tearDown()
    }

    private static func bodyData(for request: URLRequest) throws -> Data {
        if let body = request.httpBody { return body }
        let stream = try XCTUnwrap(request.httpBodyStream)
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count >= 0 else { throw stream.streamError ?? URLError(.cannotDecodeRawData) }
            if count == 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }

    func testPeerLookupUsesPOSTBodyAndKeepsSecretsOutOfURL() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RequestProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let token = try SecurePairingStore.generateToken()
        let localKey = Curve25519.KeyAgreement.PrivateKey()
            .publicKey.rawRepresentation.base64EncodedString()
        let remoteKey = Curve25519.KeyAgreement.PrivateKey()
            .publicKey.rawRepresentation.base64EncodedString()

        RequestProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.absoluteString, "https://rendezvous.blau.app/get-peer")
            XCTAssertFalse(request.url?.absoluteString.contains(token) ?? true)
            let body = try Self.bodyData(for: request)
            let object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: body) as? [String: Any]
            )
            XCTAssertEqual(object["token"] as? String, token)
            XCTAssertEqual(object["publicKey"] as? String, localKey)
            XCTAssertNil(object["port"])
            let response = try XCTUnwrap(HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            ))
            let data = try JSONSerialization.data(withJSONObject: [
                "publicKey": remoteKey,
                "ip": "203.0.113.2",
                "port": 44_321,
            ])
            return (response, data)
        }

        let client = try SignalingClient(session: session)
        let peer = try await client.getPeer(token: token, publicKeyBase64: localKey)
        XCTAssertEqual(
            peer,
            SignalingClient.PeerEndpoint(
                publicKey: remoteKey,
                ip: "203.0.113.2",
                port: 44_321
            )
        )
    }

    func testRegisterAcceptsNoContentWhileWaitingForPeer() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RequestProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        RequestProtocol.handler = { request in
            let response = try XCTUnwrap(HTTPURLResponse(
                url: request.url!,
                statusCode: 204,
                httpVersion: nil,
                headerFields: nil
            ))
            return (response, Data())
        }
        let client = try SignalingClient(session: session)
        let peer = try await client.register(
            token: SecurePairingStore.generateToken(),
            publicKeyBase64: Curve25519.KeyAgreement.PrivateKey()
                .publicKey.rawRepresentation.base64EncodedString(),
            port: 45_000
        )
        XCTAssertNil(peer)
    }

    func testHTTPSIsRequiredExceptForExplicitLocalDevelopment() throws {
        XCTAssertNoThrow(try SignalingClient(baseURL: URL(string: "https://example.com")!))
        XCTAssertThrowsError(try SignalingClient(baseURL: URL(string: "http://example.com")!))
        XCTAssertThrowsError(try SignalingClient(baseURL: URL(string: "http://localhost:8787")!))
        XCTAssertNoThrow(try SignalingClient(
            baseURL: URL(string: "http://localhost:8787")!,
            allowInsecureLocalhost: true
        ))
        XCTAssertThrowsError(try SignalingClient(
            baseURL: URL(string: "http://192.168.1.10:8787")!,
            allowInsecureLocalhost: true
        ))
    }

    func testMalformedURLDoesNotFallBackToProduction() {
        XCTAssertThrowsError(try SignalingClient(baseURLString: "not a URL"))
        XCTAssertThrowsError(try SignalingClient(baseURLString: "https://example.com/path"))
        XCTAssertNoThrow(try SignalingClient(baseURLString: ""))
    }
}
