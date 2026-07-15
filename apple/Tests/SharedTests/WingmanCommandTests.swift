import Foundation
import Testing
@testable import Copilot

@Suite("Wingman ephemeral commands")
struct WingmanCommandTests {
    private let now = Date(timeIntervalSince1970: 10_000)

    @Test("fresh commands execute once and reply-loss retries are acknowledged")
    func freshAndDuplicate() {
        var ledger = WingmanCommandLedger()
        let command = WingmanGesturePayload.Command(id: UUID(), sentAt: now)
        #expect(ledger.decide(command, now: now, isPilotConnected: true) == .acceptAndExecute)
        #expect(ledger.decide(command, now: now.addingTimeInterval(0.2), isPilotConnected: true)
            == .acknowledgeDuplicate)
    }

    @Test("stale and timed-out commands are rejected")
    func staleAndTimeout() {
        var ledger = WingmanCommandLedger()
        let stale = WingmanGesturePayload.Command(
            id: UUID(),
            sentAt: now.addingTimeInterval(-WingmanGesturePayload.maximumAge - 0.001)
        )
        #expect(ledger.decide(stale, now: now, isPilotConnected: true) == .rejectStale)
    }

    @Test("a disconnected command is not queued and may only execute on a fresh live retry")
    func reconnect() {
        var ledger = WingmanCommandLedger()
        let command = WingmanGesturePayload.Command(id: UUID(), sentAt: now)
        #expect(ledger.decide(command, now: now, isPilotConnected: false) == .rejectUnavailable)
        #expect(ledger.decide(command, now: now.addingTimeInterval(1), isPilotConnected: true)
            == .acceptAndExecute)

        let expired = WingmanGesturePayload.Command(id: UUID(), sentAt: now)
        #expect(ledger.decide(
            expired,
            now: now.addingTimeInterval(WingmanGesturePayload.maximumAge + 0.1),
            isPilotConnected: true
        ) == .rejectStale)
    }

    @Test("payload identity is mandatory")
    func malformedPayloads() {
        #expect(WingmanGesturePayload.command(from: [
            "gesture": WingmanGesturePayload.doublePinch,
            "sentAt": now.timeIntervalSince1970
        ]) == nil)
        let id = UUID()
        let command = WingmanGesturePayload.command(from: [
            "gesture": WingmanGesturePayload.doublePinch,
            "commandID": id.uuidString,
            "sentAt": now.timeIntervalSince1970
        ])
        #expect(command?.id == id)
    }

    @Test("timeout and error callbacks can claim only one same-ID retry")
    func retryCallbacksAreGenerationBound() {
        var state = WingmanDeliveryState()
        let id = UUID()
        let began = state.begin(commandID: id)
        #expect(began)

        let timeout = state.decideRetry(
            commandID: id,
            attempt: 0,
            sentAt: now,
            now: now.addingTimeInterval(2),
            isReachable: true
        )
        let lateError = state.decideRetry(
            commandID: id,
            attempt: 0,
            sentAt: now,
            now: now.addingTimeInterval(2.1),
            isReachable: true
        )

        #expect(timeout == .retry(attempt: 1))
        #expect(lateError == .ignoreStaleCallback)
        #expect(state.commandID == id)
        #expect(state.attempt == 1)
    }

    @Test("reply-loss retry is bounded and completion clears the command")
    func replyLossRetryIsBounded() {
        var state = WingmanDeliveryState()
        let id = UUID()
        let began = state.begin(commandID: id)
        let firstRetry = state.decideRetry(
            commandID: id,
            attempt: 0,
            sentAt: now,
            now: now.addingTimeInterval(2),
            isReachable: true
        )
        let secondRetry = state.decideRetry(
            commandID: id,
            attempt: 1,
            sentAt: now,
            now: now.addingTimeInterval(2.5),
            isReachable: true
        )
        let finished = state.finish(commandID: id, attempt: 1, accepted: false)
        #expect(began)
        #expect(firstRetry == .retry(attempt: 1))
        #expect(secondRetry == .fail)
        #expect(finished)
        #expect(!state.isInFlight)
    }

    @Test("a stale rejected reply cannot clear the current retry")
    func staleRejectedReplyIsIgnored() {
        var state = WingmanDeliveryState()
        let id = UUID()
        let began = state.begin(commandID: id)
        let retry = state.decideRetry(
            commandID: id,
            attempt: 0,
            sentAt: now,
            now: now.addingTimeInterval(2),
            isReachable: true
        )
        let staleRejectionFinished = state.finish(commandID: id, attempt: 0, accepted: false)

        #expect(began)
        #expect(retry == .retry(attempt: 1))
        #expect(!staleRejectionFinished)
        #expect(state.isCurrent(commandID: id, attempt: 1))
    }

    @Test("a late accepted reply completes the command across retry generations")
    func lateAcceptedReplyFinishesSuccess() {
        var state = WingmanDeliveryState()
        let id = UUID()
        let began = state.begin(commandID: id)
        let retry = state.decideRetry(
            commandID: id,
            attempt: 0,
            sentAt: now,
            now: now.addingTimeInterval(2),
            isReachable: true
        )
        let lateAcceptanceFinished = state.finish(commandID: id, attempt: 0, accepted: true)

        #expect(began)
        #expect(retry == .retry(attempt: 1))
        #expect(lateAcceptanceFinished)
        #expect(!state.isInFlight)
    }
}
