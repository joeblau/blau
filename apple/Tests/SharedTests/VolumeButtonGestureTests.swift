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

    @Test("holding Up immediately after Down ends recording and starts one execute hold")
    func immediateRecordToExecuteHandoff() {
        let start = ContinuousClock().now
        var classifier = VolumeGestureClassifier()
        _ = classifier.receive(.down, at: start)
        _ = classifier.receive(.down, at: start.advanced(by: .milliseconds(400)))
        _ = classifier.receive(.down, at: start.advanced(by: .milliseconds(500)))

        #expect(classifier.receive(
            .up, at: start.advanced(by: .milliseconds(600))
        ) == [.holdRepeated(.down)])
        #expect(classifier.receive(
            .up, at: start.advanced(by: .milliseconds(1_000))
        ) == [.holdEnded(.down)])
        #expect(classifier.receive(
            .up, at: start.advanced(by: .milliseconds(1_100))
        ) == [.holdStarted(.up)])
        #expect(classifier.receive(
            .up, at: start.advanced(by: .milliseconds(1_200))
        ) == [.holdRepeated(.up)])
    }

    @Test("rapid opposite taps after a hold remain navigation taps")
    func rapidTapsAfterHold() throws {
        let start = ContinuousClock().now
        var classifier = VolumeGestureClassifier()
        _ = classifier.receive(.down, at: start)
        _ = classifier.receive(.down, at: start.advanced(by: .milliseconds(400)))
        _ = classifier.receive(.down, at: start.advanced(by: .milliseconds(500)))
        _ = classifier.receive(.up, at: start.advanced(by: .milliseconds(600)))

        #expect(classifier.receive(
            .up, at: start.advanced(by: .milliseconds(700))
        ) == [.holdEnded(.down), .tap(.up)])
        let pending = try #require(classifier.pendingResolution)
        #expect(classifier.expirePending(token: pending.token) == [.tap(.up)])
        #expect(!classifier.isHolding)
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

    @Test("a resumed hardware repeat invalidates an in-flight release probe")
    func repeatDuringReleaseProbe() {
        var probe = VolumeHoldReleaseProbe()
        let first = probe.observedRepeat()
        #expect(probe.begin(first) == true)

        let resumed = probe.observedRepeat()
        #expect(probe.finish(first) == false)
        #expect(probe.begin(resumed) == true)
        #expect(probe.finish(resumed) == true)
        #expect(probe.finish(resumed) == false)
    }

    @Test("continuous repeats never start a stale release probe")
    func continuousRepeats() {
        var probe = VolumeHoldReleaseProbe()
        let earlier = probe.observedRepeat()
        let latest = probe.observedRepeat()

        #expect(probe.begin(earlier) == false)
        #expect(probe.finish(latest) == false)
        #expect(probe.begin(latest) == true)
        #expect(probe.finish(latest) == true)
    }

    @Test("stopping observation invalidates probes from the previous hold")
    func cancelledReleaseProbe() {
        var probe = VolumeHoldReleaseProbe()
        let cancelled = probe.observedRepeat()
        #expect(probe.begin(cancelled) == true)
        probe.reset()

        let restarted = probe.observedRepeat()
        #expect(probe.finish(cancelled) == false)
        #expect(probe.begin(cancelled) == false)
        #expect(probe.begin(restarted) == true)
        #expect(probe.finish(restarted) == true)
    }

    @Test("record, release, execute, and record again each produce one hold action")
    func successiveRecordingAndExecutionHolds() {
        let start = ContinuousClock().now
        var classifier = VolumeGestureClassifier()
        var probe = VolumeHoldReleaseProbe()

        for (index, direction) in [VolumeDirection.down, .up, .down].enumerated() {
            let press = start.advanced(by: .seconds(index * 2))
            #expect(classifier.receive(direction, at: press).isEmpty)
            #expect(classifier.receive(
                direction,
                at: press.advanced(by: .milliseconds(400))
            ).isEmpty)
            #expect(classifier.receive(
                direction,
                at: press.advanced(by: .milliseconds(500))
            ) == [.holdStarted(direction)])

            for repeatIndex in 1...3 {
                #expect(classifier.receive(
                    direction,
                    at: press.advanced(by: .milliseconds(500 + repeatIndex * 100))
                ) == [.holdRepeated(direction)])
            }

            let release = probe.observedRepeat()
            #expect(probe.begin(release) == true)
            #expect(probe.finish(release) == true)
            #expect(classifier.endHold() == .holdEnded(direction))
            #expect(classifier.endHold() == nil)
            #expect(classifier.pendingResolution == nil)
        }
    }

    @Test("leaving the workspace list discards unresolved navigation taps")
    func resetDiscardsPendingTaps() throws {
        let start = ContinuousClock().now
        var classifier = VolumeGestureClassifier()
        _ = classifier.receive(.down, at: start)
        let pending = try #require(classifier.pendingResolution)

        #expect(classifier.reset() == .none)
        #expect(classifier.expirePending(token: pending.token).isEmpty)
        #expect(classifier.pendingResolution == nil)
    }
}
