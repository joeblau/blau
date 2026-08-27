import Foundation
import Testing
@testable import Copilot

@Suite("Walkie volume-button gestures")
struct VolumeButtonGestureTests {
    @Test("volume taps navigate in screen order and clamp at the ends")
    func workspaceNavigation() {
        #expect(VolumeListNavigation.nextIndex(from: nil, direction: .up, itemCount: 3) == 0)
        #expect(VolumeListNavigation.nextIndex(from: nil, direction: .down, itemCount: 3) == 0)
        #expect(VolumeListNavigation.nextIndex(from: 1, direction: .up, itemCount: 3) == 0)
        #expect(VolumeListNavigation.nextIndex(from: 1, direction: .down, itemCount: 3) == 2)
        #expect(VolumeListNavigation.nextIndex(from: 0, direction: .up, itemCount: 3) == 0)
        #expect(VolumeListNavigation.nextIndex(from: 2, direction: .down, itemCount: 3) == 2)
        #expect(VolumeListNavigation.nextIndex(from: 1, direction: .none, itemCount: 3) == 1)
        #expect(VolumeListNavigation.nextIndex(from: nil, direction: .down, itemCount: 0) == nil)
    }

    @Test("hold-down records and hold-up sends to the selected workspace")
    func holdActionMapping() {
        let workspaceID = UUID()

        #expect(CopilotVolumeHoldAction(
            direction: .down,
            selectedWorkspaceID: workspaceID
        ) == .record(workspaceID: workspaceID))
        #expect(CopilotVolumeHoldAction(
            direction: .up,
            selectedWorkspaceID: workspaceID
        ) == .send(workspaceID: workspaceID))
        #expect(CopilotVolumeHoldAction(
            direction: .none,
            selectedWorkspaceID: workspaceID
        ) == nil)
        #expect(CopilotVolumeHoldAction(
            direction: .down,
            selectedWorkspaceID: nil
        ) == .record(workspaceID: nil))
        #expect(CopilotVolumeHoldAction(
            direction: .up,
            selectedWorkspaceID: nil
        ) == .send(workspaceID: nil))
    }

    @Test("one event resolves as one tap in either direction")
    func singleTaps() throws {
        let start = ContinuousClock().now

        var up = VolumeGestureClassifier()
        #expect(up.receive(.up, at: start).isEmpty)
        let upPending = try #require(up.pendingResolution)
        #expect(up.expirePending(token: upPending.token) == [.tap(.up)])

        var down = VolumeGestureClassifier()
        #expect(down.receive(.down, at: start).isEmpty)
        let downPending = try #require(down.pendingResolution)
        #expect(down.expirePending(token: downPending.token) == [.tap(.down)])
    }

    @Test("rapid same-direction double taps never become a hold")
    func rapidDoubleTap() throws {
        let start = ContinuousClock().now
        var classifier = VolumeGestureClassifier()

        #expect(classifier.receive(.down, at: start).isEmpty)
        #expect(classifier.receive(
            .down,
            at: start.advanced(by: .milliseconds(100))
        ) == [.tap(.down)])
        #expect(!classifier.isHolding)

        let pending = try #require(classifier.pendingResolution)
        #expect(classifier.expirePending(token: pending.token) == [.tap(.down)])
    }

    @Test("opposite-direction taps never become a hold")
    func alternatingTaps() throws {
        let start = ContinuousClock().now
        var classifier = VolumeGestureClassifier()

        #expect(classifier.receive(.up, at: start).isEmpty)
        #expect(classifier.receive(
            .down,
            at: start.advanced(by: .milliseconds(400))
        ) == [.tap(.up)])
        #expect(!classifier.isHolding)

        let pending = try #require(classifier.pendingResolution)
        #expect(classifier.expirePending(token: pending.token) == [.tap(.down)])
    }

    @Test("two deliberate taps remain taps even at the initial-repeat cadence")
    func deliberateDoubleTap() throws {
        let start = ContinuousClock().now
        var classifier = VolumeGestureClassifier()

        #expect(classifier.receive(.up, at: start).isEmpty)
        #expect(classifier.receive(
            .up,
            at: start.advanced(by: .milliseconds(400))
        ).isEmpty)

        let pending = try #require(classifier.pendingResolution)
        #expect(classifier.expirePending(token: pending.token) == [.tap(.up), .tap(.up)])
        #expect(!classifier.isHolding)
    }

    @Test("down auto-repeat starts, continues, and ends a down hold")
    func downHoldLifecycle() {
        let start = ContinuousClock().now
        var classifier = VolumeGestureClassifier()

        #expect(classifier.receive(.down, at: start).isEmpty)
        #expect(classifier.receive(
            .down,
            at: start.advanced(by: .milliseconds(400))
        ).isEmpty)
        #expect(classifier.receive(
            .down,
            at: start.advanced(by: .milliseconds(500))
        ) == [.holdStarted(.down)])
        #expect(classifier.isHolding)
        #expect(classifier.heldDirection == .down)
        #expect(classifier.receive(
            .down,
            at: start.advanced(by: .milliseconds(600))
        ) == [.holdRepeated(.down)])
        #expect(classifier.endHold() == .holdEnded(.down))
        #expect(!classifier.isHolding)
    }

    @Test("up auto-repeat starts and ends an up hold")
    func upHoldLifecycle() {
        let start = ContinuousClock().now
        var classifier = VolumeGestureClassifier()

        #expect(classifier.receive(.up, at: start).isEmpty)
        #expect(classifier.receive(
            .up,
            at: start.advanced(by: .milliseconds(425))
        ).isEmpty)
        #expect(classifier.receive(
            .up,
            at: start.advanced(by: .milliseconds(525))
        ) == [.holdStarted(.up)])
        #expect(classifier.endHold() == .holdEnded(.up))
    }

    @Test("a mismatched third event flushes taps instead of starting a hold")
    func mismatchedThirdEvent() throws {
        let start = ContinuousClock().now
        var classifier = VolumeGestureClassifier()

        #expect(classifier.receive(.up, at: start).isEmpty)
        #expect(classifier.receive(
            .up,
            at: start.advanced(by: .milliseconds(400))
        ).isEmpty)
        #expect(classifier.receive(
            .down,
            at: start.advanced(by: .milliseconds(500))
        ) == [.tap(.up), .tap(.up)])
        #expect(!classifier.isHolding)

        let pending = try #require(classifier.pendingResolution)
        #expect(classifier.expirePending(token: pending.token) == [.tap(.down)])
    }

    @Test("an active hold keeps its original direction")
    func activeHoldKeepsDirection() {
        let start = ContinuousClock().now
        var classifier = VolumeGestureClassifier()

        _ = classifier.receive(.down, at: start)
        _ = classifier.receive(.down, at: start.advanced(by: .milliseconds(400)))
        _ = classifier.receive(.down, at: start.advanced(by: .milliseconds(500)))

        #expect(classifier.receive(
            .up,
            at: start.advanced(by: .milliseconds(600))
        ) == [.holdRepeated(.down)])
        #expect(classifier.isHolding)
        #expect(classifier.endHold() == .holdEnded(.down))
    }

    @Test("stale resolution tasks cannot consume a newer gesture")
    func staleResolutionToken() throws {
        let start = ContinuousClock().now
        var classifier = VolumeGestureClassifier()

        _ = classifier.receive(.up, at: start)
        let stale = try #require(classifier.pendingResolution)
        _ = classifier.receive(.down, at: start.advanced(by: .milliseconds(100)))
        let current = try #require(classifier.pendingResolution)

        #expect(classifier.expirePending(token: stale.token).isEmpty)
        #expect(classifier.expirePending(token: current.token) == [.tap(.down)])
    }
}
