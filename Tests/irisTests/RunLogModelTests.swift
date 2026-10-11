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
}
