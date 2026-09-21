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
    /// everything else — prompt, trigger, paused reason — untouched.
    func setNextFire(jobId: UUID, at: Date?, lastRunAt: Date?) throws {
        try writer.write { db in
            try db.execute(sql: "UPDATE jobs SET nextFireAt = ?, lastRunAt = ? WHERE id = ?",
                           arguments: [at, lastRunAt, jobId.uuidString])
        }
    }

    /// Sets (or clears, with `nil`) the human-readable reason this job is not firing.
    func setPaused(jobId: UUID, reason: String?) throws {
        try writer.write { db in
            try db.execute(sql: "UPDATE jobs SET pausedReason = ? WHERE id = ?",
                           arguments: [reason, jobId.uuidString])
        }
    }

    // MARK: Reads

    /// Every job, enabled and disabled, oldest first. `rowid` breaks ties: two jobs created in the
    /// same stored millisecond still list in the order they were inserted.
    func jobs() throws -> [Job] {
        try decodeAll(sql: "SELECT * FROM jobs ORDER BY createdAt, rowid", arguments: [])
    }

    func job(named name: String) throws -> Job? {
        try decodeAll(sql: "SELECT * FROM jobs WHERE name = ?", arguments: [name]).first
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
            arguments: [now])
    }

    private func decodeAll(sql: String, arguments: StatementArguments) throws -> [Job] {
        let rows = try writer.read { db in try Row.fetchAll(db, sql: sql, arguments: arguments) }
        var jobs: [Job] = []
        var skipped = 0
        for row in rows {
            do { jobs.append(try Self.job(from: row)) } catch { skipped += 1 }
        }
        let total = skipped
        skippedCount.withLock { $0 = total }
        if skipped > 0 { print("[JobLedger] skipped \(skipped) unreadable job row(s)") }
        return jobs
    }

    private static func job(from row: Row) throws -> Job {
        guard let idString: String = row["id"], let id = UUID(uuidString: idString) else {
            throw JobLedgerError.unreadableRow("bad id")
        }
        guard let triggerJSON: String = row["trigger"] else {
            throw JobLedgerError.unreadableRow("missing trigger")
        }
        let trigger = try JSONDecoder().decode(Trigger.self, from: Data(triggerJSON.utf8))
        return Job(
            id: id,
            name: row["name"] ?? "",
            prompt: row["prompt"] ?? "",
            trigger: trigger,
            profile: JobProfile(rawValue: row["profile"] ?? "") ?? .readOnly,
            destinationConversationId: (row["destinationConversationId"] as String?).flatMap(UUID.init(uuidString:)),
            createdInConversationId: (row["createdInConversationId"] as String?).flatMap(UUID.init(uuidString:)),
            createdAt: row["createdAt"] ?? Date(timeIntervalSince1970: 0),
            enabled: row["enabled"] ?? true,
            nextFireAt: row["nextFireAt"],
            lastRunAt: row["lastRunAt"],
            pausedReason: row["pausedReason"])
    }
}

enum JobLedgerError: Error {
    case unreadableRow(String)
}
