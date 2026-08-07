import Foundation
import Testing
@testable import Pilot

/// The Docker socket is a local endpoint any process on the machine could be
/// standing in for, so the response reader is treated as a parser of untrusted
/// input: framing bugs must surface as errors, and no payload may allocate past
/// its ceiling.
@Suite("Docker HTTP response framing")
struct DockerHTTPParsingTests {
    private func parser(maxBody: Int = 8 * 1024 * 1024) -> DockerHTTPResponseParser {
        DockerHTTPResponseParser(maxBodyBytes: maxBody)
    }

    @Test("Content-Length bodies decode and complete")
    func fixedLengthBody() throws {
        var subject = parser()
        let raw = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 7\r\n\r\n[1,2,3]"
        let body = try subject.consume(Data(raw.utf8))

        #expect(subject.statusCode == 200)
        #expect(subject.headers["content-type"] == "application/json")
        #expect(subject.framing == .contentLength(7))
        #expect(subject.isBodyComplete)
        #expect(String(decoding: body, as: UTF8.self) == "[1,2,3]")
    }

    @Test("Chunked bodies are de-chunked across reads")
    func chunkedBodySplitAcrossReads() throws {
        var subject = parser()
        // The head, a chunk cut mid-payload, and the terminal chunk each arrive
        // in their own read — the shape a real socket produces.
        var collected = Data()
        collected += try subject.consume(Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhel".utf8))
        #expect(subject.statusCode == 200)
        #expect(subject.framing == .chunked)
        #expect(!subject.isBodyComplete)

        collected += try subject.consume(Data("lo\r\n6\r\n world\r\n".utf8))
        collected += try subject.consume(Data("0\r\n\r\n".utf8))

        #expect(subject.isBodyComplete)
        #expect(String(decoding: collected, as: UTF8.self) == "hello world")
    }

    @Test("Chunk extensions are ignored")
    func chunkExtensionsIgnored() throws {
        var subject = parser()
        let raw = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n3;name=value\r\nabc\r\n0\r\n\r\n"
        let body = try subject.consume(Data(raw.utf8))
        #expect(String(decoding: body, as: UTF8.self) == "abc")
        #expect(subject.isBodyComplete)
    }

    @Test("A bodiless 204 completes immediately")
    func noContentCompletes() throws {
        var subject = parser()
        let body = try subject.consume(Data("HTTP/1.1 204 No Content\r\n\r\n".utf8))
        #expect(subject.statusCode == 204)
        #expect(subject.isBodyComplete)
        #expect(body.isEmpty)
    }

    @Test("A body with no length ends at EOF")
    func untilCloseEndsOnEOF() throws {
        var subject = parser()
        let body = try subject.consume(Data("HTTP/1.1 200 OK\r\n\r\npartial".utf8))
        #expect(subject.framing == .untilClose)
        #expect(!subject.isBodyComplete)
        #expect(String(decoding: body, as: UTF8.self) == "partial")

        try subject.finishOnEOF()
        #expect(subject.isBodyComplete)
    }

    @Test("EOF mid-body on a counted response is an error")
    func truncatedFixedLengthBodyFails() throws {
        var subject = parser()
        _ = try subject.consume(Data("HTTP/1.1 200 OK\r\nContent-Length: 64\r\n\r\nshort".utf8))
        #expect(!subject.isBodyComplete)
        #expect(throws: DockerTransportError.self) { try subject.finishOnEOF() }
    }

    @Test("A garbled status line is rejected rather than guessed at")
    func malformedStatusLineFails() {
        var subject = parser()
        #expect(throws: DockerTransportError.self) {
            _ = try subject.consume(Data("NOT-HTTP nonsense\r\n\r\nbody".utf8))
        }
    }

    @Test("An unparseable chunk size is rejected")
    func malformedChunkSizeFails() {
        var subject = parser()
        #expect(throws: DockerTransportError.self) {
            _ = try subject.consume(Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nzz\r\nabc\r\n".utf8))
        }
    }

    @Test("A declared Content-Length past the ceiling is refused before allocating")
    func oversizedContentLengthRefused() {
        var subject = parser(maxBody: 1024)
        #expect(throws: DockerTransportError.self) {
            _ = try subject.consume(Data("HTTP/1.1 200 OK\r\nContent-Length: 99999\r\n\r\n".utf8))
        }
    }

    @Test("A chunked body that streams past the ceiling is cut off")
    func oversizedChunkedBodyRefused() {
        var subject = parser(maxBody: 16)
        let payload = String(repeating: "x", count: 32)
        #expect(throws: DockerTransportError.self) {
            _ = try subject.consume(Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n20\r\n\(payload)\r\n".utf8))
        }
    }

    @Test("A head that never terminates is bounded")
    func oversizedHeaderRefused() {
        var subject = DockerHTTPResponseParser(maxHeaderBytes: 128, maxBodyBytes: 1024)
        let flood = "HTTP/1.1 200 OK\r\nX-Pad: " + String(repeating: "a", count: 512)
        #expect(throws: DockerTransportError.self) {
            _ = try subject.consume(Data(flood.utf8))
        }
    }

    @Test("Requests serialize as HTTP/1.1 with a body length when one is present")
    func requestSerialization() {
        let request = DockerRequest(method: "POST", path: "/v1.43/containers/abc/stop?t=10")
        let text = String(decoding: request.serialized(), as: UTF8.self)
        #expect(text.hasPrefix("POST /v1.43/containers/abc/stop?t=10 HTTP/1.1\r\n"))
        #expect(text.contains("Host: docker\r\n"))
        #expect(text.contains("Connection: close\r\n"))
        #expect(!text.contains("Content-Length"))
        #expect(text.hasSuffix("\r\n\r\n"))

        let withBody = DockerRequest(method: "POST", path: "/x", body: Data("{}".utf8))
        let bodyText = String(decoding: withBody.serialized(), as: UTF8.self)
        #expect(bodyText.contains("Content-Length: 2\r\n"))
        #expect(bodyText.hasSuffix("\r\n\r\n{}"))
    }

    @Test("Daemon text is stripped of control characters and bounded")
    func sanitizesDaemonText() {
        #expect(UntrustedText.sanitized("web\u{0007}\nserver", limit: 40) == "webserver")
        #expect(UntrustedText.sanitized(String(repeating: "n", count: 50), limit: 10) == String(repeating: "n", count: 10) + "…")
    }

    @Test("Failure bodies prefer Docker's JSON message")
    func failureMessageDecoding() {
        let json = DockerResponse(status: 409, body: Data(#"{"message":"container already started"}"#.utf8))
        #expect(json.failureMessage == "container already started")
        #expect(!json.isSuccess)

        let plain = DockerResponse(status: 500, body: Data("boom".utf8))
        #expect(plain.failureMessage == "boom")
    }
}

@Suite("Docker socket discovery")
struct DockerSocketLocatorTests {
    @Test("DOCKER_HOST takes priority when it names a Unix socket")
    func dockerHostWins() {
        let candidates = DockerSocketLocator.candidates(
            environment: ["DOCKER_HOST": "unix:///Users/me/.colima/custom/docker.sock"],
            home: "/Users/me"
        )
        #expect(candidates.first == "/Users/me/.colima/custom/docker.sock")
    }

    @Test("Remote DOCKER_HOST values are ignored — this section is local-only")
    func remoteDockerHostIgnored() {
        #expect(DockerSocketLocator.unixPath(fromDockerHost: "tcp://10.0.0.5:2375") == nil)
        #expect(DockerSocketLocator.unixPath(fromDockerHost: "ssh://user@host") == nil)
        #expect(DockerSocketLocator.unixPath(fromDockerHost: "unix:///var/run/docker.sock") == "/var/run/docker.sock")
        #expect(DockerSocketLocator.unixPath(fromDockerHost: "/var/run/docker.sock") == "/var/run/docker.sock")
    }

    @Test("The default search covers the engines a Mac is likely to be running")
    func defaultCandidates() {
        let candidates = DockerSocketLocator.candidates(environment: [:], home: "/Users/me")
        #expect(candidates.contains("/Users/me/.docker/run/docker.sock"))
        #expect(candidates.contains("/var/run/docker.sock"))
        #expect(candidates.contains("/Users/me/.colima/default/docker.sock"))
        #expect(candidates.contains("/Users/me/.rd/docker.sock"))
        #expect(candidates.count == Set(candidates).count)
    }

    @Test("Paths past the AF_UNIX length limit are rejected, not handed to Network")
    func rejectsUnusablePaths() {
        // `NWEndpoint.unix(path:)` takes an over-long path without complaint and
        // then produces a connection that reports no state at all — the async
        // read path traps on it. 104 bytes is `sockaddr_un.sun_path`.
        #expect(DockerSocketLocator.maxSocketPathBytes == 104)
        #expect(DockerSocketLocator.isUsablePath("/var/run/docker.sock"))
        #expect(DockerSocketLocator.isUsablePath("/" + String(repeating: "a", count: 103)))
        #expect(!DockerSocketLocator.isUsablePath("/" + String(repeating: "a", count: 104)))
        #expect(!DockerSocketLocator.isUsablePath("relative/docker.sock"))
        #expect(!DockerSocketLocator.isUsablePath(""))
    }

    @Test("An unusable candidate is skipped even when it exists")
    func resolutionSkipsUnusableCandidates() {
        let tooLong = "/" + String(repeating: "a", count: 200)
        let resolved = DockerSocketLocator.resolve(
            environment: ["DOCKER_HOST": "unix://\(tooLong)"],
            home: "/Users/me",
            exists: { $0 == tooLong || $0 == "/var/run/docker.sock" }
        )
        #expect(resolved == "/var/run/docker.sock")
    }

    @Test("Resolution picks the first candidate that exists")
    func resolvesFirstExisting() {
        let resolved = DockerSocketLocator.resolve(
            environment: [:],
            home: "/Users/me",
            exists: { $0 == "/var/run/docker.sock" }
        )
        #expect(resolved == "/var/run/docker.sock")
        #expect(DockerSocketLocator.resolve(environment: [:], home: "/Users/me", exists: { _ in false }) == nil)
    }
}
