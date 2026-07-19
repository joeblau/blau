import Foundation

/// Pure decision table for the mirror's restart supervisor. One instance lives
/// for the duration of a connection; every stream exit is reported here and the
/// policy answers restart-with-these-parameters or give-up. Separated from the
/// session so the whole recovery story is unit-testable.
///
/// Attempts carry a long-edge *cap*, not a concrete size: with an explicit
/// `--size` screenrecord scales into exactly those dimensions, so the session
/// must compute the size from the device's *currently oriented* display at
/// each spawn or a post-rotation respawn would encode distorted video.
///
/// The ladder handles two distinct instant-exit shapes:
/// - Old screenrecord builds reject `--time-limit 0` (Android 10 added it) →
///   drop the flag and rely on the 180 s auto-respawn.
/// - OEM encoders that refuse the capped-native `--size` → drop to a smaller
///   cap, still aspect-correct.
/// A stream that ran ≥ `healthyRuntime` before dying resets the strike count
/// (fresh, independent failure), mirroring `DeviceCaptureSession`'s thrash cap.
struct AndroidStreamPolicy: Equatable {
    struct Attempt: Equatable {
        /// Long-edge pixel cap for the encoded video; the session turns this
        /// into an oriented `--size` via `AdbBridge.cappedStreamSize`.
        var longEdgeCap: Int
        var timeLimitZero: Bool
    }

    enum Decision: Equatable {
        case restart(Attempt)
        case fail(String)
    }

    static let quickDeath: Duration = .seconds(2)
    static let healthyRuntime: Duration = .seconds(10)
    static let maxQuickFailures = 3

    private var rung = 0
    private var quickFailures = 0

    init() {}

    /// Parameters for the first launch of a connection.
    var firstAttempt: Attempt {
        Self.attempt(forRung: 0)
    }

    /// Parameters for a deliberate in-place restart (rotation, record-start):
    /// reuse what the ladder has learned instead of retrying rungs that
    /// already failed on this device.
    var currentAttempt: Attempt {
        Self.attempt(forRung: rung)
    }

    /// Decide what to do after a stream exit. `runtime` is how long the child
    /// lived; `diagnostics` is the bounded stderr tail (shown on give-up).
    mutating func nextDecision(runtime: Duration, diagnostics: String) -> Decision {
        if runtime >= Self.healthyRuntime {
            // A long-lived stream that ended is the 180 s cap, rotation, or a
            // genuine mid-flight failure: respawn with the proven parameters.
            quickFailures = 0
            return .restart(Self.attempt(forRung: rung))
        }
        quickFailures += 1
        if quickFailures > Self.maxQuickFailures {
            let detail = diagnostics.isEmpty ? "The device stopped the video stream repeatedly." : diagnostics
            return .fail(detail)
        }
        if runtime < Self.quickDeath, rung < 2 {
            rung += 1
        }
        return .restart(Self.attempt(forRung: rung))
    }

    private static func attempt(forRung rung: Int) -> Attempt {
        switch rung {
        case 0: Attempt(longEdgeCap: 1_600, timeLimitZero: true)
        case 1: Attempt(longEdgeCap: 1_600, timeLimitZero: false)
        default: Attempt(longEdgeCap: 1_280, timeLimitZero: false)
        }
    }
}
