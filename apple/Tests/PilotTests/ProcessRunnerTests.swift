import Foundation
import Testing
@testable import Pilot

@Suite("Bounded process runner", .serialized)
struct ProcessRunnerTests {
    @Test("Nonzero exits return structured status without leaking output")
    func nonzeroExit() async throws {
        let invocation = ProcessInvocation(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf secret-output >&2; exit 23"],
            timeout: .seconds(2),
            redactedArgumentIndexes: [1]
        )
        do {
            _ = try await ProcessRunner.run(invocation)
            Issue.record("Expected the child to fail")
        } catch let error as ProcessRunnerError {
            guard case .nonZeroExit(let result) = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
            #expect(result.termination == .exit(23))
            #expect(result.standardErrorString == "secret-output")
            #expect(error.localizedDescription.contains("<redacted>"))
            #expect(!error.localizedDescription.contains("secret-output"))
            #expect(!error.localizedDescription.contains("printf"))
        }
    }

    @Test("Deadline terminates a hung child")
    func hungChild() async throws {
        let started = ContinuousClock.now
        do {
            _ = try await ProcessRunner.run(ProcessInvocation(
                executableURL: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["10"],
                timeout: .milliseconds(100)
            ))
            Issue.record("Expected timeout")
        } catch let error as ProcessRunnerError {
            guard case .timedOut = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
            #expect(started.duration(to: .now) < .seconds(2))
        }
    }

    @Test("Signal-ignoring child is killed after the grace period")
    func signalIgnoringChild() async throws {
        let started = ContinuousClock.now
        do {
            _ = try await ProcessRunner.run(ProcessInvocation(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "trap '' TERM; while :; do sleep 1; done"],
                timeout: .milliseconds(100),
                terminationGracePeriod: .milliseconds(100)
            ))
            Issue.record("Expected timeout")
        } catch let error as ProcessRunnerError {
            guard case .timedOut(let result) = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
            #expect(result.termination == .signal(SIGKILL))
            #expect(started.duration(to: .now) < .seconds(2))
        }
    }

    @Test("Cancellation terminates the child")
    func cancellation() async throws {
        let task = Task {
            try await ProcessRunner.run(ProcessInvocation(
                executableURL: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["10"],
                timeout: .seconds(20)
            ))
        }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Expected cancellation")
        } catch let error as ProcessRunnerError {
            guard case .cancelled = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
        }
    }

    @Test("Blocking bridge observes cancellation from its calling task")
    func blockingBridgeCancellation() async throws {
        let started = ContinuousClock.now
        let task = Task.detached {
            try ProcessRunner.runBlocking(ProcessInvocation(
                executableURL: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["10"],
                timeout: .seconds(20)
            ))
        }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Expected cancellation")
        } catch let error as ProcessRunnerError {
            guard case .cancelled = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
            #expect(started.duration(to: .now) < .seconds(2))
        }
    }

    @Test("Both output streams drain concurrently and enforce caps")
    func largeOutput() async throws {
        let script = "i=0; while [ $i -lt 8000 ]; do printf 0123456789abcdef; printf fedcba9876543210 >&2; i=$((i+1)); done"
        do {
            _ = try await ProcessRunner.run(ProcessInvocation(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", script],
                timeout: .seconds(5),
                standardOutputLimit: 4_096,
                standardErrorLimit: 2_048
            ))
            Issue.record("Expected a truncation error")
        } catch let error as ProcessRunnerError {
            guard case .outputTruncated(let result) = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
            #expect(result.standardOutput.count == 4_096)
            #expect(result.standardError.count == 2_048)
            #expect(result.standardOutputTruncated)
            #expect(result.standardErrorTruncated)
        }
    }
}
