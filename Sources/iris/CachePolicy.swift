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
