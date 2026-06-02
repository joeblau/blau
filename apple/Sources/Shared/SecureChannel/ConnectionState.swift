import Foundation

/// The peer-to-peer secure channel's connection lifecycle (issue #51).
///
/// The transport drives this state machine as it walks from rendezvous through
/// the Noise IK handshake to an established encrypted session:
///
///     signaling -> holePunching -> handshake -> connected
///                                                   |
///                       (any stage may abort) ----> failed
///
/// It is a pure value type with no socket/UI dependencies so the connection
/// logic can be exercised in unit tests. `transition(to:)` enforces the legal
/// edges and returns `false` for an illegal move (leaving state unchanged).
enum ConnectionState: Equatable, Sendable {
    /// Registering with the rendezvous worker and waiting for the peer's
    /// public endpoint.
    case signaling
    /// Both endpoints known; exchanging UDP packets to punch through NAT.
    case holePunching
    /// Running the Noise IK handshake over the punched-through path.
    case handshake
    /// Handshake complete; directional transport keys established.
    case connected
    /// Terminal error state with a human-readable reason.
    case failed(reason: String)

    /// Whether `next` is a legal successor of `self`.
    func canTransition(to next: ConnectionState) -> Bool {
        switch (self, next) {
        case (.signaling, .holePunching),
             (.holePunching, .handshake),
             (.handshake, .connected):
            return true
        // Any non-terminal state may abort into `failed`.
        case (.signaling, .failed),
             (.holePunching, .failed),
             (.handshake, .failed),
             (.connected, .failed):
            return true
        default:
            return false
        }
    }

    /// `true` once the channel is usable for encrypted traffic.
    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }

    /// `true` for the terminal failure state.
    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }
}

/// A tiny driver around ``ConnectionState`` that rejects illegal transitions.
///
/// The transport layer holds one of these and advances it as signaling,
/// hole-punching, and the handshake complete. Keeping the legality check here
/// means the socket code can't accidentally jump straight from `signaling` to
/// `connected` without going through the handshake.
struct ConnectionStateMachine: Equatable, Sendable {
    private(set) var state: ConnectionState = .signaling

    init(state: ConnectionState = .signaling) {
        self.state = state
    }

    /// Attempt to move to `next`. Returns `true` and updates `state` if the
    /// edge is legal; returns `false` and leaves `state` unchanged otherwise.
    @discardableResult
    mutating func transition(to next: ConnectionState) -> Bool {
        // `.failed` is absorbing: once terminal, no further transitions.
        guard !state.isFailed else { return false }
        guard state.canTransition(to: next) else { return false }
        state = next
        return true
    }

    /// Force the channel into the terminal failure state from anywhere. Preserves
    /// the first failure reason: a late/duplicate failure can't clobber the
    /// original abort cause, and `.failed` is otherwise absorbing.
    mutating func fail(_ reason: String) {
        guard !state.isFailed else { return }
        state = .failed(reason: reason)
    }
}
