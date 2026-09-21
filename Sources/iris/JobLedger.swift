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

    /// Decodes one row, throwing `unreadableRow` for anything a `Job` cannot be built from. Every
    /// column is read through `DatabaseValue` rather than GRDB's typed subscript, which traps on a
    /// value it cannot convert — a hand-edited or newer-schema row must skip the job, never crash
    /// the app. Identity and ordering fields (`id`, `name`, `trigger`, `createdAt`) are required:
    /// a row missing one of them would otherwise masquerade as an unnamed job at the epoch.
    private static func job(from row: Row) throws -> Job {
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

        guard let id = UUID(uuidString: try required("id", String.self)) else {
            throw JobLedgerError.unreadableRow("unreadable id")
        }
        let trigger = try JSONDecoder().decode(
            Trigger.self, from: Data(try required("trigger", String.self).utf8))
        return Job(
            id: id,
            name: try required("name", String.self),
            prompt: try read("prompt", String.self) ?? "",
            trigger: trigger,
            profile: JobProfile(rawValue: try read("profile", String.self) ?? "") ?? .readOnly,
            destinationConversationId: (try read("destinationConversationId", String.self)).flatMap(UUID.init(uuidString:)),
            createdInConversationId: (try read("createdInConversationId", String.self)).flatMap(UUID.init(uuidString:)),
            createdAt: try required("createdAt", Date.self),
            enabled: try read("enabled", Bool.self) ?? true,
            nextFireAt: try read("nextFireAt", Date.self),
            lastRunAt: try read("lastRunAt", Date.self),
            pausedReason: try read("pausedReason", String.self))
    }
}

enum JobLedgerError: Error, Equatable {
    /// A row that cannot be turned into a `Job`; the string names the offending column. Skipped by
    /// `jobs()` and counted into `unreadableJobCount`, never surfaced to a caller.
    case unreadableRow(String)
    /// An update named a job id that is not in the table.
    case unknownJob(UUID)
}
