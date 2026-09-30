import Foundation

/// `/jobs` (#187 §9): the deterministic view of the agency ledger. It works in every
/// conversation, pinned or not, and never wakes a model turn — a person who wants to know what
/// their jobs are doing should not have to pay for inference to find out, and a person looking at
/// a failed run needs a way to clear it that cannot itself fail.
///
/// Parsing and rendering live here, apart from `AppState`, because they are the whole surface:
/// what the table says, how a run id is matched, and what an unacknowledged failure reads like are
/// all decidable from their inputs. `AppState.handleJobsCommand` is then only the ledger calls
/// between them.
enum JobsCommand: Equatable {
    case list
    case ack(runId: String)
    case pause(name: String)
    case resume(name: String)
    case run(name: String)
    case delete(name: String)
    case usage

    static let usageText = "Usage: /jobs · /jobs ack <run id> · /jobs pause <name> · "
        + "/jobs resume <name> · /jobs run <name> · /jobs delete <name>"

    /// What `/jobs pause` writes, and what `/jobs` then prints in the Next column. Spelled once so
    /// the command that clears it and the table that shows it cannot drift.
    static let pausedByUserReason = "paused by user"

    /// The shortest run-id prefix `/jobs ack` will consider. Eight characters is what an event
    /// card prints (`EventCard.historyLine`), so it is the shortest id a person can actually have
    /// been shown; anything shorter is a typo, and matching it would risk acknowledging a failure
    /// nobody has read.
    static let minimumRunIdPrefix = 8

    // MARK: Parsing

    /// `/jobs`, `/jobs ack <run id>`, `/jobs pause|resume|run|delete <name>`; anything else is
    /// `.usage`. A run id is exactly one token — a second word means the user meant something the
    /// command cannot do, and acting on the first token alone would be a guess. A job name, by
    /// contrast, is the rest of the line: names come from `schedule_job` and may contain spaces.
    static func parse(_ text: String) -> JobsCommand {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed == "/jobs" || trimmed.hasPrefix("/jobs ") else { return .usage }
        let args = trimmed.dropFirst("/jobs".count).trimmingCharacters(in: .whitespacesAndNewlines)
        if args.isEmpty { return .list }

        if args == "ack" || args.hasPrefix("ack ") {
            let rest = args.dropFirst(3).trimmingCharacters(in: .whitespacesAndNewlines)
            let tokens = rest.split(whereSeparator: \.isWhitespace)
            guard tokens.count == 1 else { return .usage }
            return .ack(runId: String(tokens[0]))
        }
        for (verb, form) in named {
            guard args == verb || args.hasPrefix(verb + " ") else { continue }
            let rest = args.dropFirst(verb.count).trimmingCharacters(in: .whitespacesAndNewlines)
            return rest.isEmpty ? .usage : form(rest)
        }
        return .usage
    }

    /// The forms that take a job name. A table rather than four near-identical branches, since the
    /// only thing that differs between them is which case the name goes into.
    private static let named: [(String, @Sendable (String) -> JobsCommand)] = [
        ("pause", { .pause(name: $0) }),
        ("resume", { .resume(name: $0) }),
        ("run", { .run(name: $0) }),
        ("delete", { .delete(name: $0) }),
    ]

    // MARK: Run-id matching

    /// What `/jobs ack <id>` and `get_job_run` found for what the caller typed.
    enum RunMatch: Equatable {
        case none
        /// More than one run's id starts with the query — refusing beats acknowledging whichever
        /// one happened to be first.
        case ambiguous
        case found(UUID)
    }

    /// A run id as it is compared: lower-cased with the hyphens taken out, so an id copied from a
    /// card (`1a2b3c4d`), from a log (`1A2B3C4D-0000-…`) and from a paste that lost its hyphens
    /// (`1a2b3c4d0000`) are all the same id. The prefix length is counted in these characters.
    static func normalizedRunId(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: "-", with: "")
    }

    /// Matches a full UUID or a unique prefix of at least `minimumRunIdPrefix` characters against
    /// candidates already in hand. A full id is matched exactly first, so an id that is also the
    /// prefix of another is never ambiguous.
    static func matchRun(_ query: String, in runs: [JobRun]) -> RunMatch {
        let needle = normalizedRunId(query)
        guard !needle.isEmpty else { return .none }
        if let exact = runs.first(where: { normalizedRunId($0.id.uuidString) == needle }) {
            return .found(exact.id)
        }
        guard needle.count >= minimumRunIdPrefix else { return .none }
        let hits = runs.filter { normalizedRunId($0.id.uuidString).hasPrefix(needle) }
        if hits.isEmpty { return .none }
        return hits.count == 1 ? .found(hits[0].id) : .ambiguous
    }

    /// The one resolver `/jobs ack` and `get_job_run` share — the only part of this type that
    /// touches the database, kept here so the two surfaces cannot drift on what an id means.
    ///
    /// A full UUID is a primary-key read: no window, no scan, so a run stays reachable by its own
    /// id forever. A prefix is a prefix query (`runs(idPrefix:)`) rather than a filter over the
    /// most recent N runs, because the run a person most needs to acknowledge — an unacknowledged
    /// failure, exempt from retention — is precisely the one that can have aged out of any window.
    static func resolveRun(_ query: String, in ledger: JobLedger) throws -> RunMatch {
        let needle = normalizedRunId(query)
        guard !needle.isEmpty else { return .none }
        if let id = UUID(uuidString: query.trimmingCharacters(in: .whitespaces)),
           try ledger.run(id: id) != nil {
            return .found(id)
        }
        guard needle.count >= minimumRunIdPrefix else { return .none }
        return matchRun(query, in: try ledger.runs(idPrefix: query))
    }

    // MARK: Rendering

    /// The whole `/jobs` listing: a table of jobs, then one line per unacknowledged failure, then
    /// the count of job rows the ledger could not read. `lastRuns` is each job's newest run, keyed
    /// by job id. `now` is a parameter rather than `Date()` so the relative next-fire text is
    /// testable.
    ///
    /// `usage` is what the job has spent and how hard it has been running, against the numbers
    /// admission decides on (§0.1). A listing whose ledger reads failed passes `.empty` and still
    /// prints the table, with a dash where a figure would be — inventing a zero there would read as
    /// "this job has spent nothing today", which is a different and wrong claim. Required rather
    /// than defaulted for exactly that reason: a caller that forgot the figures would render a
    /// table of dashes and claim the ledger could not be read.
    ///
    /// `lastBursts` and `absorbed` are the watch figures (#187 deliverable 4, spec §6): the newest
    /// `watchSummary` per job from the ledger, and what each watch has absorbed since launch from
    /// the coordinator's memory. `absorbed == nil` means there is no live coordinator in this
    /// process — `iris --run-job` — and the line says `—` rather than a zero it cannot vouch for.
    static func render(jobs: [Job], lastRuns: [UUID: JobRun], usage: UsageSnapshot,
                       unacknowledged: [JobRun], unreadableJobs: Int, now: Date,
                       lastBursts: [UUID: WatchSummary] = [:],
                       absorbed: [UUID: AbsorbedCounts]? = nil) -> String {
        var blocks: [String] = []

        if jobs.isEmpty {
            blocks.append("No jobs.")
        } else {
            var rows = ["| Job | Trigger | Policy | Next | Last | Tokens today | Runs/h |",
                        "| --- | --- | --- | --- | --- | --- | --- |"]
            for job in jobs {
                let last = lastRuns[job.id]?.status.text ?? "never"
                let figures = usage.perJob[job.id]
                rows.append("| \(cell(job.name)) | \(cell(job.trigger.summary)) | "
                            + "\(cell(policySummary(for: job))) | "
                            + "\(cell(nextText(for: job, now: now))) | \(cell(last)) | "
                            + "\(figures.map(tokensCell) ?? missingFigure) | "
                            + "\(figures.map(runsCell) ?? missingFigure) |")
            }
            // One line per watch, directly beneath the table and in its order: a markdown table
            // row cannot carry a second line, and the figures are too long for a column. The grant
            // paragraphs (spec §5) follow, one per granted job, in the jobs' own order.
            let watchLines = jobs.compactMap { job -> String? in
                guard case .fsEvent = job.trigger else { return nil }
                return watchLine(job: job, lastBurst: lastBursts[job.id],
                                 absorbed: absorbed?[job.id], hasCoordinator: absorbed != nil)
            }
            let extraLines = watchLines + jobs.compactMap(grantLine(job:))
            // One paragraph per line: the block is markdown, where a single newline is a space,
            // so two lines joined by one would read as a single sentence.
            for line in extraLines {
                rows.append("")
                rows.append(line)
            }
            if let global = usage.global {
                rows.append("")
                rows.append("Tokens today, all jobs: \(budgetText(used: global.tokensToday, budget: global.dailyBudget))")
            }
            blocks.append(rows.joined(separator: "\n"))
        }

        if !unacknowledged.isEmpty {
            blocks.append(unacknowledged.map(failureLine).joined(separator: "\n"))
        }
        // Said out loud rather than swallowed: a job silently missing from the table is the one
        // case where the listing is actively misleading about what is scheduled.
        if unreadableJobs > 0 {
            blocks.append("\(unreadableJobs) unreadable job row(s)")
        }
        return blocks.joined(separator: "\n\n")
    }

    /// What one job has spent today and how hard it has been running, beside the numbers it is
    /// judged against (§0.1). The figures come from the ledger sums admission itself decides on
    /// (`JobLedger.usage`) and the limits from `JobLimits.resolve`, so what a person reads in the
    /// table is the same arithmetic that would pause the job — not a second, drifting accounting.
    struct JobFigures: Equatable, Sendable {
        let tokensToday: Int
        let runsLastHour: Int
        let limits: JobLimits
    }

    /// The whole unattended system's spend for the local day, against the one ceiling no job can
    /// raise for itself.
    struct GlobalUsage: Equatable, Sendable {
        let tokensToday: Int
        let dailyBudget: Int
    }

    /// Every figure one listing needs. Absent entries are the point: a ledger read that failed is
    /// reported as a dash rather than as a zero.
    struct UsageSnapshot: Equatable, Sendable {
        var perJob: [UUID: JobFigures] = [:]
        var global: GlobalUsage?
        static let empty = UsageSnapshot()
    }

    /// The figures for a listing, read through the same two ledger seams admission uses. Each read
    /// is allowed to fail on its own: one unreadable job costs that job its two columns, not the
    /// table, and a global sum that will not read costs the footer.
    static func usageSnapshot(jobs: [Job], ledger: JobLedger, config: ConfigManager,
                              now: Date, calendar: Calendar = .current) -> UsageSnapshot {
        var snapshot = UsageSnapshot()
        for job in jobs {
            guard let usage = try? ledger.usage(jobId: job.id, now: now, calendar: calendar) else { continue }
            snapshot.perJob[job.id] = JobFigures(tokensToday: usage.tokensToday,
                                                 runsLastHour: usage.runsLastHour,
                                                 limits: JobLimits.resolve(job: job, config: config))
        }
        // `globalDailyTokens` is deliberately not overridable per job, so the first job's
        // resolution answers for all of them; with no jobs at all there is no table to foot.
        let globalBudget = jobs.first.map { JobLimits.resolve(job: $0, config: config).globalDailyTokens }
        if let globalBudget, let total = try? ledger.tokensToday(jobId: nil, calendar: calendar, now: now) {
            snapshot.global = GlobalUsage(tokensToday: total, dailyBudget: globalBudget)
        }
        return snapshot
    }

    /// What this job does differently from every other job (§3), in the order a person asks about
    /// it: what it may touch, whether it may run beside itself, and what it does with occurrences
    /// it slept through. A job that departs from none of the defaults says `default` rather than
    /// repeating them in every row.
    ///
    /// The gate is deliberately not here. `Trigger.summary` already ends a polled job's cell with
    /// `(url gate)`, and in the widest table Iris prints the one word worth cutting is the one
    /// printed twice on the same row; `list_jobs` carries `gateKind` as a field of its own,
    /// because it has no trigger column to read it out of.
    static func policySummary(for job: Job) -> String {
        var parts: [String] = []
        if job.profile == .mutating { parts.append("mutating") }
        if job.effectiveGrant != nil { parts.append("grant") }
        if job.policy.overlap == .queue { parts.append("overlap queue") }
        // #283 review: the column shows what a job's policy does differently from the defaults, and
        // a removed breaker is the most different thing in it — `0` is the one value that takes the
        // bound off a self-write loop entirely, so it must not read as `default`.
        if let runs = job.policy.maxRunsPerHour {
            parts.append(runs == 0 ? "no breaker" : "breaker \(runs)/h")
        }
        switch job.policy.catchUp {
        case .coalesce: break
        case .skip: parts.append("catch-up skip")
        case .replay(let cap): parts.append("catch-up replay \(cap)")
        }
        // A watch's own knobs (spec §6): the quiet window when it is not the default, and how
        // many globs it ignores — the count, since the globs themselves are too long for a cell.
        if case .fsEvent(let watch) = job.trigger {
            if watch.quietWindowSeconds != FSWatch.defaultQuietWindowSeconds {
                parts.append("quiet \(watch.quietWindowSeconds) s")
            }
            if !watch.ignore.isEmpty { parts.append("\(watch.ignore.count) ignore") }
        }
        return parts.isEmpty ? "default" : parts.joined(separator: " · ")
    }

    /// The watch line beneath the table (spec §6), two halves from two sources:
    /// `` `notes` — last burst: 12 changes · 3 noise · 1 own writes (cut at 30 s) · absorbed since
    /// launch: 41 noise · 7 own writes · 3 while paused ``. The first half is the ledger's newest
    /// summary for the job and survives a relaunch; the second is the coordinator's memory and
    /// starts again at zero. The job is at hand here, so the ceiling is printed as the number the
    /// window makes it — the card, which has no window, says `(cut at the ceiling)` instead.
    ///
    /// `hasCoordinator == false` prints `—` for the second half: with no coordinator in the
    /// process (the `--run-job` process) a zero would claim the watch absorbed nothing, which is
    /// not known. With one, a watch it has no entry for has absorbed nothing, and says so.
    static func watchLine(job: Job, lastBurst: WatchSummary?, absorbed: AbsorbedCounts?,
                          hasCoordinator: Bool) -> String {
        let ceiling: Int?
        if case .fsEvent(let watch) = job.trigger { ceiling = watch.ceilingSeconds } else { ceiling = nil }
        let burst = lastBurst?.figuresText(ceilingSeconds: ceiling) ?? "nothing fired yet"
        let since: String
        if hasCoordinator {
            let counts = absorbed ?? AbsorbedCounts()
            since = "\(counts.noise) noise · \(counts.ownWrites) own writes · \(counts.whilePaused) while paused"
        } else {
            since = missingFigure
        }
        return "`\(job.name)` — last burst: \(burst) · absorbed since launch: \(since)"
    }

    /// The grant paragraph beneath the table (spec §5): what a granted job may touch, in the words
    /// the result sentence used when it was created, so the two never disagree. A read-only row's
    /// grant is inert (L1) and gets no line.
    static func grantLine(job: Job) -> String? {
        guard let grant = job.effectiveGrant else { return nil }
        return "`\(job.name)` — \(grant.describe(hostNote: true))"
    }

    /// What a column says when the figure behind it could not be read.
    static let missingFigure = "—"

    private static func tokensCell(_ figures: JobFigures) -> String {
        budgetText(used: figures.tokensToday, budget: figures.limits.dailyTokens)
    }

    private static func runsCell(_ figures: JobFigures) -> String {
        figures.limits.maxRunsPerHour > 0
            ? "\(figures.runsLastHour) / \(figures.limits.maxRunsPerHour)"
            : "\(figures.runsLastHour) / unlimited"
    }

    /// `620k / 1M (62%)`. A zero budget is not a ceiling of nothing — it is how a hand-written
    /// policy says "unbounded" (§0.1) — so it prints the word rather than a percentage of zero.
    static func budgetText(used: Int, budget: Int) -> String {
        guard budget > 0 else { return "\(compactTokens(used)) / unlimited" }
        let pct = Int((Double(used) / Double(budget) * 100).rounded())
        return "\(compactTokens(used)) / \(compactTokens(budget)) (\(pct)%)"
    }

    /// Token counts as a person reads them in a table: `620k`, `1M`, `1.2M`. Exact figures are
    /// what `get_job_run` and `list_jobs` are for; a column that has to fit beside four others is
    /// for noticing that a job is at 90% of its day.
    static func compactTokens(_ value: Int) -> String {
        let n = max(0, value)
        if n < 1_000 { return "\(n)" }
        if n < 999_500 { return "\(Int((Double(n) / 1_000).rounded()))k" }
        let millions = (Double(n) / 1_000_000 * 10).rounded() / 10
        return millions == millions.rounded()
            ? "\(Int(millions))M"
            : String(format: "%.1fM", millions)
    }

    /// `⚠️ pr-sweep · failed · 1a2b3c4d · could not reach the API` — the run's own account of
    /// itself, named by the same eight characters `/jobs ack` takes back.
    static func failureLine(_ run: JobRun) -> String {
        let shortId = run.id.uuidString.lowercased().prefix(8)
        var line = "⚠️ \(run.jobName) · \(run.status.text) · \(shortId)"
        let detail = [run.outcome, run.failureReason]
            .compactMap { $0 }
            .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if let detail { line += " · \(flatten(detail))" }
        return line
    }

    /// When this job fires next, as a person reads it. A paused job says why instead; a watch has
    /// no cadence to report. A job part-way up the retry ladder says so beside its next fire (§9),
    /// because "in 1 m" on a five-minute job is otherwise unexplained.
    static func nextText(for job: Job, now: Date) -> String {
        if let reason = job.pausedReason { return "paused: \(reason)" }
        if !job.enabled { return "disabled" }
        var text = "—"
        if case .fsEvent = job.trigger {
            text = "—"
        } else if let next = job.nextFireAt {
            text = relative(from: now, to: next)
        }
        guard job.retryAttempt > 0 else { return text }
        return "\(text) · retry \(job.retryAttempt)/\(JobRunner.backoff.count)"
    }

    /// One unit, rounded down: "in 3 m" is read as "not for a few minutes", and a fire that is
    /// already overdue (the scheduler is between ticks, or the app was asleep) is "due" rather than
    /// a negative interval.
    private static func relative(from now: Date, to date: Date) -> String {
        let delta = date.timeIntervalSince(now)
        if delta <= 0 { return "due" }
        if delta < 60 { return "in \(Int(delta)) s" }
        if delta < 3_600 { return "in \(Int(delta / 60)) m" }
        if delta < 86_400 { return "in \(Int(delta / 3_600)) h" }
        return "in \(Int(delta / 86_400)) d"
    }

    /// A table cell: job names, trigger paths and pause reasons are not written by the harness, and
    /// an unescaped `|` in any of them would open a column of its own.
    private static func cell(_ text: String) -> String {
        flatten(text).replacingOccurrences(of: "|", with: "\\|")
    }

    private static func flatten(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).joined(separator: " ")
    }
}
