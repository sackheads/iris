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

    /// #1437: a loop ticking at most this often keeps its history for an hour; a slower one stays at five minutes.
    /// 45 minutes rather than 60, so a tick that runs a little late still finds the entry (planner, from the paid runs).
    static let hourlyHistoryMaxCadence: TimeInterval = 45 * 60

    /// The gap between a loop's ticks, for `resolve`. A self-paced loop picks each delay itself, so it counts at its
    /// default; an alarm at its delay.
    static func cadence(of loop: ConversationLoop) -> TimeInterval {
        loop.selfPaced ? ConversationLoop.selfPacedDefault : loop.intervalSeconds
    }
}

/// Provider-side cache hints that ride on a `GeminiRequest` without being encoded into it.
struct CacheHints: Sendable, Equatable {
    var ttl: CacheTTLPolicy = .standard
    /// OpenAI's `prompt_cache_key`; capped at 64 UTF-8 bytes where it is sent.
    var promptCacheKey: String? = nil
    /// #1437: send no `cache_control` marker at all, for a one-off request whose prefix is never sent again (a
    /// compaction summary wrote its whole input to cache and never read it back: 1.25× for nothing).
    var uncached: Bool = false
}

extension CacheTTLPolicy {
    /// 5c §0.8. Iris (the pinned conversation) holds an hour everywhere: a human-paced day stays
    /// warm for one 2× write per hour of silence. A job run holds the shared prefix for an hour
    /// only when some job comes round inside one; its own history markers stay at five minutes,
    /// because runs are short. A conversation with a loop (#1437) holds an hour when it ticks every 45 minutes or less, so
    /// each tick reads the last one's history. A slower loop stays at five minutes: its ticks start cold either way, and
    /// marker (d) still lets a tick's later rounds read its first (dev-2's #1445 review; dropping it cost more than it saved).
    /// Everything else, subagents and evaluators included, is five minutes.
    static func resolve(isPinned: Bool, isUnattended: Bool, principal: Principal,
                        backgroundFiresHourly: Bool, loopCadence: TimeInterval? = nil) -> CacheTTLPolicy {
        guard principal == .main else { return .standard }
        if isPinned { return CacheTTLPolicy(prefix: .oneHour, history: .oneHour) }
        if let cadence = loopCadence {
            if cadence <= hourlyHistoryMaxCadence { return CacheTTLPolicy(prefix: .oneHour, history: .oneHour) }
        }
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
