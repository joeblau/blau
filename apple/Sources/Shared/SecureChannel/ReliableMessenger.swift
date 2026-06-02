import Foundation

/// Reliability bookkeeping for the secure channel's control messages (issue #51).
///
/// Reliable messages (`PacketType.reliableControl`, 0x02) carry a `msgID`. The
/// receiver acknowledges each one with an ACK packet (`PacketType.ack`, 0x03)
/// echoing that `msgID`; the sender retransmits with exponential backoff until
/// the ACK arrives. Best-effort blobs (0x04) are fire-and-forget and never
/// tracked here.
///
/// This type is the pure, socket-free bookkeeping layer: it decides *when* a
/// message should be (re)sent and *which* in-flight messages an incoming ACK
/// clears. The transport plugs it into a real `NWConnection` + timer; tests
/// drive it directly with a synthetic clock.
struct ReliableMessenger {

    /// Caps retransmission so a dead peer doesn't keep a message queued forever.
    static let defaultMaxAttempts = 8
    /// First retransmit delay; doubles each attempt up to `maxBackoff`.
    static let defaultBaseBackoff: TimeInterval = 0.25
    static let defaultMaxBackoff: TimeInterval = 8.0

    /// An on-wire reliable control message paired with its ACK token.
    struct Message: Equatable, Sendable {
        let id: UInt64
        let payload: Data
    }

    /// Result of asking the messenger for work at a given time.
    enum SendDecision: Equatable {
        /// (Re)send these messages now.
        case send([Message])
        /// Nothing due yet; ask again no sooner than this absolute time.
        case waitUntil(TimeInterval)
        /// No outstanding reliable messages.
        case idle
    }

    private struct InFlight {
        var message: Message
        var attempts: Int
        var nextFireAt: TimeInterval
    }

    private let maxAttempts: Int
    private let baseBackoff: TimeInterval
    private let maxBackoff: TimeInterval

    private var nextID: UInt64 = 1
    private var inFlight: [UInt64: InFlight] = [:]
    /// IDs whose retransmission budget was exhausted before an ACK arrived.
    private(set) var abandoned: Set<UInt64> = []

    init(
        maxAttempts: Int = ReliableMessenger.defaultMaxAttempts,
        baseBackoff: TimeInterval = ReliableMessenger.defaultBaseBackoff,
        maxBackoff: TimeInterval = ReliableMessenger.defaultMaxBackoff
    ) {
        self.maxAttempts = maxAttempts
        self.baseBackoff = baseBackoff
        self.maxBackoff = maxBackoff
    }

    /// Number of messages still awaiting an ACK.
    var outstandingCount: Int { inFlight.count }

    /// Whether `id` is still awaiting an ACK.
    func isOutstanding(_ id: UInt64) -> Bool { inFlight[id] != nil }

    /// Enqueue a new reliable message for delivery. Returns the assigned
    /// `msgID`, which the receiver will echo in its ACK. The first send is due
    /// immediately (`now`); the caller transmits it on the next `due(now:)`.
    mutating func enqueue(_ payload: Data, now: TimeInterval) -> Message {
        let id = nextID
        nextID &+= 1
        let message = Message(id: id, payload: payload)
        inFlight[id] = InFlight(message: message, attempts: 0, nextFireAt: now)
        return message
    }

    /// Replace the payload of an already-enqueued in-flight message, keeping its
    /// `msgID` and retransmit schedule. Used when the caller must reserve a
    /// `msgID` (via `enqueue`) before it can build the final payload, because the
    /// `msgID` is embedded inside that payload (e.g. a JSON envelope). No-op if
    /// the message has already been acknowledged or abandoned.
    mutating func replacePayload(id: UInt64, payload: Data) {
        guard var entry = inFlight[id] else { return }
        entry.message = Message(id: id, payload: payload)
        inFlight[id] = entry
    }

    /// Record an incoming ACK for `id`. Returns `true` if it cleared an
    /// in-flight message, `false` if the ID was unknown (duplicate/late ACK).
    @discardableResult
    mutating func acknowledge(_ id: UInt64) -> Bool {
        inFlight.removeValue(forKey: id) != nil
    }

    /// Ask what should be transmitted at `now`. Messages whose timer has fired
    /// are returned for (re)send and rescheduled with doubled backoff; ones that
    /// exhaust `maxAttempts` are abandoned. Capped backoff prevents unbounded
    /// growth.
    mutating func due(now: TimeInterval) -> SendDecision {
        var toSend: [Message] = []
        var soonest: TimeInterval?

        for (id, var entry) in inFlight {
            if entry.nextFireAt <= now {
                if entry.attempts >= maxAttempts {
                    inFlight.removeValue(forKey: id)
                    abandoned.insert(id)
                    continue
                }
                entry.attempts += 1
                let backoff = min(maxBackoff, baseBackoff * pow(2, Double(entry.attempts - 1)))
                entry.nextFireAt = now + backoff
                inFlight[id] = entry
                toSend.append(entry.message)
                soonest = min(soonest ?? entry.nextFireAt, entry.nextFireAt)
            } else {
                soonest = min(soonest ?? entry.nextFireAt, entry.nextFireAt)
            }
        }

        if !toSend.isEmpty {
            // Deterministic ordering for tests / predictable wire traffic.
            return .send(toSend.sorted { $0.id < $1.id })
        }
        if let soonest { return .waitUntil(soonest) }
        return .idle
    }
}

/// Receiver-side ACK bookkeeping: tracks which reliable `msgID`s have already
/// been delivered to the app so duplicates (from sender retransmits) are
/// ACK'd again but not re-delivered.
struct AckTracker {
    private var delivered: Set<UInt64> = []

    /// Register receipt of a reliable message. Returns `true` if this is the
    /// first time (deliver it to the app); `false` for a duplicate (still ACK
    /// it so the sender stops retransmitting, but don't re-deliver).
    @discardableResult
    mutating func receive(_ id: UInt64) -> Bool {
        delivered.insert(id).inserted
    }

    func hasDelivered(_ id: UInt64) -> Bool { delivered.contains(id) }
}
