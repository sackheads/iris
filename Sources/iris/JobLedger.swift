import Foundation
import GRDB
import os

/// The two figures admission decides on. A protocol only so the failure has a seam: a read that
/// throws used to be swallowed into zero, which opens the breaker and both budgets at once on a
/// job that may be far past either, and a test cannot make a real SQLite read fail while leaving
/// the writes that record the refusal working.
protocol JobUsageReading: Sendable {
    func usage(jobId: UUID, now: Date, calendar: Calendar) throws -> JobUsage
    func tokensToday(jobId: UUID?, calendar: Calendar, now: Date) throws -> Int
}

/// Jobs' half of the agency ledger (#187 deliverable 1): the `jobs` table, read and written
/// through the conversation store's own writer so a job and the conversation it produces commit
/// against one database. Scalar `Job` fields are columns — the scheduler queries `enabled` and
/// `nextFireAt` directly — while the two open-ended fields, `trigger` and `policy`, are stored as
/// JSON.
///
/// Reads are deliberately lenient: a row whose `trigger` JSON no longer decodes (a kind written by
/// a newer build, a hand-edited row) is skipped rather than failing the whole listing, so one bad
/// job cannot stop every other job from running. `unreadableJobCount` reports how many the last
/// `jobs()` call skipped.
final class JobLedger: JobUsageReading, Sendable {
    private let writer: any DatabaseWriter
    private let skippedCount = OSAllocatedUnfairLock(initialState: 0)
    /// What to tell when the *set* of jobs changes (#187 deliverable 4, §7). A lock rather than a
    /// `var` because this class is `Sendable` by being immutable, and one hook rather than a list
    /// because there is exactly one caller: `IrisEngine.start()`, wiring the watch layer.
    private let jobsChanged = OSAllocatedUnfairLock<(@Sendable () -> Void)?>(initialState: nil)

    init(writer: any DatabaseWriter) {
        self.writer = writer
    }

    /// Installs the hook that runs after every write that can change which directories are
    /// watched. Set once, at launch; a second call replaces the first.
    func onJobsChanged(_ hook: @escaping @Sendable () -> Void) {
        jobsChanged.withLock { $0 = hook }
    }

    /// Runs the hook, if there is one. Called **after** `writer.write` returns and never inside
    /// it: the hook reads `jobs()`, and a read from inside the write would re-enter the writer
    /// this thread is already holding. Only the three writes that can change the watch set call
    /// it — `upsert`, `delete`, `setPaused` — so the cadence writers, which run every few seconds
    /// for every scheduled job, cost nothing. A write that threw never gets here: nothing changed,
    /// so there is nothing to resync.
    private func notifyJobsChanged() {
        jobsChanged.withLock { $0 }?()
    }

    /// How many rows the most recent `jobs()` call could not decode. Reset by each `jobs()` call.
    /// Read by `/jobs`, deliverable 2.
    var unreadableJobCount: Int { skippedCount.withLock { $0 } }

    // MARK: Writes

    /// Inserts `job`, or replaces the row with the same id. A rename onto another job's name
    /// surfaces as the UNIQUE violation on `name` rather than silently clobbering that job, which
    /// is why this is an `ON CONFLICT(id)` upsert and not `INSERT OR REPLACE`.
    ///
    /// Editing a job's **gate** also drops every signal its runs recorded, in the same write (#187
    /// §7). A signal is a reading taken by one gate: an ETag cannot answer for an mtime, and
    /// leaving the old one behind would have the new gate compare against something it never saw —
    /// silently "unchanged" forever, or one spurious run. Every path that changes a job goes
    /// through here, so this is the one place it has to be done.
    func upsert(_ job: Job) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let triggerJSON = String(decoding: try encoder.encode(job.trigger), as: UTF8.self)
        let policyJSON = String(decoding: try encoder.encode(job.policy), as: UTF8.self)
        try writer.write { db in
            let storedTrigger = try String.fetchOne(db, sql: "SELECT trigger FROM jobs WHERE id = ?",
                                                    arguments: [job.id.uuidString])
            try db.execute(sql: """
                INSERT INTO jobs (
                    id, name, prompt, triggerKind, trigger, profile, destinationConversationId,
                    createdInConversationId, createdAt, enabled, nextFireAt, lastRunAt, pausedReason,
                    policy, retryAttempt, queuedFire)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    name = excluded.name,
                    prompt = excluded.prompt,
                    triggerKind = excluded.triggerKind,
                    trigger = excluded.trigger,
                    profile = excluded.profile,
                    destinationConversationId = excluded.destinationConversationId,
                    createdInConversationId = excluded.createdInConversationId,
                    createdAt = excluded.createdAt,
                    enabled = excluded.enabled,
                    nextFireAt = excluded.nextFireAt,
                    lastRunAt = excluded.lastRunAt,
                    pausedReason = excluded.pausedReason,
                    policy = excluded.policy,
                    retryAttempt = excluded.retryAttempt,
                    queuedFire = excluded.queuedFire
                """, arguments: [
                    job.id.uuidString, job.name, job.prompt, job.trigger.kind, triggerJSON,
                    job.profile.rawValue, job.destinationConversationId?.uuidString,
                    job.createdInConversationId?.uuidString, job.createdAt, job.enabled,
                    job.nextFireAt, job.lastRunAt, job.pausedReason,
                    policyJSON, job.retryAttempt, job.queuedFire,
                ])
            if let storedTrigger, Self.storedGate(storedTrigger) != job.trigger.gate {
                // A stored trigger this build cannot read decodes as "no gate", so a job that
                // *gains* one clears — the safe direction, since a signal nobody can vouch for
                // costs one run rather than a gate that never fires. A job that had no gate and
                // still has none clears nothing, because there is nothing to compare against.
                try db.execute(sql: "UPDATE job_runs SET gateSignal = NULL WHERE jobId = ?",
                               arguments: [job.id.uuidString])
            }
        }
        notifyJobsChanged()
    }

    /// The gate inside a stored `trigger` column, or `nil` — for a trigger that carries none, and
    /// for one this build cannot read.
    private static func storedGate(_ json: String) -> Gate? {
        (try? JSONDecoder().decode(Trigger.self, from: Data(json.utf8)))?.gate
    }

    func delete(jobId: UUID) throws {
        try writer.write { db in
            try db.execute(sql: "DELETE FROM jobs WHERE id = ?", arguments: [jobId.uuidString])
        }
        notifyJobsChanged()
    }

    /// Records the outcome of a fire: when this job next runs and when it last ran. Leaves
    /// everything else — prompt, trigger, paused reason — untouched. Throws
    /// `JobLedgerError.unknownJob` if the job has been deleted out from under the caller, rather
    /// than updating nothing and reporting success: a scheduler that keeps re-firing a job whose
    /// row is gone should hear about it.
    func setNextFire(jobId: UUID, at: Date?, lastRunAt: Date?) throws {
        try writer.write { db in
            try db.execute(sql: "UPDATE jobs SET nextFireAt = ?, lastRunAt = ? WHERE id = ?",
                           arguments: [at, lastRunAt, jobId.uuidString])
            guard db.changesCount > 0 else { throw JobLedgerError.unknownJob(jobId) }
        }
    }

    /// Sets (or clears, with `nil`) the human-readable reason this job is not firing. Throws
    /// `JobLedgerError.unknownJob` for an id that is not in the table.
    func setPaused(jobId: UUID, reason: String?) throws {
        try writer.write { db in
            try db.execute(sql: "UPDATE jobs SET pausedReason = ? WHERE id = ?",
                           arguments: [reason, jobId.uuidString])
            guard db.changesCount > 0 else { throw JobLedgerError.unknownJob(jobId) }
        }
        notifyJobsChanged()
    }

    /// Stamps when a job last actually started a turn, without touching its cadence. The runner
    /// writes it as a run begins: the scheduler hands a trigger over before it knows whether
    /// admission will refuse it, so a refused fire must not move the field `/jobs` prints as "last
    /// run". Throws `JobLedgerError.unknownJob` for an id that is not in the table.
    func setLastRun(jobId: UUID, at: Date) throws {
        try writer.write { db in
            try db.execute(sql: "UPDATE jobs SET lastRunAt = ? WHERE id = ?",
                           arguments: [at, jobId.uuidString])
            guard db.changesCount > 0 else { throw JobLedgerError.unknownJob(jobId) }
        }
    }

    /// Records where a job is on the retry ladder and when the next attempt is due. One statement
    /// so a crash cannot leave an attempt counted with no fire scheduled, or the reverse. Throws
    /// `JobLedgerError.unknownJob` for an id that is not in the table.
    func setRetry(jobId: UUID, attempt: Int, nextFireAt: Date?) throws {
        try writer.write { db in
            try db.execute(sql: "UPDATE jobs SET retryAttempt = ?, nextFireAt = ? WHERE id = ?",
                           arguments: [attempt, nextFireAt, jobId.uuidString])
            guard db.changesCount > 0 else { throw JobLedgerError.unknownJob(jobId) }
        }
    }

    /// Remembers (or forgets, with `nil`) the one fire held back while this job's previous run was
    /// still going — `policy.overlap == .queue`. Throws `JobLedgerError.unknownJob` for an id that
    /// is not in the table.
    func setQueuedFire(jobId: UUID, at: Date?) throws {
        try writer.write { db in
            try db.execute(sql: "UPDATE jobs SET queuedFire = ? WHERE id = ?",
                           arguments: [at, jobId.uuidString])
            guard db.changesCount > 0 else { throw JobLedgerError.unknownJob(jobId) }
        }
    }

    // MARK: Reads

    /// Every job, enabled and disabled, oldest first. `rowid` breaks ties: two jobs created in the
    /// same stored millisecond still list in the order they were inserted. This is the only read
    /// that publishes `unreadableJobCount`: the scheduler's `dueJobs` poll runs every few seconds
    /// and must not overwrite what the listing reported to the UI.
    func jobs() throws -> [Job] {
        let (jobs, skipped) = try decodeAll(sql: "SELECT * FROM jobs ORDER BY createdAt, rowid", arguments: [])
        skippedCount.withLock { $0 = skipped }
        if skipped > 0 { print("[JobLedger] skipped \(skipped) unreadable job row(s)") }
        return jobs
    }

    func job(named name: String) throws -> Job? {
        try decodeAll(sql: "SELECT * FROM jobs WHERE name = ?", arguments: [name]).jobs.first
    }

    /// One job by id — what the runner re-reads after a run to see whether a trigger was queued
    /// while it was going, rather than trusting the copy it was handed when the run began.
    func job(id: UUID) throws -> Job? {
        try decodeAll(sql: "SELECT * FROM jobs WHERE id = ?", arguments: [id.uuidString]).jobs.first
    }

    /// The enabled jobs whose `nextFireAt` has arrived, soonest first. Inclusive at `now`, so a job
    /// scheduled for exactly this tick fires on it.
    func dueJobs(at now: Date) throws -> [Job] {
        try decodeAll(
            sql: """
                SELECT * FROM jobs
                WHERE enabled AND nextFireAt IS NOT NULL AND nextFireAt <= ?
                ORDER BY nextFireAt, rowid
                """,
            arguments: [now]).jobs
    }

    private func decodeAll(sql: String, arguments: StatementArguments) throws -> (jobs: [Job], skipped: Int) {
        let rows = try writer.read { db in try Row.fetchAll(db, sql: sql, arguments: arguments) }
        var jobs: [Job] = []
        var skipped = 0
        for row in rows {
            do { jobs.append(try Self.job(from: row)) } catch { skipped += 1 }
        }
        return (jobs, skipped)
    }

    /// Decodes one row, throwing `unreadableRow` for anything a `Job` cannot be built from.
    /// Identity and ordering fields (`id`, `name`, `trigger`, `createdAt`) are required: a row
    /// missing one of them would otherwise masquerade as an unnamed job at the epoch.
    private static func job(from row: Row) throws -> Job {
        let r = RowReader(row: row)
        let trigger = try JSONDecoder().decode(
            Trigger.self, from: Data(try r.required("trigger", String.self).utf8))
        return Job(
            id: try r.requiredUUID("id"),
            name: try r.required("name", String.self),
            prompt: try r.read("prompt", String.self) ?? "",
            trigger: trigger,
            profile: JobProfile(rawValue: try r.read("profile", String.self) ?? "") ?? .readOnly,
            destinationConversationId: try r.uuid("destinationConversationId"),
            createdInConversationId: try r.uuid("createdInConversationId"),
            createdAt: try r.required("createdAt", Date.self),
            enabled: try r.read("enabled", Bool.self) ?? true,
            nextFireAt: try r.read("nextFireAt", Date.self),
            lastRunAt: try r.read("lastRunAt", Date.self),
            pausedReason: try r.read("pausedReason", String.self),
            policy: Self.policy(from: row["policy"] as DatabaseValue?),
            retryAttempt: try r.read("retryAttempt", Int.self) ?? 0,
            queuedFire: try r.read("queuedFire", Date.self))
    }

    /// A NULL column, a value that is not even text, and text that will not parse all read as the
    /// default policy — never as an unreadable row. Unlike `trigger`, a policy does not decide
    /// whether the job runs at all, only what it is allowed to spend, and the defaults are the
    /// conservative answer. Taken straight off the `DatabaseValue` rather than through
    /// `RowReader.read`, which throws `unreadableRow` on a non-text value and would make exactly
    /// the row this is here to save disappear.
    private static func policy(from value: DatabaseValue?) -> JobPolicy {
        guard let value, let json = String.fromDatabaseValue(value),
              let decoded = try? JSONDecoder().decode(JobPolicy.self, from: Data(json.utf8)) else {
            return JobPolicy()
        }
        return decoded
    }
}

// MARK: - Runs

/// Runs' half of the agency ledger (#187 deliverable 2): the `job_runs` table. A run is inserted
/// `running` by the background runner, closed once by `finish`, and read back by the event card,
/// `get_job_run` and `/jobs`.
///
/// Reads are as lenient as the job reads above: a row that cannot be decoded is skipped rather
/// than failing the listing, so one bad row cannot hide every other run. (A skipped row is also
/// invisible to `prune`, which is the safe direction: it is never deleted by mistake.)
extension JobLedger {
    // MARK: Writes

    /// Records a run that has just started. The `jobId` foreign key means a run cannot outlive its
    /// job: deleting the job cascades its runs away.
    func begin(run: JobRun) throws {
        let blockedCallJSON = try run.blockedCall.map { try Self.encodeBlockedCall($0) }
        let watchSummaryJSON = try run.watchSummary.map { try Self.encodeJSON($0) }
        try writer.write { db in
            try db.execute(sql: """
                INSERT INTO job_runs (
                    id, jobId, jobName, triggerKind, startedAt, finishedAt, status, outcome,
                    failureReason, blockedTool, promptTokens, candidateTokens, totalTokens,
                    costMicros, gateSignal, transcriptConversationId, acknowledgedAt,
                    blockedCall, approvedAt, parentRunId, watchSummary)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [
                    run.id.uuidString, run.jobId.uuidString, run.jobName, run.triggerKind,
                    run.startedAt, run.finishedAt, run.status.rawValue, run.outcome,
                    run.failureReason, run.blockedTool, run.promptTokens, run.candidateTokens,
                    run.totalTokens, run.costMicros, run.gateSignal,
                    run.transcriptConversationId?.uuidString, run.acknowledgedAt,
                    blockedCallJSON, run.approvedAt, run.parentRunId?.uuidString,
                    watchSummaryJSON,
                ])
        }
    }

    /// Closes a run: its terminal status, what came of it, and what it cost. `outcome` is one line
    /// on a card, so it is truncated to 200 characters here rather than trusting every caller to
    /// do it. Throws `JobLedgerError.unknownRun` when the row is gone (its job was deleted
    /// mid-run), for the same reason `setNextFire` does: a runner writing into nothing should hear
    /// about it.
    func finish(runId: UUID, status: JobRun.Status, outcome: String?, failureReason: String?,
                blockedTool: String?, tokens: TokenUsage, finishedAt: Date) throws {
        let trimmed = outcome.map { String($0.prefix(200)) }
        try writer.write { db in
            try db.execute(sql: """
                UPDATE job_runs SET
                    status = ?, outcome = ?, failureReason = ?, blockedTool = ?,
                    promptTokens = ?, candidateTokens = ?, totalTokens = ?, finishedAt = ?
                WHERE id = ?
                """, arguments: [
                    status.rawValue, trimmed, failureReason, blockedTool,
                    tokens.promptTokenCount, tokens.candidatesTokenCount, tokens.totalTokenCount,
                    finishedAt, runId.uuidString,
                ])
            guard db.changesCount > 0 else { throw JobLedgerError.unknownRun(runId) }
        }
    }

    /// Writes what a run has spent so far without closing it — called after every model round
    /// (`TurnUsageSink`). `tokensToday` sums `totalTokens`, which `finish` used to be the only
    /// writer of, so a run the app quit in the middle of left an `interrupted` row costed at zero
    /// and its spend counted against nobody's budget.
    ///
    /// `status = 'running'` in the WHERE clause, and no `unknownRun` throw: a turn the deadline
    /// already gave up on goes on running, and its next round must not write over the `failed` row
    /// the timeout wrote. A no-op is the expected answer here, not an error.
    func recordUsage(runId: UUID, tokens: TokenUsage) throws {
        try writer.write { db in
            try db.execute(sql: """
                UPDATE job_runs SET promptTokens = ?, candidateTokens = ?, totalTokens = ?
                WHERE id = ? AND status = ?
                """, arguments: [
                    tokens.promptTokenCount, tokens.candidatesTokenCount, tokens.totalTokenCount,
                    runId.uuidString, JobRun.Status.running.rawValue,
                ])
        }
    }

    /// Marks a failed or blocked run as seen, taking it out of `unacknowledgedFailures()` and out
    /// of retention's exemption. Throws `JobLedgerError.unknownRun` for an id that is not in the
    /// table.
    func acknowledge(runId: UUID, at: Date) throws {
        try writer.write { db in
            try db.execute(sql: "UPDATE job_runs SET acknowledgedAt = ? WHERE id = ?",
                           arguments: [at, runId.uuidString])
            guard db.changesCount > 0 else { throw JobLedgerError.unknownRun(runId) }
        }
    }

    /// Persists (or clears, with `nil`) the exact call this run failed closed on, so the card can
    /// show every argument and "Approve and run" can dispatch it. Throws
    /// `JobLedgerError.unknownRun` for an id that is not in the table. `JobRunner` writes one when
    /// a run ends `blockedOnApproval`, whether nobody was there to approve the call or the job's
    /// `readOnly` profile forbade it outright.
    func setBlockedCall(runId: UUID, _ call: BlockedCall?) throws {
        let json = try call.map { try Self.encodeBlockedCall($0) }
        try writer.write { db in
            try db.execute(sql: "UPDATE job_runs SET blockedCall = ? WHERE id = ?",
                           arguments: [json, runId.uuidString])
            guard db.changesCount > 0 else { throw JobLedgerError.unknownRun(runId) }
        }
    }

    /// Claims this run's blocked call for exactly one dispatch. `true` means the caller won the
    /// claim and owns running the call; `false` means it was already approved, the row is gone, or
    /// the call is one no approval can authorise. The `approvedAt IS NULL` guard is in the
    /// `UPDATE` itself rather than a read-then-write, so two clicks on the same card — or two
    /// processes — cannot both see it unapproved and run the call twice.
    ///
    /// A `.profile` blocked call is refused outright (R13): it was not refused for want of a human
    /// but because the job is `readOnly`, and re-dispatching it would reopen the profile gate
    /// through the ledger. So is a stored call this build cannot read: "there is a blocked call
    /// and I do not know what it is" is not a thing to approve, and the same direction is what
    /// `ConversationStore` takes for an unreadable `jobProfile`. So, finally, is a row with no
    /// blocked call at all — a completed run, or one whose call failed to store — because burning
    /// `approvedAt` on a row with nothing to approve turns the one-shot into a wasted shot. The
    /// refusals live here rather than only in whatever UI offers the button, so a second caller
    /// cannot get them wrong.
    ///
    /// Winning the claim also acknowledges the row, in the same `UPDATE`: approving a blocked call
    /// is a stronger "I have seen this" than Dismiss is, and without it an approved-and-executed
    /// run would sit in `/jobs`'s failure list and stay exempt from retention forever, its card
    /// still offering a button that now answers "it has already been approved once". `COALESCE`
    /// so a row the user dismissed first keeps the time they dismissed it.
    func markApproved(runId: UUID, at: Date) throws -> Bool {
        try writer.write { db in
            let json = try String.fetchOne(db, sql: "SELECT blockedCall FROM job_runs WHERE id = ?",
                                           arguments: [runId.uuidString])
            guard let json else { return false }
            let call = try? JSONDecoder().decode(BlockedCall.self, from: Data(json.utf8))
            guard let call, call.reason != .profile else { return false }
            try db.execute(sql: """
                UPDATE job_runs SET approvedAt = ?, acknowledgedAt = COALESCE(acknowledgedAt, ?)
                WHERE id = ? AND approvedAt IS NULL
                """, arguments: [at, at, runId.uuidString])
            return db.changesCount > 0
        }
    }

    /// Records what this run's gate saw, for the next run to compare against — the built-in gates
    /// are handed it back as `previous` at the next tick, and the comparison is the verdict. Throws
    /// `JobLedgerError.unknownRun` for an id that is not in the table.
    func setGateSignal(runId: UUID, _ signal: String?) throws {
        try writer.write { db in
            try db.execute(sql: "UPDATE job_runs SET gateSignal = ? WHERE id = ?",
                           arguments: [signal, runId.uuidString])
            guard db.changesCount > 0 else { throw JobLedgerError.unknownRun(runId) }
        }
    }

    private static func encodeBlockedCall(_ call: BlockedCall) throws -> String {
        try encodeJSON(call)
    }

    /// One JSON column's value, keys sorted the way `upsert` writes `trigger` and `policy` — so a
    /// column that did not change is byte-identical from one write to the next.
    static func encodeJSON<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    /// Closes out every run still marked `running` — at launch, those are runs the last process
    /// died in the middle of, and nothing will ever finish them. Returns how many were closed.
    func closeRunningRuns(reason: String, at: Date) throws -> Int {
        try writer.write { db in
            try db.execute(sql: """
                UPDATE job_runs SET status = ?, failureReason = ?, finishedAt = ? WHERE status = ?
                """, arguments: [
                    JobRun.Status.interrupted.rawValue, reason, at, JobRun.Status.running.rawValue,
                ])
            return db.changesCount
        }
    }

    // MARK: Reads

    func run(id: UUID) throws -> JobRun? {
        try decodeRuns(sql: "SELECT * FROM job_runs WHERE id = ?", arguments: [id.uuidString]).first
    }

    /// One job's runs, newest first. `rowid` breaks ties so two runs that started in the same
    /// stored millisecond still list in the order they were inserted.
    func runs(jobId: UUID, limit: Int) throws -> [JobRun] {
        try decodeRuns(
            sql: "SELECT * FROM job_runs WHERE jobId = ? ORDER BY startedAt DESC, rowid DESC LIMIT ?",
            arguments: [jobId.uuidString, limit])
    }

    /// How many runs a job has, optionally only those in one status. A count, not a listing: the
    /// two callers (`/jobs delete`, which reports what is about to go and refuses while something
    /// is still running) want a number, and decoding every row of a long-lived job's history to
    /// take `.count` of it is work thrown away.
    func runCount(jobId: UUID, status: JobRun.Status? = nil) throws -> Int {
        try writer.read { db in
            if let status {
                return try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM job_runs WHERE jobId = ? AND status = ?",
                                        arguments: [jobId.uuidString, status.rawValue]) ?? 0
            }
            return try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM job_runs WHERE jobId = ?",
                                    arguments: [jobId.uuidString]) ?? 0
        }
    }

    /// The runs whose id starts with `idPrefix`, hyphens ignored on both sides — what resolves the
    /// eight characters an event card prints (`JobsCommand.resolveRun`). A query rather than a
    /// filter over a recent-runs window: an unacknowledged failure is exempt from retention and
    /// can be arbitrarily old, so the one id a person is chasing is exactly the one such a window
    /// would hide.
    ///
    /// Capped at `prefixMatchLimit`, which is only ever used to tell "one" from "more than one".
    func runs(idPrefix: String) throws -> [JobRun] {
        let needle = JobsCommand.normalizedRunId(idPrefix)
        guard !needle.isEmpty else { return [] }
        // `LOWER` on the column rather than leaning on SQLite's ASCII-case-insensitive LIKE:
        // `normalizedRunId` has already lowercased the needle, and an id is stored uppercased, so
        // the match is only case-insensitive by a default a `PRAGMA case_sensitive_like` could
        // change under it.
        //
        // The prefix reaches here from a person's or a model's typing, so `%` and `_` in it must
        // be literals rather than wildcards that would match every run in the table.
        let escaped = needle
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        return try decodeRuns(
            sql: """
                SELECT * FROM job_runs WHERE LOWER(REPLACE(id, '-', '')) LIKE ? ESCAPE '\\'
                ORDER BY startedAt DESC, rowid DESC LIMIT ?
                """,
            arguments: [escaped + "%", Self.prefixMatchLimit])
    }

    /// How many prefix matches are read back. More than one is already ambiguous, so the rest are
    /// rows nobody will look at.
    static let prefixMatchLimit = 8

    /// The runs still waiting on a person: failed or blocked and never acknowledged, oldest first
    /// so the longest-ignored one leads.
    func unacknowledgedFailures() throws -> [JobRun] {
        try decodeRuns(
            sql: """
                SELECT * FROM job_runs
                WHERE status IN (?, ?) AND acknowledgedAt IS NULL
                ORDER BY startedAt, rowid
                """,
            arguments: [JobRun.Status.failed.rawValue, JobRun.Status.blockedOnApproval.rawValue])
    }

    /// How many of this job's runs started a turn at or after `since` — the breaker's question,
    /// asked with `since = now - 1h`. Inclusive at the boundary, like `dueJobs`.
    ///
    /// Only rows with a transcript count. A skip row and a pause row are runs that never happened
    /// (`recordStillborn` writes them with no conversation), and counting them would have the
    /// breaker trip on its own refusals: a `.skip` job overlapping itself six times, or a job
    /// resumed by hand after a breaker pause, would be paused again by the rows that recorded the
    /// pause. The breaker is a limit on work done, not on triggers received.
    func runsStarted(jobId: UUID, since: Date) throws -> Int {
        try writer.read { db in try Self.runsStarted(db, jobId: jobId, since: since) }
    }

    private static func runsStarted(_ db: Database, jobId: UUID, since: Date) throws -> Int {
        try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM job_runs
            WHERE jobId = ? AND startedAt >= ? AND transcriptConversationId IS NOT NULL
            """, arguments: [jobId.uuidString, since]) ?? 0
    }

    /// The tokens spent on runs that *started* during the local calendar day containing `now`, for
    /// one job or (with `jobId: nil`) every job — the per-job and global daily budgets, spec §10.
    /// The day is `calendar`'s, so the boundary is the user's local midnight and a caller can pin
    /// the zone in a test.
    ///
    /// Attributed by start, not by finish: a run that began before midnight and ended after it
    /// belongs to the day it was admitted on, which is the day whose budget let it start.
    ///
    /// A run still in flight counts what it has reported: `recordUsage` writes the running total
    /// onto the row after every model round, so the day's figure is at worst one round behind
    /// rather than blind until the run ends — and a run the app quit during still costs the day
    /// what it spent. A burst of concurrent runs can still overshoot the daily figure by up to one
    /// round apiece, which the per-run budget bounds (§4, "during a run").
    func tokensToday(jobId: UUID?, calendar: Calendar, now: Date) throws -> Int {
        try writer.read { db in try Self.tokensToday(db, jobId: jobId, calendar: calendar, now: now) }
    }

    private static func tokensToday(_ db: Database, jobId: UUID?, calendar: Calendar, now: Date) throws -> Int {
        let dayStart = calendar.startOfDay(for: now)
        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else { return 0 }
        if let jobId {
            return try Int.fetchOne(db, sql: """
                SELECT COALESCE(SUM(totalTokens), 0) FROM job_runs
                WHERE jobId = ? AND startedAt >= ? AND startedAt < ?
                """, arguments: [jobId.uuidString, dayStart, dayEnd]) ?? 0
        }
        return try Int.fetchOne(db, sql: """
            SELECT COALESCE(SUM(totalTokens), 0) FROM job_runs
            WHERE startedAt >= ? AND startedAt < ?
            """, arguments: [dayStart, dayEnd]) ?? 0
    }

    /// Both of a job's live figures in one call: what admission decides on, what a budget or
    /// breaker pause names on the row, the reason and the card, and what `/jobs` and `list_jobs`
    /// print in their usage columns (spec §9). Nothing but the two queries above, so the numbers a
    /// person reads are the ones admission decided on rather than a second, drifting accounting.
    ///
    /// One `read`, so both figures come from one snapshot: a run finishing between two separate
    /// reads would otherwise let a card print a token total that the run count it sits beside does
    /// not include.
    func usage(jobId: UUID, now: Date, calendar: Calendar) throws -> JobUsage {
        try writer.read { db in
            JobUsage(tokensToday: try Self.tokensToday(db, jobId: jobId, calendar: calendar, now: now),
                     runsLastHour: try Self.runsStarted(db, jobId: jobId, since: now.addingTimeInterval(-3600)))
        }
    }

    /// The newest gate signal this job recorded, or `nil` if it has never recorded one — a job
    /// whose first tick has not happened yet, or one with no gate at all. Rows with
    /// no signal are skipped rather than answering `nil`: a gate that errored or a run that
    /// predates the gate writes nothing, and the question being asked is "what did we last see?",
    /// which such a row does not answer.
    func lastGateSignal(jobId: UUID) throws -> String? {
        try writer.read { db in
            try String.fetchOne(db, sql: """
                SELECT gateSignal FROM job_runs WHERE jobId = ? AND gateSignal IS NOT NULL
                ORDER BY startedAt DESC, rowid DESC LIMIT 1
                """, arguments: [jobId.uuidString])
        }
    }

    /// The newest watch summary the job has written — `/jobs`'s `last burst:` and `list_jobs`'s
    /// `lastBurst`. Rows without one are skipped rather than answering `nil`: a hand-started fire
    /// of a watch job writes a row and no summary, and the question is "what did the last burst
    /// see?", which such a row does not answer. `nil` only when no burst has ever fired. Same
    /// shape as `lastGateSignal`, and the same lenient decode as `run(from:)`: a blob this build
    /// cannot read is no burst, not an error.
    func lastWatchSummary(jobId: UUID) throws -> WatchSummary? {
        let json = try writer.read { db in
            try String.fetchOne(db, sql: """
                SELECT watchSummary FROM job_runs WHERE jobId = ? AND watchSummary IS NOT NULL
                ORDER BY startedAt DESC, rowid DESC LIMIT 1
                """, arguments: [jobId.uuidString])
        }
        guard let json else { return nil }
        return try? JSONDecoder().decode(WatchSummary.self, from: Data(json.utf8))
    }

    private func decodeRuns(sql: String, arguments: StatementArguments) throws -> [JobRun] {
        let rows = try writer.read { db in try Row.fetchAll(db, sql: sql, arguments: arguments) }
        return Self.decodeRuns(rows)
    }

    private static func decodeRuns(_ rows: [Row]) -> [JobRun] {
        var runs: [JobRun] = []
        var skipped = 0
        for row in rows {
            do { runs.append(try Self.run(from: row)) } catch { skipped += 1 }
        }
        if skipped > 0 { print("[JobLedger] skipped \(skipped) unreadable job run row(s)") }
        return runs
    }

    /// Decodes one row the same way `job(from:)` does — every column through `DatabaseValue`,
    /// never the trapping typed subscript. `id`, `jobId`, `jobName`, `triggerKind`, `startedAt`
    /// and a recognized `status` are required: without them there is no run to show.
    private static func run(from row: Row) throws -> JobRun {
        let r = RowReader(row: row)
        let statusText = try r.required("status", String.self)
        guard let status = JobRun.Status(rawValue: statusText) else {
            throw JobLedgerError.unreadableRow("unreadable status")
        }
        var run = JobRun(
            id: try r.requiredUUID("id"),
            jobId: try r.requiredUUID("jobId"),
            jobName: try r.required("jobName", String.self),
            triggerKind: try r.required("triggerKind", String.self),
            startedAt: try r.required("startedAt", Date.self),
            status: status,
            transcriptConversationId: try r.uuid("transcriptConversationId"))
        run.finishedAt = try r.read("finishedAt", Date.self)
        run.outcome = try r.read("outcome", String.self)
        run.failureReason = try r.read("failureReason", String.self)
        run.blockedTool = try r.read("blockedTool", String.self)
        run.promptTokens = try r.read("promptTokens", Int.self) ?? 0
        run.candidateTokens = try r.read("candidateTokens", Int.self) ?? 0
        run.totalTokens = try r.read("totalTokens", Int.self) ?? 0
        run.costMicros = try r.read("costMicros", Int64.self)
        run.gateSignal = try r.read("gateSignal", String.self)
        run.acknowledgedAt = try r.read("acknowledgedAt", Date.self)
        // A blocked call that will not decode reads as absent, never as a reason to skip the row:
        // the run itself — that it happened, that it was blocked, what it cost — is the part a
        // person needs, and hiding it would hide the notification too. The card then shows a
        // blocked run it cannot offer an "Approve and run" for, which is the safe direction.
        if let json = try r.read("blockedCall", String.self) {
            run.blockedCall = try? JSONDecoder().decode(BlockedCall.self, from: Data(json.utf8))
        }
        run.approvedAt = try r.read("approvedAt", Date.self)
        run.parentRunId = try r.uuid("parentRunId")
        // Same idiom as `blockedCall`, and for the same reason: the figures a burst produced are
        // worth less than the run itself, so a summary that will not decode reads as absent and
        // the card simply shows no watch line.
        if let json = try r.read("watchSummary", String.self) {
            run.watchSummary = try? JSONDecoder().decode(WatchSummary.self, from: Data(json.utf8))
        }
        return run
    }

    // MARK: Retention

    /// What a prune would remove. Transcripts are conversation ids: `prune` deletes the `job_runs`
    /// rows itself, and hands the transcripts to a caller that owns conversations.
    struct PruneDecision: Equatable, Sendable {
        let deleteRunIds: [UUID]
        let deleteTranscriptIds: [UUID]
    }

    /// The retention rule (spec §10), kept pure so it can be reasoned about and tested without a
    /// database: rows age out after `rowRetention`, and each job keeps only its `transcriptsPerJob`
    /// newest transcripts. Both are overridden by the same exemption — a failed or blocked run
    /// nobody has acknowledged keeps its row *and* its transcript, however old, because the
    /// evidence is the point of the notification. A `running` row is exempt on the same terms: it
    /// is either in flight right now or an orphan `closeRunningRuns` resolves at the next launch,
    /// and deleting it would either pull the transcript out from under a live run or leave the
    /// orphan permanently unresolvable.
    ///
    /// A deleted row's transcript goes with it unless a surviving row still names the same
    /// conversation, which today's writers never do; the check is there so a future one cannot
    /// pull a transcript out from under a run that is still listed.
    ///
    /// The order `runs` arrives in does not matter: everything is decided against `startedAt` with
    /// the run id breaking ties, and both returned arrays come back oldest first.
    static func pruneDecision(runs: [JobRun], now: Date, rowRetention: TimeInterval,
                              transcriptsPerJob: Int) -> PruneDecision {
        let cutoff = now.addingTimeInterval(-rowRetention)
        // Exempt from both halves of retention: a run still in flight (or an orphan awaiting
        // `closeRunningRuns`), and a failure nobody has acknowledged.
        func isExempt(_ run: JobRun) -> Bool {
            if run.status == .running { return true }
            return (run.status == .failed || run.status == .blockedOnApproval) && run.acknowledgedAt == nil
        }

        // Oldest first, ties broken by id, so the decision is a function of the rows alone: two
        // callers that fetched the same runs in different orders get the same arrays back.
        let ordered = runs.sorted { ($0.startedAt, $0.id.uuidString) < ($1.startedAt, $1.id.uuidString) }
        let deletedRunIds = Set(ordered.filter { $0.startedAt < cutoff && !isExempt($0) }.map(\.id))

        // Runs whose transcript is no longer worth keeping: the row is going away, or the run has
        // fallen out of its job's newest `transcriptsPerJob`.
        var doomedRunIds = Set(ordered
            .filter { deletedRunIds.contains($0.id) && $0.transcriptConversationId != nil }.map(\.id))
        let withTranscripts = ordered.filter { $0.transcriptConversationId != nil }
        for (_, jobRuns) in Dictionary(grouping: withTranscripts, by: \.jobId) {
            let newestFirst = jobRuns.reversed()
            for run in newestFirst.dropFirst(max(0, transcriptsPerJob)) where !isExempt(run) {
                doomedRunIds.insert(run.id)
            }
        }
        let stillReferenced = Set(ordered.filter { !doomedRunIds.contains($0.id) }
            .compactMap(\.transcriptConversationId))

        var deleteTranscriptIds: [UUID] = []
        var seen = Set<UUID>()
        for run in ordered {
            guard doomedRunIds.contains(run.id), let transcript = run.transcriptConversationId,
                  !stillReferenced.contains(transcript), seen.insert(transcript).inserted else { continue }
            deleteTranscriptIds.append(transcript)
        }
        return PruneDecision(deleteRunIds: ordered.filter { deletedRunIds.contains($0.id) }.map(\.id),
                             deleteTranscriptIds: deleteTranscriptIds)
    }

    /// Applies `pruneDecision` to the table in one transaction and returns it. Only `job_runs`
    /// rows are deleted here: the conversations named by `deleteTranscriptIds` belong to the
    /// caller, which deletes them (and can survive a crash in between — the rows are gone, and the
    /// orphaned transcripts are ordinary conversations).
    /// Ids bound per `DELETE`. Well under the 999 the oldest SQLite builds cap a statement at, so
    /// the chunking does not depend on which SQLite the app links.
    static let deleteChunkSize = 500

    func prune(now: Date, rowRetention: TimeInterval, transcriptsPerJob: Int) throws -> PruneDecision {
        try writer.write { db in
            let rows = try Row.fetchAll(db, sql: "SELECT * FROM job_runs ORDER BY startedAt, rowid")
            let decision = Self.pruneDecision(runs: Self.decodeRuns(rows), now: now,
                                              rowRetention: rowRetention,
                                              transcriptsPerJob: transcriptsPerJob)
            // Chunked, inside the one transaction: a single `IN (...)` over every expired row
            // binds one variable per id, and a Mac with a few months of run history past its
            // retention window — exactly the case this exists for — would blow
            // `SQLITE_MAX_VARIABLE_NUMBER` and prune nothing at all.
            for chunk in stride(from: 0, to: decision.deleteRunIds.count, by: Self.deleteChunkSize) {
                let ids = decision.deleteRunIds[chunk..<min(chunk + Self.deleteChunkSize,
                                                            decision.deleteRunIds.count)]
                let placeholders = databaseQuestionMarks(count: ids.count)
                try db.execute(sql: "DELETE FROM job_runs WHERE id IN (\(placeholders))",
                               arguments: StatementArguments(ids.map(\.uuidString)))
            }
            return decision
        }
    }
}

/// Reads a row's columns through `DatabaseValue` rather than GRDB's typed subscript, which traps
/// on a value it cannot convert — a hand-edited or newer-schema row must skip the row, never crash
/// the app.
private struct RowReader {
    let row: Row

    func read<T: DatabaseValueConvertible>(_ column: String, _ type: T.Type = T.self) throws -> T? {
        guard let value = row[column] as DatabaseValue?, !value.isNull else { return nil }
        guard let decoded = T.fromDatabaseValue(value) else {
            throw JobLedgerError.unreadableRow("unreadable \(column)")
        }
        return decoded
    }

    func required<T: DatabaseValueConvertible>(_ column: String, _ type: T.Type = T.self) throws -> T {
        guard let value = try read(column, T.self) else {
            throw JobLedgerError.unreadableRow("missing \(column)")
        }
        return value
    }

    /// An optional id column: absent *or* unparseable reads as `nil`, because a stale reference is
    /// not worth dropping a whole row over.
    func uuid(_ column: String) throws -> UUID? {
        guard let text: String = try read(column, String.self) else { return nil }
        return UUID(uuidString: text)
    }

    /// An id the row cannot be understood without.
    func requiredUUID(_ column: String) throws -> UUID {
        guard let id = UUID(uuidString: try required(column, String.self)) else {
            throw JobLedgerError.unreadableRow("unreadable \(column)")
        }
        return id
    }
}

/// What one job has spent and how hard it has been running (#187 deliverable 3, spec §9): the two
/// figures admission decides on, and the two `/jobs` and `list_jobs` print beside every job.
struct JobUsage: Equatable, Sendable {
    let tokensToday: Int
    let runsLastHour: Int
}

enum JobLedgerError: Error, Equatable {
    /// A row that cannot be turned into a `Job`; the string names the offending column. Skipped by
    /// `jobs()` and counted into `unreadableJobCount`, never surfaced to a caller.
    case unreadableRow(String)
    /// An update named a job id that is not in the table.
    case unknownJob(UUID)
    /// An update named a run id that is not in the table.
    case unknownRun(UUID)
}
