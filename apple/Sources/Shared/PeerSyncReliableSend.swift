import Foundation

/// Cancelling a queued command prevents transport submission. Once the SDK has
/// accepted the command, cancellation cannot recall it or change that result.
enum PeerSyncReliableSend {
    static func perform(
        on queue: DispatchQueue,
        send: @escaping @Sendable () -> Bool
    ) async -> Bool {
        let request = Request()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard request.install(continuation) else { return }
                queue.async { request.submit(send) }
            }
        } onCancel: {
            request.cancel()
        }
    }

    /// The lock owns the pending continuation and submission decision together.
    /// Submission stays inside that lock so cancellation cannot win between its
    /// final eligibility check and the synchronous SDK send.
    private final class Request: @unchecked Sendable {
        private let lock = NSLock()
        private var result: Bool?
        private var continuation: CheckedContinuation<Bool, Never>?

        func install(_ continuation: CheckedContinuation<Bool, Never>) -> Bool {
            let resolved = lock.withLock { () -> Bool? in
                if let result { return result }
                self.continuation = continuation
                return nil
            }
            if let resolved {
                continuation.resume(returning: resolved)
                return false
            }
            return true
        }

        func submit(_ send: () -> Bool) {
            let completion = lock.withLock { () -> (CheckedContinuation<Bool, Never>?, Bool)? in
                guard result == nil else { return nil }
                let accepted = send()
                result = accepted
                defer { continuation = nil }
                return (continuation, accepted)
            }
            if let (continuation, accepted) = completion {
                continuation?.resume(returning: accepted)
            }
        }

        func cancel() {
            let pending = lock.withLock { () -> CheckedContinuation<Bool, Never>? in
                guard result == nil else { return nil }
                result = false
                defer { continuation = nil }
                return continuation
            }
            pending?.resume(returning: false)
        }
    }
}
