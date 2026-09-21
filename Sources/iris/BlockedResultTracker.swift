/// Counts consecutive tool results the injection guard withheld, per conversation (#235).
///
/// `LoopDetector` cannot see this loop: it keys on identical `toolName|args`, and an agent whose
/// search results all come back blocked responds by rephrasing the query, so no two signatures
/// match. What repeats is the *outcome*, not the call.
struct BlockedResultTracker: Sendable {
    private(set) var consecutive = 0

    /// Returns the new consecutive count: one more when blocked, zero the moment anything passes.
    mutating func record(blocked: Bool) -> Int {
        consecutive = blocked ? consecutive + 1 : 0
        return consecutive
    }

    mutating func reset() { consecutive = 0 }
}
