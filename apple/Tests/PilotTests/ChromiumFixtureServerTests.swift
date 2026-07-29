import Foundation
import XCTest

final class ChromiumFixtureServerTests: XCTestCase {
    func testRoutesOnlyBundledFixtureFiles() async throws {
        let server = try makeServer()
        try server.start()
        defer { server.stop() }

        let (indexData, indexResponse) = try await fetch(server.baseURL)
        XCTAssertEqual(indexResponse.statusCode, 200)
        XCTAssertTrue(
            String(decoding: indexData, as: UTF8.self)
                .contains("Chromium fixture index")
        )

        let secondURL = server.baseURL.appendingPathComponent(
            "second-page.html"
        )
        let (secondData, secondResponse) = try await fetch(secondURL)
        XCTAssertEqual(secondResponse.statusCode, 200)
        XCTAssertTrue(
            String(decoding: secondData, as: UTF8.self)
                .contains("second-page-marker")
        )

        let downloadURL = server.baseURL.appendingPathComponent("download.txt")
        let (_, downloadResponse) = try await fetch(downloadURL)
        XCTAssertEqual(
            downloadResponse.value(
                forHTTPHeaderField: "Content-Disposition"
            ),
            "attachment; filename=\"pilot-fixture-download.txt\""
        )

        let authenticationURL = server.baseURL.appendingPathComponent(
            "authentication-required"
        )
        let (_, authenticationResponse) = try await fetch(
            authenticationURL
        )
        XCTAssertEqual(authenticationResponse.statusCode, 401)
        XCTAssertEqual(
            authenticationResponse.value(
                forHTTPHeaderField: "WWW-Authenticate"
            ),
            "Basic realm=\"Pilot Chromium fixture\""
        )
    }

    func testRejectsOversizedRequestsAndResponses() async throws {
        let requestBoundedServer = try makeServer(maxRequestBytes: 512)
        try requestBoundedServer.start()
        var oversizedRequest = URLRequest(url: requestBoundedServer.baseURL)
        oversizedRequest.setValue(
            String(repeating: "x", count: 2048),
            forHTTPHeaderField: "X-Fixture-Oversized"
        )
        let (_, requestResponse) = try await fetch(oversizedRequest)
        XCTAssertEqual(requestResponse.statusCode, 431)
        requestBoundedServer.stop()

        let responseBoundedServer = try makeServer(maxResponseBytes: 1024)
        try responseBoundedServer.start()
        defer { responseBoundedServer.stop() }
        let largeURL = responseBoundedServer.baseURL.appendingPathComponent(
            "large-response.txt"
        )
        let (body, response) = try await fetch(largeURL)
        XCTAssertEqual(response.statusCode, 413)
        XCTAssertLessThan(body.count, 1024)
    }

    func testRejectsPercentEncodedTraversal() async throws {
        let server = try makeServer()
        try server.start()
        defer { server.stop() }

        let traversal = try XCTUnwrap(
            URL(
                string: server.baseURL.absoluteString +
                    "%2e%2e/%2e%2e/README.md"
            )
        )
        let (_, response) = try await fetch(traversal)
        XCTAssertEqual(response.statusCode, 403)
    }

    func testSelfSignedTLSRequiresExplicitTestTrust() async throws {
        let server = try ChromiumFixtureServer(
            fixtureDirectory:
                ChromiumFixtureServer.bundledFixtureDirectory(),
            tlsIdentity:
                ChromiumFixtureServer.bundledSelfSignedTLSIdentity()
        )
        try server.start()
        defer { server.stop() }

        XCTAssertEqual(server.baseURL.scheme, "https")
        do {
            _ = try await URLSession.shared.data(from: server.baseURL)
            XCTFail("The platform trusted the self-signed fixture")
        } catch let error as NSError {
            XCTAssertEqual(error.domain, NSURLErrorDomain)
            XCTAssertTrue([
                NSURLErrorSecureConnectionFailed,
                NSURLErrorServerCertificateUntrusted,
            ].contains(error.code))
        }

        let delegate = ChromiumFixtureTLSDelegate()
        let session = URLSession(
            configuration: .ephemeral,
            delegate: delegate,
            delegateQueue: nil
        )
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(from: server.baseURL)
        XCTAssertEqual(
            try XCTUnwrap(response as? HTTPURLResponse).statusCode,
            200
        )
        XCTAssertTrue(
            String(decoding: data, as: UTF8.self)
                .contains("Chromium fixture index")
        )
    }

    func testOpenSSLFixtureProvidesConventionalTLSPeer() async throws {
        let server = try ChromiumOpenSSLFixtureServer.bundled()
        try server.start()
        defer { server.stop() }

        do {
            _ = try await URLSession.shared.data(from: server.baseURL)
            XCTFail("The platform trusted the OpenSSL fixture")
        } catch let error as NSError {
            XCTAssertEqual(error.domain, NSURLErrorDomain)
            XCTAssertTrue([
                NSURLErrorSecureConnectionFailed,
                NSURLErrorServerCertificateUntrusted,
            ].contains(error.code))
        }

        let delegate = ChromiumFixtureTLSDelegate()
        let session = URLSession(
            configuration: .ephemeral,
            delegate: delegate,
            delegateQueue: nil
        )
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(from: server.baseURL)
        XCTAssertEqual(
            try XCTUnwrap(response as? HTTPURLResponse).statusCode,
            200
        )
        XCTAssertFalse(data.isEmpty)
    }

    func testShutdownClosesTheEphemeralListener() async throws {
        let server = try makeServer()
        try server.start()
        let stoppedURL = server.baseURL
        XCTAssertTrue(server.isRunning)

        server.stop()
        XCTAssertFalse(server.isRunning)

        var request = URLRequest(url: stoppedURL)
        request.timeoutInterval = 0.25
        request.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            _ = try await URLSession.shared.data(for: request)
            XCTFail("A stopped fixture server accepted a connection")
        } catch {
            XCTAssertFalse(server.isRunning)
        }
    }

    private func makeServer(
        maxRequestBytes: Int = 16 * 1024,
        maxResponseBytes: Int = 2 * 1024 * 1024
    ) throws -> ChromiumFixtureServer {
        try ChromiumFixtureServer(
            fixtureDirectory: ChromiumFixtureServer.bundledFixtureDirectory(),
            maxRequestBytes: maxRequestBytes,
            maxResponseBytes: maxResponseBytes
        )
    }

    private func fetch(
        _ url: URL
    ) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        return try await fetch(request)
    }

    private func fetch(
        _ request: URLRequest
    ) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, try XCTUnwrap(response as? HTTPURLResponse))
    }
}

private final class ChromiumFixtureTLSDelegate:
    NSObject,
    URLSessionDelegate,
    @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (
            URLSession.AuthChallengeDisposition,
            URLCredential?
        ) -> Void
    ) {
        _ = session
        guard challenge.protectionSpace.authenticationMethod
                == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust
        else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        completionHandler(
            .useCredential,
            URLCredential(trust: trust)
        )
    }
}
