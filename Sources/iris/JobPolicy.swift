import Foundation

/// What an unattended job is allowed to do to the machine over time (#187 deliverable 3, spec §3):
/// whether it may run beside itself, what it does with occurrences missed while the Mac slept, how
/// long one run may take, what it may spend, and whether a failure is retried.
///
/// Stored as one `policy TEXT` JSON column on `jobs` rather than a column per field: these are
/// per-job overrides of global `ConfigManager` numbers, they are read together or not at all, and
/// the set of them will grow. A NULL column, an empty object and an object full of keys this build
/// has never heard of all read back as the default policy — a job must keep running when a newer
/// build has written a policy an older one cannot parse.
///
/// The `nil` budgets are not "no budget": they mean "take the global default", which the runner
/// resolves at admission time. A stored negative decodes to `nil` for the same reason: nobody
/// writes -1 to mean unlimited, so it is a typo, and reading it as "no budget" would quietly take
/// a job's ceiling off.
struct JobPolicy: Codable, Equatable, Sendable {
    /// What a fire does when the job's previous run has not finished. `skip` drops it (with an
    /// `interrupted` ledger row); `queue` remembers one pending fire in `Job.queuedFire` and takes
    /// it when the run ends. Never more than one: a job that fell far behind should run once, not
    /// N times in a row.
    enum Overlap: String, Codable, Sendable { case skip, queue }

    /// What happens to occurrences that came due while the Mac was asleep (spec §5). `replay`'s
    /// `cap` bounds the catch-up burst; occurrences past it are dropped and counted on the card.
    enum CatchUp: Codable, Equatable, Sendable {
        case coalesce
        case skip
        case replay(cap: Int)
    }

    var overlap: Overlap = .skip
    /// Nothing replays a missed occurrence yet; this is the stored shape. PR D's wake handling is
    /// the first thing to read it.
    var catchUp: CatchUp = .coalesce
    var runTimeoutSeconds: Int = 600
    /// `nil` = the global default from `ConfigManager`, not "unlimited".
    var perRunTokenBudget: Int?
    /// Per job per day; `nil` = the global default.
    var dailyTokenBudget: Int?
    /// The breaker: more runs than this in the last hour pauses the job. `nil` = the global default.
    var maxRunsPerHour: Int?
    /// Whether a failed run is retried on the backoff ladder before the job is paused.
    var retry: Bool = true

    /// The cap a `replay` written without one takes (spec §0.1).
    static let defaultReplayCap = 5

    init(overlap: Overlap = .skip, catchUp: CatchUp = .coalesce, runTimeoutSeconds: Int = 600,
         perRunTokenBudget: Int? = nil, dailyTokenBudget: Int? = nil, maxRunsPerHour: Int? = nil,
         retry: Bool = true) {
        self.overlap = overlap
        self.catchUp = catchUp
        self.runTimeoutSeconds = runTimeoutSeconds
        self.perRunTokenBudget = perRunTokenBudget
        self.dailyTokenBudget = dailyTokenBudget
        self.maxRunsPerHour = maxRunsPerHour
        self.retry = retry
    }

    private enum CodingKeys: String, CodingKey {
        case overlap, catchUp, runTimeoutSeconds, perRunTokenBudget, dailyTokenBudget
        case maxRunsPerHour, retry
    }

    /// Invariant 1, and one step further: every key is optional *and* an unrecognized `overlap`
    /// degrades to the default instead of throwing. A policy is advisory; nothing in it is worth
    /// making a job unreadable over.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        overlap = Overlap(rawValue: try c.decodeIfPresent(String.self, forKey: .overlap) ?? "") ?? .skip
        catchUp = try c.decodeIfPresent(CatchUp.self, forKey: .catchUp) ?? .coalesce
        // Negatives are dropped here, not carried and argued with later: a policy that has been
        // read back is one whose numbers mean what the rest of the code thinks they mean.
        runTimeoutSeconds = Self.notNegative(try c.decodeIfPresent(Int.self, forKey: .runTimeoutSeconds)) ?? 600
        perRunTokenBudget = Self.notNegative(try c.decodeIfPresent(Int.self, forKey: .perRunTokenBudget))
        dailyTokenBudget = Self.notNegative(try c.decodeIfPresent(Int.self, forKey: .dailyTokenBudget))
        maxRunsPerHour = Self.notNegative(try c.decodeIfPresent(Int.self, forKey: .maxRunsPerHour))
        retry = try c.decodeIfPresent(Bool.self, forKey: .retry) ?? true
    }

    /// A stored figure, or `nil` — absent, which is "take the default" — when it is below zero.
    /// Zero is kept: for the token budgets and the breaker it deliberately means unbounded (§0.1),
    /// and for `runTimeoutSeconds` `JobLimits.resolve` reads it as the global default, because a
    /// turn nothing can end is the failure the timeout exists for.
    private static func notNegative(_ value: Int?) -> Int? {
        guard let value, value >= 0 else { return nil }
        return value
    }
}

extension JobPolicy.CatchUp {
    private enum CodingKeys: String, CodingKey { case kind, cap }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .coalesce: try c.encode("coalesce", forKey: .kind)
        case .skip: try c.encode("skip", forKey: .kind)
        case .replay(let cap):
            try c.encode("replay", forKey: .kind)
            try c.encode(cap, forKey: .cap)
        }
    }

    /// Lenient on purpose, unlike `Schedule` and `Trigger`, which throw on an unknown kind: those
    /// decide *whether* a job runs at all and a wrong guess would fire it on the wrong cadence,
    /// while a catch-up mode only decides what a wake does with missed occurrences. The safe guess
    /// is the default, `coalesce` — one fire now.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decodeIfPresent(String.self, forKey: .kind) ?? "" {
        case "skip":
            self = .skip
        case "replay":
            // Clamped like the four limits above (R15): a negative cap is a typo, and the wake
            // handling that will read this must not have to decide what "replay -1 occurrences"
            // means. Zero is kept and is a real answer: replay nothing, drop the lot.
            let cap = JobPolicy.notNegative(try c.decodeIfPresent(Int.self, forKey: .cap))
            self = .replay(cap: cap ?? JobPolicy.defaultReplayCap)
        default:
            self = .coalesce
        }
    }
}
