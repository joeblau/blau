import Foundation
import Testing
@testable import Pilot

@Suite("Repository polling scheduler", .serialized)
struct RepositoryPollingSchedulerTests {
    @Test("Remote URL forms resolve to the same canonical identity")
    func canonicalRemote() {
        let expected = "github.com/openai/codex"
        #expect(CanonicalRepository.normalizeRemote("git@github.com:OpenAI/Codex.git") == expected)
        #expect(CanonicalRepository.normalizeRemote("ssh://git@github.com/OpenAI/Codex.git") == expected)
        #expect(CanonicalRepository.normalizeRemote("https://github.com/OpenAI/Codex.git") == expected)
    }

    @Test("Duplicate repositories coalesce a slow command")
    func duplicateRepositoryCoalescing() async throws {
        let probe = PollingProbe(delay: .milliseconds(100), response: Data("[]".utf8))
        let scheduler = RepositoryPollingScheduler(jitter: { 0.5 }) { command in
            try await probe.execute(command)
        }
        let first = Self.repository(id: "github.com/example/project", path: "/tmp/checkout-a")
        let duplicate = Self.repository(id: "github.com/example/project", path: "/tmp/checkout-b")

        async let a = scheduler.data(for: .workflowRuns, repository: first)
        async let b = scheduler.data(for: .workflowRuns, repository: duplicate)
        _ = try await (a, b)

        #expect(await probe.commandCount == 1)
        #expect(await scheduler.metrics.coalescedRequests == 1)
    }

    @Test("Different worktrees do not share checkout-local commit data")
    func separateWorktreeCommitCaches() async throws {
        let probe = PollingProbe(response: Data("commits".utf8))
        let scheduler = RepositoryPollingScheduler(jitter: { 0.5 }) { command in
            try await probe.execute(command)
        }
        let first = Self.repository(id: "github.com/example/project", path: "/tmp/worktree-a")
        let second = Self.repository(id: "github.com/example/project", path: "/tmp/worktree-b")

        _ = try await scheduler.data(for: .commits, repository: first)
        _ = try await scheduler.data(for: .commits, repository: second)

        #expect(await probe.commandCount == 2)
        #expect(await scheduler.metrics.cacheHits == 0)
        #expect(await scheduler.metrics.coalescedRequests == 0)
    }

    @Test("Many repositories respect the global GitHub process limit")
    func concurrencyLimit() async throws {
        let probe = PollingProbe(delay: .milliseconds(80), response: Data("[]".utf8))
        let scheduler = RepositoryPollingScheduler(
            maximumConcurrentGitHubCommands: 2,
            jitter: { 0.5 }
        ) { command in
            try await probe.execute(command)
        }

        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<8 {
                group.addTask {
                    _ = try await scheduler.data(
                        for: .issues,
                        repository: Self.repository(
                            id: "github.com/example/project-\(index)",
                            path: "/tmp/project-\(index)"
                        )
                    )
                }
            }
            try await group.waitForAll()
        }

        #expect(await probe.maximumActive == 2)
        #expect(await probe.commandCount == 8)
    }

    @Test("Background polling slows down while manual refresh bypasses cache")
    func backgroundAndManualRefresh() async throws {
        let clock = TestDateClock()
        let probe = PollingProbe(response: Data("[]".utf8))
        let scheduler = RepositoryPollingScheduler(
            now: { clock.now },
            jitter: { 0.5 }
        ) { command in
            try await probe.execute(command)
        }
        let repo = Self.repository(id: "github.com/example/background", path: "/tmp/background")

        _ = try await scheduler.data(for: .issues, repository: repo)
        clock.advance(by: 60)
        await scheduler.setEnvironment(applicationActive: false)
        _ = try await scheduler.data(for: .issues, repository: repo)
        #expect(await probe.commandCount == 1)

        _ = try await scheduler.data(for: .issues, repository: repo, policy: .manual)
        #expect(await probe.commandCount == 2)
    }

    @Test("Failure backs off automatic calls but manual refresh still runs")
    func failureBackoff() async throws {
        let clock = TestDateClock()
        let probe = PollingProbe(error: PollingTestError.failed)
        let scheduler = RepositoryPollingScheduler(
            now: { clock.now },
            jitter: { 0.5 }
        ) { command in
            try await probe.execute(command)
        }
        let repo = Self.repository(id: "github.com/example/failure", path: "/tmp/failure")

        await #expect(throws: PollingTestError.self) {
            _ = try await scheduler.data(for: .workflowRuns, repository: repo)
        }
        await #expect(throws: RepositoryPollingError.self) {
            _ = try await scheduler.data(for: .workflowRuns, repository: repo)
        }
        #expect(await probe.commandCount == 1)

        await #expect(throws: PollingTestError.self) {
            _ = try await scheduler.data(
                for: .workflowRuns,
                repository: repo,
                policy: .manual
            )
        }
        #expect(await probe.commandCount == 2)
        #expect(await scheduler.metrics.failures == 2)
    }

    @Test("Offline automatic requests pause without blocking manual refresh")
    func offline() async throws {
        let probe = PollingProbe(response: Data("[]".utf8))
        let scheduler = RepositoryPollingScheduler(jitter: { 0.5 }) { command in
            try await probe.execute(command)
        }
        let repo = Self.repository(id: "github.com/example/offline", path: "/tmp/offline")
        await scheduler.setEnvironment(networkAvailable: false)

        await #expect(throws: RepositoryPollingError.self) {
            _ = try await scheduler.data(for: .issues, repository: repo)
        }
        #expect(await probe.commandCount == 0)

        _ = try await scheduler.data(for: .issues, repository: repo, policy: .manual)
        #expect(await probe.commandCount == 1)
    }

    private static func repository(id: String, path: String) -> CanonicalRepository {
        CanonicalRepository(
            id: id,
            rootURL: URL(fileURLWithPath: path, isDirectory: true),
            remote: id
        )
    }
}

private enum PollingTestError: Error {
    case failed
}

private actor PollingProbe {
    private let delay: Duration
    private let response: Data
    private let error: Error?
    private(set) var commandCount = 0
    private(set) var active = 0
    private(set) var maximumActive = 0

    init(
        delay: Duration = .zero,
        response: Data = Data(),
        error: Error? = nil
    ) {
        self.delay = delay
        self.response = response
        self.error = error
    }

    func execute(_ command: RepositoryPollCommand) async throws -> Data {
        _ = command
        commandCount += 1
        active += 1
        maximumActive = max(maximumActive, active)
        defer { active -= 1 }
        if delay > .zero { try await Task.sleep(for: delay) }
        if let error { throw error }
        return response
    }
}

private final class TestDateClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 1_000)

    var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func advance(by interval: TimeInterval) {
        lock.lock()
        value.addTimeInterval(interval)
        lock.unlock()
    }
}
