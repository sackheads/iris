import Foundation

/// A job that runs without a model turn (5b §0.8): the runner calls it in place of opening a
/// conversation, records its outcome on an ordinary ledger row with zero tokens and no transcript,
/// and posts a card when it asks for one. Scheduling, overlap, catch-up and `/jobs` treat it like
/// any other job; only the token budgets are skipped, since it spends none.
protocol BuiltinJob: Sendable {
    /// The key it is registered under, and what follows `builtin:` in a job's `action` column.
    static var name: String { get }
    func run(ledger: JobLedger, now: Date, calendar: Calendar) async -> BuiltinResult
}

struct BuiltinResult: Equatable, Sendable {
    /// How the run ended, as its ledger row records it.
    enum Status: Equatable, Sendable {
        case completed
        /// `reason` is the row's `failureReason`: a fixed harness constant, never fetched text,
        /// so `Briefing.reason` can map it to a word.
        case failed(reason: String)
    }

    /// The run's outcome text: the row's outcome and, when `card` is set, the card's.
    var outcome: String
    /// `false` posts nothing — the row is still written.
    var card: Bool
    /// Completed unless the built-in says otherwise. A failed run does not count as a completed
    /// one anywhere that asks — the digest's window, notably, only closes on a completed digest.
    var status: Status = .completed
}

/// The registry of built-ins, keyed by name, so the next model-free job is one entry rather than a
/// schema change.
enum BuiltinJobs {
    /// What production runs.
    static let registry: [String: any BuiltinJob] = [DailyDigest.name: DailyDigest()]

    /// A test's own registry, in place of `registry` for the task that sets it — never a mutation
    /// of a shared table (invariant 7).
    @TaskLocal static var scopedRegistry: [String: any BuiltinJob]?

    static func named(_ name: String) -> (any BuiltinJob)? {
        (scopedRegistry ?? registry)[name]
    }
}
