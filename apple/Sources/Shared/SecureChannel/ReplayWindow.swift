import Foundation

/// Per-direction anti-replay sliding window over the monotonic packet counter,
/// modelled on the RFC 6479 / IPsec ESP scheme.
///
/// The receiver tracks the highest counter seen plus a bitmap of the most
/// recent `size` counters. A packet is rejected if its counter is at or below
/// the bottom of the window (too old) or if its bit is already set (replayed).
/// Accepting a packet advances the window and sets its bit.
struct ReplayWindow {

    /// Window size in counters. The protocol spec mandates 1024.
    static let defaultSize: UInt64 = 1024

    private let size: UInt64
    /// Highest counter accepted so far; `nil` until the first accept.
    private var highest: UInt64?
    /// Set of accepted counters within `[highest - size + 1, highest]`.
    private var seen: Set<UInt64> = []

    init(size: UInt64 = ReplayWindow.defaultSize) {
        precondition(size > 0)
        self.size = size
    }

    /// Returns `true` and records the counter if it is fresh; returns `false`
    /// (and changes nothing) if it is a replay or below the window.
    mutating func accept(_ counter: UInt64) -> Bool {
        guard let high = highest else {
            highest = counter
            seen = [counter]
            return true
        }

        if counter > high {
            // Advance the window; drop counters that fall off the bottom.
            highest = counter
            seen.insert(counter)
            let bottom = counter >= size ? counter - size + 1 : 0
            seen = seen.filter { $0 >= bottom }
            return true
        }

        // Below the window bottom -> too old.
        let bottom = high >= size ? high - size + 1 : 0
        if counter < bottom { return false }

        // Inside the window: reject if already seen.
        if seen.contains(counter) { return false }
        seen.insert(counter)
        return true
    }
}
