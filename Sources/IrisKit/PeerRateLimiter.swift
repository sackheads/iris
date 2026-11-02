import Foundation

/// #469 §6: a per-sender token bucket. Catches runaway fan-out; loops are the depth limit's job.
/// In memory — a restart refilling every bucket is acceptable (§8).
struct PeerRateLimiter {
    static let capacity = 20
    static let refillInterval: TimeInterval = 15

    private var buckets: [UUID: (tokens: Double, at: Date)] = [:]
    private let now: () -> Date

    init(now: @escaping () -> Date = Date.init) { self.now = now }

    /// Gives back `count` tokens a publish took and did not use (#696): a broadcast the guard withheld
    /// or the ledger could not record reached nobody, so it must not cost the sender its budget.
    mutating func refund(for sender: UUID, count: Int) {
        guard var b = buckets[sender] else { return }
        b.tokens = min(Double(Self.capacity), b.tokens + Double(count))
        buckets[sender] = b
    }

    /// Takes one token for `sender`. Nil when taken; otherwise the seconds until one is available.
    mutating func take(for sender: UUID) -> TimeInterval? { take(for: sender, count: 1) }

    /// Takes `count` tokens at once or none (#696: a topic publish is one send per subscriber woken).
    /// Nil when taken; otherwise the seconds until `count` are available. A count above the
    /// bucket's capacity can never be met, so callers keep it at or below `capacity`.
    mutating func take(for sender: UUID, count: Int) -> TimeInterval? {
        let t = now()
        let need = Double(count)
        var b = buckets[sender] ?? (Double(Self.capacity), t)
        b.tokens = min(Double(Self.capacity), b.tokens + t.timeIntervalSince(b.at) / Self.refillInterval)
        b.at = t
        guard b.tokens >= need else {
            buckets[sender] = b
            return (need - b.tokens) * Self.refillInterval
        }
        b.tokens -= need
        buckets[sender] = b
        return nil
    }
}
