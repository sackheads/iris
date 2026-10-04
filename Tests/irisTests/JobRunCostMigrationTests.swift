import Testing
import Foundation
import GRDB
@testable import iris

/// Migration `v15_job_run_cost` (5c §0.6): `job_runs` keeps the raw cache components and the run's
/// provider and tier, so a weighted total is priced from the run's own figures at read time.
@Suite struct JobRunCostMigrationTests {
    let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    /// Plan review focus 4: a pre-5c row loads, and prices at its plain `totalTokens` (rulings 7
    /// and 10), which is what it was charged when it was written.
    @Test func v15KeepsRowsAndPricesThemUnknown() throws {
        let queue = try DatabaseQueue()
        try ConversationStore.migrator.migrate(queue, upTo: "v14_job_action")
        let jobId = UUID(), runId = UUID()
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO jobs (id, name, prompt, triggerKind, trigger, profile, createdAt, enabled)
                VALUES (?, 'nightly', 'p', 'schedule', ?, 'readOnly', ?, 1)
                """, arguments: [jobId.uuidString,
                                 #"{"kind":"schedule","schedule":{"kind":"interval","seconds":60}}"#, t0])
            try db.execute(sql: """
                INSERT INTO job_runs (id, jobId, jobName, triggerKind, startedAt, status,
                                      promptTokens, candidateTokens, totalTokens)
                VALUES (?, ?, 'nightly', 'schedule', ?, 'completed', 1000, 10, 1010)
                """, arguments: [runId.uuidString, jobId.uuidString, t0])
        }
        try ConversationStore.migrator.migrate(queue)

        let ledger = JobLedger(writer: queue)
        let run = try #require(try ledger.run(id: runId))
        #expect(run.provider == nil && run.tier == nil)
        #expect(run.cacheReadTokens == 0 && run.cacheWriteTokens == 0 && run.cacheWrite1hTokens == 0)
        #expect(CostWeights.weighted(run.components, provider: run.provider) == run.totalTokens)
        let columns = try queue.read { db in try db.columns(in: "job_runs").map(\.name) }
        for c in ["cacheReadTokens", "cacheWriteTokens", "cacheWrite1hTokens", "provider", "tier"] {
            #expect(columns.contains(c), Comment(rawValue: c))
        }
    }

    @Test func beginFinishAndRecordUsageRoundTrip() throws {
        let store = try ConversationStore.inMemory()
        let job = Job(name: "j", prompt: "p", trigger: .schedule(.interval(seconds: 60)))
        try store.ledger.upsert(job)
        var run = JobRun(jobId: job.id, jobName: "j", triggerKind: "schedule", startedAt: t0,
                         transcriptConversationId: UUID())
        run.provider = "Anthropic"; run.tier = "medium"
        try store.ledger.begin(run: run)
        let mid = TokenUsage(promptTokenCount: 500, candidatesTokenCount: 5, totalTokenCount: 505,
                             cacheReadTokenCount: 300, cacheWriteTokenCount: 100, cacheWrite1hTokenCount: 80)
        try store.ledger.recordUsage(runId: run.id, tokens: mid)
        var less = mid; less.cacheReadTokenCount = 1
        try store.ledger.recordUsage(runId: run.id, tokens: less)   // never lowers
        let read = try #require(try store.ledger.run(id: run.id))
        #expect(read.provider == "Anthropic" && read.tier == "medium")
        #expect(read.cacheReadTokens == 300 && read.cacheWriteTokens == 100 && read.cacheWrite1hTokens == 80)
        try store.ledger.finish(runId: run.id, status: .completed, outcome: nil, failureReason: nil,
                                blockedTool: nil, tokens: mid, finishedAt: t0)
        #expect(try store.ledger.run(id: run.id)?.cacheWrite1hTokens == 80)
    }

    @Test func componentsSplitTheRow() {
        var run = JobRun(jobId: UUID(), jobName: "j", triggerKind: "schedule", startedAt: t0)
        run.promptTokens = 100; run.candidateTokens = 10; run.totalTokens = 150
        run.cacheReadTokens = 60; run.cacheWriteTokens = 20; run.cacheWrite1hTokens = 5
        #expect(run.components == UsageComponents(prompt: 100, output: 50, cacheRead: 60,
                                                  cacheWrite: 20, cacheWrite1h: 5))
    }
}
