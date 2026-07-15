import Foundation

enum SecureChannelAttemptError: Error, Equatable, LocalizedError {
    case socketReadinessTimedOut
    case handshakeTimedOut

    var errorDescription: String? {
        switch self {
        case .socketReadinessTimedOut:
            "UDP socket readiness timed out; retry the connection."
        case .handshakeTimedOut:
            "Secure handshake timed out; retry the connection."
        }
    }
}

/// Races an async operation against a monotonic deadline and cancels the loser.
/// The operation must honor task cancellation, as Network continuations do via
/// the cancellation handlers in the secure-channel transports.
enum SecureChannelDeadline {
    static func run<T: Sendable>(
        timeout: Duration,
        timeoutError: SecureChannelAttemptError,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw timeoutError
            }

            guard let result = try await group.next() else {
                throw CancellationError()
            }
            group.cancelAll()
            return result
        }
    }
}

/// Pure retry schedule shared by production and tests. Attempt zero is sent
/// immediately; subsequent attempts are spaced evenly until the deadline.
struct HandshakeRetrySchedule: Equatable {
    let interval: Duration
    let timeout: Duration

    init(interval: Duration = .milliseconds(500), timeout: Duration = .seconds(8)) {
        precondition(interval > .zero && timeout > interval)
        self.interval = interval
        self.timeout = timeout
    }
}

/// Remembers the authenticated msg1/msg2 pair so a responder can recover from
/// a lost UDP reply without running the handshake twice or accepting a
/// different request after keys have been established.
struct HandshakeResponseCache {
    private var request: Data?
    private var response: Data?

    mutating func record(request: Data, response: Data) {
        self.request = request
        self.response = response
    }

    func response(for request: Data) -> Data? {
        guard request == self.request else { return nil }
        return response
    }

    mutating func reset() {
        request = nil
        response = nil
    }
}
