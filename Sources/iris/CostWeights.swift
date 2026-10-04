import Foundation

/// One usage, split the way a weight table prices it (5c §0.5). `prompt` is every input token,
/// cached or not: each provider's prompt count already folds cache reads and writes in (5a).
/// `output` includes anything billed as output that `candidates` leaves out (Gemini thinking).
struct UsageComponents: Equatable, Sendable {
    var prompt: Int = 0
    var output: Int = 0
    var cacheRead: Int = 0
    /// Every cache write.
    var cacheWrite: Int = 0
    /// The 1-hour share of `cacheWrite`.
    var cacheWrite1h: Int = 0
}
