import Testing
import Foundation
@testable import IrisKit

/// D6 decision 15: a run log row says what the row says, offers Acknowledge exactly where a run
/// still waits on someone, links a blocked run to its card, and opens a live transcript in the
/// app's one sheet.
@MainActor
@Suite("Run log model (D6)", .timeLimit(.minutes(1)))
struct RunLogModelTests {
    private func run(_ status: JobRun.Status, acknowledged: Bool = false,
                     transcript: UUID? = nil, finishedAfter: TimeInterval? = 42) -> JobRun {
        var run = JobRun(jobId: UUID(), jobName: "pr-sweep", triggerKind: "url",
                         startedAt: Date(timeIntervalSince1970: 1_700_000_000), status: status,
                         transcriptConversationId: transcript)
        run.finishedAt = finishedAfter.map { run.startedAt.addingTimeInterval($0) }
        run.acknowledgedAt = acknowledged ? Date() : nil
        run.promptTokens = 100
        run.candidateTokens = 10
        run.totalTokens = 110
        return run
    }

    @Test("a row carries the columns, and Acknowledge only where a run still waits on someone")
    func rowColumns() {
        let live = UUID()
        let failed = RunLogRow.make(run(.failed, transcript: live), transcriptExists: { $0 == live })
        #expect(failed.duration == 42)
        #expect(failed.triggerKind == "url")
        #expect(failed.weightedTokens > 0)
        #expect(failed.canAcknowledge)
        #expect(failed.transcript == .live(live))
        #expect(!failed.opensCard)

        let blocked = RunLogRow.make(run(.blockedOnApproval), transcriptExists: { _ in false })
        #expect(blocked.canAcknowledge && blocked.opensCard, "a blocked row links to its card, never to an approval")

        #expect(!RunLogRow.make(run(.failed, acknowledged: true), transcriptExists: { _ in false }).canAcknowledge)
        #expect(!RunLogRow.make(run(.completed), transcriptExists: { _ in false }).canAcknowledge)
        #expect(RunLogRow.make(run(.running, finishedAfter: nil), transcriptExists: { _ in false }).duration == nil)
        #expect(RunLogRow.make(run(.completed, transcript: UUID()), transcriptExists: { _ in false }).transcript == .pruned)
        #expect(RunLogRow.make(run(.completed), transcriptExists: { _ in true }).transcript == .none)

        // A failed run that wrote only a reason shows the reason, as `/jobs` does; an outcome
        // that is only whitespace counts as none.
        var reasonOnly = run(.failed)
        reasonOnly.failureReason = "model call failed: 500"
        #expect(RunLogRow.make(reasonOnly, transcriptExists: { _ in false }).outcome == "model call failed: 500")
        var blank = run(.failed)
        blank.outcome = "  \n"
        blank.failureReason = "timed out"
        #expect(RunLogRow.make(blank, transcriptExists: { _ in false }).outcome == "timed out")
        var both = run(.failed)
        both.outcome = "said something"
        both.failureReason = "then failed"
        #expect(RunLogRow.make(both, transcriptExists: { _ in false }).outcome == "said something")
    }

    private func seeded(_ count: Int) throws -> (ConversationStore, Job) {
        let store = try ConversationStore.inMemory()
        let job = Job(name: "pr-sweep", prompt: "do it", trigger: .schedule(.interval(seconds: 60)))
        try store.ledger.upsert(job)
        for i in 0..<count {
            let run = JobRun(jobId: job.id, jobName: job.name, triggerKind: "schedule",
                             startedAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(i)))
            try store.ledger.begin(run: run)
            try store.ledger.finish(runId: run.id, status: i == 0 ? .failed : .completed, outcome: "r\(i)",
                                    failureReason: nil, blockedTool: nil, tokens: TokenUsage(),
                                    finishedAt: run.startedAt)
        }
        return (store, job)
    }

    @Test("reload replaces, loadMore appends, and a filter reloads from the top")
    func paging() async throws {
        let (store, _) = try seeded(5)
        let model = RunLogModel(ledger: store.ledger, pageSize: 2, transcriptExists: { _ in false })

        try await value(of: model.reload())
        #expect(model.rows.map(\.outcome) == ["r4", "r3"])
        #expect(model.hasMore)
        try await value(of: model.loadMore())
        try await value(of: model.loadMore())
        #expect(model.rows.map(\.outcome) == ["r4", "r3", "r2", "r1", "r0"])
        #expect(!model.hasMore)

        model.statusFilter = .failed
        try await value(of: model.reload())
        #expect(model.rows.map(\.outcome) == ["r0"])
    }

    @Test("every filter change reloads from the top by itself, before any loadMore can run")
    func filtersReload() async throws {
        let (store, job) = try seeded(3)
        let other = Job(name: "digest", prompt: "do it", trigger: .schedule(.interval(seconds: 60)))
        try store.ledger.upsert(other)
        let gate = JobRun(jobId: other.id, jobName: other.name, triggerKind: "schedule",
                          startedAt: Date(timeIntervalSince1970: 1_700_000_100))
        try store.ledger.begin(run: gate)
        try store.ledger.finish(runId: gate.id, status: .completed, outcome: JobRunner.gateUnchangedOutcome,
                                failureReason: nil, blockedTool: nil, tokens: TokenUsage(),
                                finishedAt: gate.startedAt)
        let model = RunLogModel(ledger: store.ledger, pageSize: 10, transcriptExists: { _ in false })
        try await value(of: model.reload())
        #expect(model.rows.map(\.outcome) == ["r2", "r1", "r0"])

        // No reload() here: the assignment alone must start one, so a loadMore that follows
        // waits for it rather than paging the old filter from the old cursor.
        model.showGateChecks = true
        let gateReload = try #require(model.pendingReload, "a filter change starts a reload")
        try await value(of: gateReload)
        #expect(model.rows.first?.outcome == JobRunner.gateUnchangedOutcome)

        model.statusFilter = .failed
        try await value(of: try #require(model.pendingReload))
        #expect(model.rows.map(\.outcome) == ["r0"])

        model.statusFilter = nil
        model.jobFilter = job.id
        try await value(of: model.loadMore())
        #expect(model.rows.map(\.outcome) == ["r2", "r1", "r0"])

        // Setting the value it already has is not a change.
        try await value(of: model.reload())
        model.jobFilter = job.id
        #expect(model.pendingReload == nil)
    }

    @Test("a refresh keeps the pages Load more brought in; a filter change reads one page")
    func refreshKeepsDepth() async throws {
        let (store, _) = try seeded(5)
        let model = RunLogModel(ledger: store.ledger, pageSize: 2, transcriptExists: { _ in false })
        try await value(of: model.reload())
        try await value(of: model.loadMore())
        #expect(model.rows.count == 4)

        try await value(of: model.reload(keepingDepth: true))
        #expect(model.rows.map(\.outcome) == ["r4", "r3", "r2", "r1"])
        #expect(model.hasMore)
        try await value(of: model.loadMore())
        #expect(model.rows.map(\.outcome) == ["r4", "r3", "r2", "r1", "r0"], "the cursor follows the deeper read")

        try await value(of: model.reload())
        #expect(model.rows.count == 2)
    }

    @Test("a reload that cannot read leaves no Load more behind")
    func failedReload() async throws {
        let (store, _) = try seeded(5)
        let model = RunLogModel(ledger: store.ledger, pageSize: 2, transcriptExists: { _ in false })
        try await value(of: model.reload())
        #expect(model.hasMore)
        try await store.writer.write { db in try db.execute(sql: "DROP TABLE job_runs") }

        try await value(of: model.reload())
        #expect(!model.hasMore)
        try await value(of: model.loadMore())
        #expect(model.rows.count == 2, "loadMore has no cursor to page from")
    }

    @Test("a picked job that has since been deleted is cleared from the filter")
    func deletedJobFilter() async throws {
        let (store, job) = try seeded(2)
        let model = RunLogModel(ledger: store.ledger, pageSize: 10, transcriptExists: { _ in false })
        model.jobFilter = job.id
        try await value(of: try #require(model.pendingReload))
        #expect(model.jobFilter == job.id)

        try store.ledger.delete(jobId: job.id)
        try await value(of: model.reload())
        #expect(model.jobFilter == nil)
        #expect(!model.jobChoices.contains { $0.id == job.id })
    }

    @Test("the job picker lists every job by name, unreadable ones too, without moving /jobs' count")
    func jobChoices() async throws {
        let (store, job) = try seeded(1)
        let badId = UUID()
        try await store.writer.write { db in
            try db.execute(sql: """
                INSERT INTO jobs (id, name, prompt, triggerKind, trigger, createdAt)
                VALUES (?, ?, ?, ?, ?, ?)
                """, arguments: [badId.uuidString, "bad", "p", "schedule", "{\"kind\":\"telepathy\"}", Date()])
        }
        #expect(store.ledger.unreadableJobCount == 0)
        #expect(try store.ledger.jobNames() == [JobLedger.JobName(id: job.id, name: "pr-sweep"),
                                                JobLedger.JobName(id: badId, name: "bad")])
        // R9: `jobs()` would publish 1 here, and `/jobs` reports that figure.
        #expect(store.ledger.unreadableJobCount == 0)

        let model = RunLogModel(ledger: store.ledger, pageSize: 10, transcriptExists: { _ in false })
        try await value(of: model.reload())
        #expect(model.jobChoices.map(\.name) == ["pr-sweep", "bad"])
        #expect(store.ledger.unreadableJobCount == 0)
    }

    @Test("a loadMore asked for while a reload is in flight waits for it rather than superseding it")
    func loadMoreDuringReload() async throws {
        let (store, _) = try seeded(5)
        let model = RunLogModel(ledger: store.ledger, pageSize: 2, transcriptExists: { _ in false })
        try await value(of: model.reload())

        // The old cursor sits after r3; a page read from it under the new filter would append r0
        // to the unfiltered rows.
        model.statusFilter = .failed
        let reload = model.reload()
        try await value(of: model.loadMore())
        try await value(of: reload)
        #expect(model.rows.map(\.outcome) == ["r0"])
    }

    @Test("Acknowledge stamps the row and clears the menu's failure count")
    func acknowledge() async throws {
        let (store, _) = try seeded(1)
        let app = AppState(store: store, tier2Provisioning: .provisioned, tier3Provisioning: .provisioned)
        let model = RunLogModel(ledger: store.ledger, pageSize: 10, transcriptExists: { _ in false })
        try await value(of: model.reload())
        let row = try #require(model.rows.first)
        #expect(row.canAcknowledge)
        // R5: the count is 1 first, so the 0 below proves the acknowledge moved it.
        try await value(of: app.refreshLedgerAttention())
        #expect(app.ledgerAttention.failedCount == 1)

        try await value(of: app.acknowledgeRun(row.id))
        try await value(of: model.reload())

        #expect(try store.ledger.run(id: row.id)?.acknowledgedAt != nil)
        #expect(model.rows.first?.canAcknowledge == false)
        #expect(app.ledgerAttention.failedCount == 0)
    }

    @Test("a live transcript opens in the main window's one sheet")
    func opensTranscript() throws {
        let app = AppState(store: try ConversationStore.inMemory(),
                           tier2Provisioning: .provisioned, tier3Provisioning: .provisioned)
        final class Raises { var count = 0 }
        let raises = Raises()
        app.raiseMainWindow = { raises.count += 1 }
        let transcript = app.createNewConversation(isBackground: true)

        #expect(app.transcriptExists(transcript))
        #expect(!app.transcriptExists(UUID()))
        app.openTranscript(transcript)

        #expect(app.transcriptSheetConversationId == transcript)
        #expect(raises.count == 1)
    }

    @Test("with nothing selected, Transcript selects Iris so the sheet has a pane to appear on")
    func transcriptWithNoSelection() throws {
        let app = AppState(store: try ConversationStore.inMemory(),
                           tier2Provisioning: .provisioned, tier3Provisioning: .provisioned)
        app.raiseMainWindow = {}
        let mine = app.createNewConversation()
        let transcript = app.createNewConversation(isBackground: true, select: false)

        app.selectedConversationId = nil
        app.openTranscript(transcript)
        #expect(app.selectedConversationId == app.activityConversationId())
        #expect(app.transcriptSheetConversationId == transcript)

        app.selectedConversationId = mine
        app.openTranscript(transcript)
        #expect(app.selectedConversationId == mine, "a selection the user made is left alone")
    }
}
