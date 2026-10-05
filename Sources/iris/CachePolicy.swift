import Foundation

/// An Anthropic `cache_control` lifetime (5c §0.8).
enum CacheTTL: Int, Sendable, Comparable {
    case fiveMinutes = 300, oneHour = 3600
    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

/// Anthropic's marker TTLs, by position. The prefix (tools + system) and the history markers.
/// A longer TTL must come before a shorter one in the prompt, so history is clamped to the prefix.
struct CacheTTLPolicy: Sendable, Equatable {
    let prefix: CacheTTL
    let history: CacheTTL
    init(prefix: CacheTTL, history: CacheTTL) { self.prefix = prefix; self.history = min(history, prefix) }
    static let standard = CacheTTLPolicy(prefix: .fiveMinutes, history: .fiveMinutes)
}

/// Provider-side cache hints that ride on a `GeminiRequest` without being encoded into it.
struct CacheHints: Sendable, Equatable {
    var ttl: CacheTTLPolicy = .standard
    /// OpenAI's `prompt_cache_key`; capped at 64 UTF-8 bytes where it is sent.
    var promptCacheKey: String? = nil
}

extension CacheTTLPolicy {
    /// 5c §0.8. Iris (the pinned conversation) holds an hour everywhere: a human-paced day stays
    /// warm for one 2× write per hour of silence. A job run holds the shared prefix for an hour
    /// only when some job comes round inside one; its own history markers stay at five minutes,
    /// because runs are short. Everything else, subagents and evaluators included, is five minutes.
    static func resolve(isPinned: Bool, isUnattended: Bool, principal: Principal,
                        backgroundFiresHourly: Bool) -> CacheTTLPolicy {
        guard principal == .main else { return .standard }
        if isPinned { return CacheTTLPolicy(prefix: .oneHour, history: .oneHour) }
        if isUnattended, backgroundFiresHourly { return CacheTTLPolicy(prefix: .oneHour, history: .fiveMinutes) }
        return .standard
    }
}

/// Whether any job that runs a model turn on a predictable cadence comes round more often than
/// hourly (plan note 13: schedules only; polls, watches and built-ins don't keep a prefix warm).
enum JobCadence {
    /// How many consecutive cron fires are sampled for the smallest gap.
    static let samples = 48

    static func anyFiresMoreOftenThanHourly(_ jobs: [Job], now: Date,
                                            calendar: Calendar = Calendar(identifier: .gregorian)) -> Bool {
        jobs.contains { job in
            guard job.enabled, job.pausedReason == nil, case .prompt = job.action,
                  case .schedule(let schedule) = job.trigger else { return false }
            return minimumGap(schedule, after: now, calendar: calendar) < 3600
        }
    }

    static func minimumGap(_ schedule: Schedule, after now: Date, calendar: Calendar) -> TimeInterval {
        if case .interval(let seconds) = schedule { return TimeInterval(seconds) }
        var previous = schedule.next(after: now, calendar: calendar)
        var gap = TimeInterval.infinity
        for _ in 0..<samples {
            guard let p = previous, let n = schedule.next(after: p, calendar: calendar) else { break }
            gap = min(gap, n.timeIntervalSince(p))
            previous = n
        }
        return gap
    }
}
