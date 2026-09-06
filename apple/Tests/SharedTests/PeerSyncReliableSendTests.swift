import Foundation
import Testing
@testable import Copilot

@Suite("Cancellable peer transport submission")
struct PeerSyncReliableSendTests {
    @Test("Cancelling a send on a suspended transport queue prevents SDK submission")
    func cancelledQueuedSendIsNeverSubmitted() async {
        let queue = DispatchQueue(label: "app.blau.tests.reliable-send.cancelled")
        let probe = ReliableSendProbe()
        let started = ReliableSendSignal()
        queue.suspend()
        let operation = Task {
            started.signal()
            return await PeerSyncReliableSend.perform(on: queue) {
                probe.recordSubmission()
                return true
            }
        }
        await started.wait()
        operation.cancel()
        queue.resume()

        #expect(!(await operation.value))
        await drain(queue)
        #expect(probe.submissionCount == 0)
    }

    @Test("A caller cancelled before registration never submits a command")
    func alreadyCancelledCallerIsNeverSubmitted() async {
        let queue = DispatchQueue(label: "app.blau.tests.reliable-send.pre-cancelled")
        let probe = ReliableSendProbe()
        let ready = ReliableSendSignal()
        let proceed = ReliableSendSignal()
        let operation = Task {
            ready.signal()
            await proceed.wait()
            return await PeerSyncReliableSend.perform(on: queue) {
                probe.recordSubmission()
                return true
            }
        }
        await ready.wait()
        operation.cancel()
        proceed.signal()

        #expect(!(await operation.value))
        await drain(queue)
        #expect(probe.submissionCount == 0)
    }

    @Test("Normal submission returns the SDK result exactly once", arguments: [false, true])
    func normalSubmissionReportsSDKResult(accepted: Bool) async {
        let queue = DispatchQueue(label: "app.blau.tests.reliable-send.normal")
        let probe = ReliableSendProbe()
        let result = await PeerSyncReliableSend.perform(on: queue) {
            probe.recordSubmission()
            return accepted
        }

        #expect(result == accepted)
        await drain(queue)
        #expect(probe.submissionCount == 1)
    }

    @Test("Cancellation cannot falsely recall a command accepted by the SDK")
    func cancellingAcceptedSendPreservesSuccess() async {
        let queue = DispatchQueue(label: "app.blau.tests.reliable-send.accepted")
        let probe = ReliableSendProbe()
        let accepted = ReliableSendSignal()
        let operation = Task {
            await PeerSyncReliableSend.perform(on: queue) {
                probe.recordSubmission()
                accepted.signal()
                return true
            }
        }
        await accepted.wait()
        operation.cancel()

        #expect(await operation.value)
        #expect(probe.submissionCount == 1)
    }

    private func drain(_ queue: DispatchQueue) async {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume() }
        }
    }
}

private final class ReliableSendProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var submissionCount: Int { lock.withLock { count } }

    func recordSubmission() {
        lock.withLock { count += 1 }
    }
}

private final class ReliableSendSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var isSignalled = false
    private var continuation: CheckedContinuation<Void, Never>?

    func signal() {
        let pending = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            isSignalled = true
            defer { continuation = nil }
            return continuation
        }
        pending?.resume()
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            let alreadySignalled = lock.withLock { () -> Bool in
                guard !isSignalled else { return true }
                self.continuation = continuation
                return false
            }
            if alreadySignalled { continuation.resume() }
        }
    }
}
