import Testing
import Foundation
import GRDB
@testable import iris

/// Migration `v11_watches`: the `job_runs.watchSummary` column and the canonical rewrite of every
/// stored watch root. In-memory stores only (invariant 7); the symlink case makes its own temp
/// directory and removes it.
@Suite("Watch migration v11")
struct WatchMigrationTests {
    let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    /// A v10 database with the columns the jobs and runs tables had before v11.
    private func v10Database() throws -> DatabaseQueue {
        let queue = try DatabaseQueue()
        try ConversationStore.migrator.migrate(queue, upTo: "v10_job_policy")
        return queue
    }

    private func insertJob(_ db: Database, id: UUID, name: String, kind: String, trigger: String) throws {
        try db.execute(sql: """
            INSERT INTO jobs (id, name, prompt, triggerKind, trigger, profile, createdAt, enabled)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [id.uuidString, name, "p", kind, trigger, "readOnly", t0, true])
    }

    private func watchTrigger(path: String) -> String {
        #"{"kind":"fsEvent","watch":{"path":"\#(path)","quietWindowSeconds":3}}"#
    }

    private func storedPath(_ queue: DatabaseQueue) throws -> String? {
        let ledger = JobLedger(writer: queue)
        guard case .fsEvent(let watch)? = try ledger.jobs().first?.trigger else { return nil }
        return watch.path
    }

    @Test("v11 adds the column and keeps every existing row")
    func v11AddsTheColumnAndKeepsRows() throws {
        let queue = try v10Database()
        let jobId = UUID(), runId = UUID()
        try queue.write { db in
            try insertJob(db, id: jobId, name: "nightly", kind: "schedule",
                          trigger: #"{"kind":"schedule","schedule":{"kind":"interval","seconds":60}}"#)
            try db.execute(sql: """
                INSERT INTO job_runs (id, jobId, jobName, triggerKind, startedAt, status,
                                      promptTokens, candidateTokens, totalTokens)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [runId.uuidString, jobId.uuidString, "nightly", "schedule", t0,
                                 "completed", 1, 2, 3])
        }

        try ConversationStore.migrator.migrate(queue)

        let ledger = JobLedger(writer: queue)
        #expect(try ledger.jobs().map(\.name) == ["nightly"])
        let run = try #require(try ledger.run(id: runId))
        #expect(run.status == .completed && run.totalTokens == 3)
        #expect(run.watchSummary == nil)
        let columns = try queue.read { db in try db.columns(in: "job_runs").map(\.name) }
        #expect(columns.contains("watchSummary"))
    }

    @Test("v11 rewrites an existing watch root to its canonical path")
    func v11CanonicalisesAnExistingWatchRoot() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("iris-v11-\(UUID().uuidString)")
        let real = base.appendingPathComponent("real")
        let link = base.appendingPathComponent("link")
        try fm.createDirectory(at: real, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: link, withDestinationURL: real)
        defer { try? fm.removeItem(at: base) }

        let queue = try v10Database()
        try queue.write { db in
            try insertJob(db, id: UUID(), name: "notes", kind: "fsEvent",
                          trigger: watchTrigger(path: link.path))
        }

        try ConversationStore.migrator.migrate(queue)

        let expected = URL(fileURLWithPath: link.path).resolvingSymlinksInPath()
            .standardizedFileURL.path
        #expect(try storedPath(queue) == expected)
        #expect(expected != link.path, "the symlinked spelling is not the canonical one")
    }

    @Test("v11 leaves a row whose root is already canonical byte for byte")
    func v11LeavesACanonicalRowUntouched() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("iris-v11-canon-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let canonical = try #require(WatchRoot.canonical(dir.path))
        // Keys deliberately not in sorted order and no `ignore` key: the row must still not be
        // touched. Nor must the second row, whose stored window is out of range — the clamp is a
        // read-time rule, not something a data migration writes back.
        let stored = #"{"watch":{"quietWindowSeconds":3,"path":"\#(canonical)"},"kind":"fsEvent"}"#
        let wild = #"{"kind":"fsEvent","watch":{"path":"\#(canonical)","quietWindowSeconds":9000}}"#
        let queue = try v10Database()
        try queue.write { db in
            try insertJob(db, id: UUID(), name: "canon", kind: "fsEvent", trigger: stored)
            try insertJob(db, id: UUID(), name: "wild", kind: "fsEvent", trigger: wild)
        }

        try ConversationStore.migrator.migrate(queue)

        let after = try queue.read { db in
            try Row.fetchAll(db, sql: "SELECT name, trigger FROM jobs ORDER BY name")
                .map { (String.fromDatabaseValue($0["name"]), String.fromDatabaseValue($0["trigger"])) }
        }
        #expect(after.map(\.0) == ["canon", "wild"])
        #expect(after.map(\.1) == [stored, wild])
        // The out-of-range window still reads back clamped; the row on disk is just not rewritten.
        let ledger = JobLedger(writer: queue)
        let windows = try ledger.jobs().compactMap { job -> Int? in
            guard case .fsEvent(let watch) = job.trigger else { return nil }
            return watch.quietWindowSeconds
        }
        #expect(windows.sorted() == [3, 300])
    }

    @Test("v11 leaves a root that no longer exists as it was stored")
    func v11LeavesAMissingRootAsStored() throws {
        let gone = "/tmp/iris-v11-missing-\(UUID().uuidString)/notes"
        let queue = try v10Database()
        try queue.write { db in
            try insertJob(db, id: UUID(), name: "gone", kind: "fsEvent",
                          trigger: watchTrigger(path: gone))
        }

        try ConversationStore.migrator.migrate(queue)

        #expect(try storedPath(queue) == gone)
    }

    @Test("a row an older build wrote reads back with no summary, and so does a malformed one")
    func olderBuildIgnoresTheColumn() throws {
        let store = try ConversationStore.inMemory()
        let job = Job(name: "w", prompt: "p", trigger: .fsEvent(FSWatch(path: "/tmp")))
        try store.ledger.upsert(job)
        let oldId = UUID(), badId = UUID()
        try store.writer.write { db in
            for (id, blob) in [(oldId, nil as String?), (badId, "{not json")] {
                try db.execute(sql: """
                    INSERT INTO job_runs (id, jobId, jobName, triggerKind, startedAt, status,
                                          promptTokens, candidateTokens, totalTokens, watchSummary)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [id.uuidString, job.id.uuidString, "w", "fsEvent", t0,
                                     "completed", 0, 0, 0, blob])
            }
        }

        #expect(try store.ledger.run(id: oldId)?.watchSummary == nil)
        let bad = try #require(try store.ledger.run(id: badId))
        #expect(bad.watchSummary == nil, "a blob that will not decode is absent, not a skipped row")
        #expect(bad.status == .completed)
    }

    @Test("canonical resolves a symlink and is nil for a path that does not exist")
    func canonicalResolvesAndRefusesMissing() {
        #expect(WatchRoot.canonical("/tmp/x", fileExists: { _ in false }) == nil)
        #expect(WatchRoot.canonical("/a/../b", fileExists: { _ in true }) == "/b")
        #expect(WatchRoot.canonical("~", fileExists: { _ in true })
                == NSHomeDirectory().standardizedAndResolved)
    }
}

private extension String {
    var standardizedAndResolved: String {
        URL(fileURLWithPath: self).standardizedFileURL.resolvingSymlinksInPath()
            .standardizedFileURL.path
    }
}
