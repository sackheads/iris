import Foundation

/// #469 §6: a per-sender token bucket. Catches runaway fan-out; loops are the depth limit's job.
/// In memory — a restart refilling every bucket is acceptable (§8).
struct PeerRateLimiter {
    static let capacity = 20
    static let refillInterval: TimeInterval = 15

    private var buckets: [UUID: (tokens: Double, at: Date)] = [:]
    private let now: () -> Date

    init(now: @escaping () -> Date = Date.init) { self.now = now }

    /// Takes one token for `sender`. Nil when taken; otherwise the seconds until one is available.
    mutating func take(for sender: UUID) -> TimeInterval? {
        let t = now()
        var b = buckets[sender] ?? (Double(Self.capacity), t)
        b.tokens = min(Double(Self.capacity), b.tokens + t.timeIntervalSince(b.at) / Self.refillInterval)
        b.at = t
        guard b.tokens >= 1 else {
            buckets[sender] = b
            return (1 - b.tokens) * Self.refillInterval
        }
        b.tokens -= 1
        buckets[sender] = b
        return nil
    }
}
