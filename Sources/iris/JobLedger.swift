import Foundation
import GRDB
import os

/// Jobs' half of the agency ledger (#187 deliverable 1): the `jobs` table, read and written
/// through the conversation store's own writer so a job and the conversation it produces commit
/// against one database. Scalar `Job` fields are columns — the scheduler queries `enabled` and
/// `nextFireAt` directly — while `trigger`, the one open-ended field, is stored as JSON.
///
/// Reads are deliberately lenient: a row whose `trigger` JSON no longer decodes (a kind written by
/// a newer build, a hand-edited row) is skipped rather than failing the whole listing, so one bad
/// job cannot stop every other job from running. `unreadableJobCount` reports how many the last
/// `jobs()` call skipped.
final class JobLedger: Sendable {
    private let writer: any DatabaseWriter
    private let skippedCount = OSAllocatedUnfairLock(initialState: 0)

    init(writer: any DatabaseWriter) {
        self.writer = writer
    }

    /// How many rows the most recent `jobs()` call could not decode. Reset by each `jobs()` call.
    /// Read by `/jobs`, deliverable 2.
    var unreadableJobCount: Int { skippedCount.withLock { $0 } }

    // MARK: Writes

    /// Inserts `job`, or replaces the row with the same id. A rename onto another job's name
    /// surfaces as the UNIQUE violation on `name` rather than silently clobbering that job, which
    /// is why this is an `ON CONFLICT(id)` upsert and not `INSERT OR REPLACE`.
    func upsert(_ job: Job) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let triggerJSON = String(decoding: try encoder.encode(job.trigger), as: UTF8.self)
        try writer.write { db in
            try db.execute(sql: """
                INSERT INTO jobs (
                    id, name, prompt, triggerKind, trigger, profile, destinationConversationId,
                    createdInConversationId, createdAt, enabled, nextFireAt, lastRunAt, pausedReason)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
                    pausedReason = excluded.pausedReason
                """, arguments: [
                    job.id.uuidString, job.name, job.prompt, job.trigger.kind, triggerJSON,
                    job.profile.rawValue, job.destinationConversationId?.uuidString,
                    job.createdInConversationId?.uuidString, job.createdAt, job.enabled,
                    job.nextFireAt, job.lastRunAt, job.pausedReason,
                ])
        }
    }

    func delete(jobId: UUID) throws {
        try writer.write { db in
            try db.execute(sql: "DELETE FROM jobs WHERE id = ?", arguments: [jobId.uuidString])
        }
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
            pausedReason: try r.read("pausedReason", String.self))
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
        try writer.write { db in
            try db.execute(sql: """
                INSERT INTO job_runs (
                    id, jobId, jobName, triggerKind, startedAt, finishedAt, status, outcome,
                    failureReason, blockedTool, promptTokens, candidateTokens, totalTokens,
                    costMicros, gateSignal, transcriptConversationId, acknowledgedAt)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [
                    run.id.uuidString, run.jobId.uuidString, run.jobName, run.triggerKind,
                    run.startedAt, run.finishedAt, run.status.rawValue, run.outcome,
                    run.failureReason, run.blockedTool, run.promptTokens, run.candidateTokens,
                    run.totalTokens, run.costMicros, run.gateSignal,
                    run.transcriptConversationId?.uuidString, run.acknowledgedAt,
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

enum JobLedgerError: Error, Equatable {
    /// A row that cannot be turned into a `Job`; the string names the offending column. Skipped by
    /// `jobs()` and counted into `unreadableJobCount`, never surfaced to a caller.
    case unreadableRow(String)
    /// An update named a job id that is not in the table.
    case unknownJob(UUID)
    /// An update named a run id that is not in the table.
    case unknownRun(UUID)
}
