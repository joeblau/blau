import Foundation

struct WingmanDeliveryRetryPolicy {
    static let replyTimeout: Duration = .seconds(2)
    static let maximumAge: TimeInterval = 3
    static let maximumAttempts = 2

    static func shouldRetry(attempt: Int, sentAt: Date, now: Date, isReachable: Bool) -> Bool {
        attempt + 1 < maximumAttempts
            && isReachable
            && now.timeIntervalSince(sentAt) >= -1
            && now.timeIntervalSince(sentAt) <= maximumAge
    }
}

enum WingmanRetryDecision: Equatable {
    case retry(attempt: Int)
    case ignoreStaleCallback
    case fail
}

/// Tracks the single live Watch command and lets exactly one callback claim
/// each retry generation. A timeout and an error callback for the same send can
/// race, but only the first advances the attempt.
struct WingmanDeliveryState {
    private(set) var commandID: UUID?
    private(set) var attempt: Int?

    var isInFlight: Bool { commandID != nil }

    mutating func begin(commandID: UUID) -> Bool {
        guard self.commandID == nil else { return false }
        self.commandID = commandID
        attempt = 0
        return true
    }

    func isCurrent(commandID: UUID, attempt: Int) -> Bool {
        self.commandID == commandID && self.attempt == attempt
    }

    mutating func decideRetry(
        commandID: UUID,
        attempt: Int,
        sentAt: Date,
        now: Date,
        isReachable: Bool
    ) -> WingmanRetryDecision {
        guard isCurrent(commandID: commandID, attempt: attempt) else {
            return .ignoreStaleCallback
        }
        guard WingmanDeliveryRetryPolicy.shouldRetry(
            attempt: attempt,
            sentAt: sentAt,
            now: now,
            isReachable: isReachable
        ) else {
            return .fail
        }
        let nextAttempt = attempt + 1
        self.attempt = nextAttempt
        return .retry(attempt: nextAttempt)
    }

    /// Accepted replies prove that Copilot executed this command and may finish
    /// it even if they arrive from an earlier attempt. Rejected replies carry
    /// no such proof and may finish only the attempt that is still current.
    mutating func finish(commandID: UUID, attempt: Int, accepted: Bool) -> Bool {
        guard self.commandID == commandID else { return false }
        guard accepted || self.attempt == attempt else { return false }
        self.commandID = nil
        self.attempt = nil
        return true
    }
}
