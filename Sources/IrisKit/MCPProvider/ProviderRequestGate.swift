import Foundation

/// Per-token admission gate for the MCP provider (#1067): resolves a bearer token to a client id
/// and takes one unit from that client's token bucket, same refill algorithm as
/// `PeerRateLimiter`, but on `SuspendingClock` rather than `Date`/`TimeInterval` — AGENTS.md #605:
/// a `Date()`-timed bucket counts a Mac sleep as elapsed budget. `ContinuousClock` does too
/// (`Tests/irisTests/TestClock.swift` notes this explicitly); `SuspendingClock` is the one that
/// actually pauses while the system sleeps. This is a new, separate limiter; it never reads or
/// writes `AppState.peerRateLimiter` or `AppState.inboxEmitRateLimiter`.
///
/// Rate-only, not a concurrency cap: `admit` has no matching release, so there is no in-flight-
/// request ceiling here, only a refilling-bucket limit on requests per interval. A true
/// concurrency cap (bounding simultaneous in-flight requests) is a different primitive and a
/// follow-up, not something this type also does.
actor ProviderRequestGate {
    enum Admission: Equatable {
        case admitted(clientId: String)
        case unauthorized
        case budgetExceeded
    }

    private let registry: ProviderTokenRegistry
    private let capacity: Int
    /// The time it takes to refill one token.
    private let refillInterval: Duration
    private let now: @Sendable () -> SuspendingClock.Instant

    private var buckets: [String: (tokens: Double, at: SuspendingClock.Instant)] = [:]

    init(registry: ProviderTokenRegistry, capacity: Int, refillInterval: Duration,
         now: @escaping @Sendable () -> SuspendingClock.Instant = { SuspendingClock().now }) {
        precondition(refillInterval > .zero, "refillInterval must be positive — zero would divide by zero in the refill math")
        self.registry = registry
        self.capacity = capacity
        self.refillInterval = refillInterval
        self.now = now
    }

    /// Resolves `bearerToken` to a client id (a bare lookup, no network/MainActor work), then
    /// takes one unit from that client's bucket. `nil`/unresolvable token is `.unauthorized`
    /// without touching the bucket at all.
    func admit(bearerToken: String?) async -> Admission {
        guard let bearerToken, let clientId = registry.clientId(forToken: bearerToken) else {
            return .unauthorized
        }
        let t = now()
        var bucket = buckets[clientId] ?? (Double(capacity), t)
        let elapsedSeconds = Self.seconds(t - bucket.at)
        bucket.tokens = min(Double(capacity), bucket.tokens + elapsedSeconds / Self.seconds(refillInterval))
        bucket.at = t
        guard bucket.tokens >= 1 else {
            buckets[clientId] = bucket
            return .budgetExceeded
        }
        bucket.tokens -= 1
        buckets[clientId] = bucket
        return .admitted(clientId: clientId)
    }

    /// Drops `clientId`'s bucket, so a revoked id does not hold rate-limit state across a later
    /// re-issue of the same string, and so `buckets` does not grow for every client that ever
    /// existed. Not itself a budget decision — `revoke` calls it alongside the mailbox/store
    /// purges, never in place of `registry.revokeToken`.
    func purge(clientId: String) {
        buckets.removeValue(forKey: clientId)
    }

    private static func seconds(_ duration: Duration) -> Double {
        let (seconds, attoseconds) = duration.components
        return Double(seconds) + Double(attoseconds) / 1e18
    }
}
