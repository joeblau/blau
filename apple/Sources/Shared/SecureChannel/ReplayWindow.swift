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

    /// Number of counters retained for replay decisions. This never exceeds
    /// the configured window size and is useful for bounded-memory diagnostics.
    var retainedCount: Int { seen.count }

    init(size: UInt64 = ReplayWindow.defaultSize) {
        precondition(size > 0 && size <= UInt64.max / 2)
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

        if counter == high { return false }

        // RFC 1982-style serial arithmetic: a small wrapping subtraction means
        // `counter` is ahead, including UInt64.max -> 0 rollover. A difference
        // of half the sequence space or more is treated as old.
        let forwardDistance = counter &- high
        if forwardDistance < (UInt64.max / 2 + 1) {
            highest = counter
            seen.insert(counter)
            seen = seen.filter { counter &- $0 < size }
            return true
        }

        // Behind the window bottom -> too old.
        if high &- counter >= size { return false }

        // Inside the window: reject if already seen.
        if seen.contains(counter) { return false }
        seen.insert(counter)
        return true
    }

    func contains(_ counter: UInt64) -> Bool { seen.contains(counter) }
}
