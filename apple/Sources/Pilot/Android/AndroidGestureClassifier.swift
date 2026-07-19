import CoreGraphics
import Foundation

/// Classifies a completed mouse gesture into the Android `input` command that
/// best preserves its semantics. Pure and unit-testable.
///
/// Native adb input has no live event channel — every `input` invocation
/// replays a whole gesture — so the pane records the mouse gesture and replays
/// it on mouse-up. The classification preserves what matters:
/// - a quick stationary press is a tap;
/// - a held stationary press is a long-press (zero-motion swipe);
/// - a moving gesture is a swipe whose duration preserves fling velocity;
/// - a press that was *held* before moving is a drag-and-drop (grab, move,
///   release), which a plain swipe cannot express.
struct AndroidGestureClassifier {
    enum Gesture: Equatable {
        case tap(x: Int, y: Int)
        case longPress(x: Int, y: Int, durationMS: Int)
        case swipe(fromX: Int, fromY: Int, toX: Int, toY: Int, durationMS: Int)
        case dragAndDrop(fromX: Int, fromY: Int, toX: Int, toY: Int, durationMS: Int)
    }

    /// Movement below this (in device pixels) is "stationary".
    static let movementThreshold: CGFloat = 12
    /// A stationary press this long becomes a long-press.
    static let longPressThreshold: Duration = .milliseconds(400)
    /// Holding still this long before moving turns the gesture into a drag.
    static let dragHoldThreshold: Duration = .milliseconds(400)

    private var downPoint: CGPoint = .zero
    private var downAt: ContinuousClock.Instant?
    private var firstMoveAt: ContinuousClock.Instant?
    private var maxDistance: CGFloat = 0

    /// Begin a gesture at a device-pixel point.
    mutating func began(at point: CGPoint, time: ContinuousClock.Instant = .now) {
        downPoint = point
        downAt = time
        firstMoveAt = nil
        maxDistance = 0
    }

    mutating func moved(to point: CGPoint, time: ContinuousClock.Instant = .now) {
        guard downAt != nil else { return }
        let distance = hypot(point.x - downPoint.x, point.y - downPoint.y)
        maxDistance = max(maxDistance, distance)
        if firstMoveAt == nil, distance >= Self.movementThreshold {
            firstMoveAt = time
        }
    }

    /// End the gesture and classify it. Returns nil when no gesture began.
    mutating func ended(at point: CGPoint, time: ContinuousClock.Instant = .now) -> Gesture? {
        guard let downAt else { return nil }
        defer { self.downAt = nil }

        let duration = downAt.duration(to: time)
        let durationMS = Int(duration.components.seconds * 1_000
            + duration.components.attoseconds / 1_000_000_000_000_000)
        let fromX = Int(downPoint.x), fromY = Int(downPoint.y)
        let toX = Int(point.x), toY = Int(point.y)

        if maxDistance < Self.movementThreshold {
            if duration >= Self.longPressThreshold {
                return .longPress(x: fromX, y: fromY, durationMS: min(durationMS, 5_000))
            }
            return .tap(x: fromX, y: fromY)
        }

        let heldBeforeMoving = firstMoveAt.map { downAt.duration(to: $0) } ?? .zero
        if heldBeforeMoving >= Self.dragHoldThreshold {
            let moveMS = durationMS - Int(heldBeforeMoving.components.seconds * 1_000
                + heldBeforeMoving.components.attoseconds / 1_000_000_000_000_000)
            return .dragAndDrop(fromX: fromX, fromY: fromY, toX: toX, toY: toY,
                                durationMS: max(moveMS, 100))
        }
        return .swipe(fromX: fromX, fromY: fromY, toX: toX, toY: toY,
                      durationMS: min(max(durationMS, 50), 2_000))
    }

    /// The `input` line for a classified gesture.
    static func command(for gesture: Gesture) -> AndroidInputCommand {
        switch gesture {
        case .tap(let x, let y):
            .tap(x: x, y: y)
        case .longPress(let x, let y, let durationMS):
            .longPress(x: x, y: y, durationMS: durationMS)
        case .swipe(let fromX, let fromY, let toX, let toY, let durationMS):
            .swipe(fromX: fromX, fromY: fromY, toX: toX, toY: toY, durationMS: durationMS)
        case .dragAndDrop(let fromX, let fromY, let toX, let toY, let durationMS):
            .dragAndDrop(fromX: fromX, fromY: fromY, toX: toX, toY: toY, durationMS: durationMS)
        }
    }
}
