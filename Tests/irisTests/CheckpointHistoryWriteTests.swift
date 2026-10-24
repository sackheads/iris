import Foundation
import GRDB
import Testing
@testable import IrisKit

/// Every update that writes `conversations.checkpointHistory`, counted at the database.
final class HistoryColumnWrites: TransactionObserver, @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    var count: Int { lock.withLock { n } }
    func observes(eventsOfKind eventKind: DatabaseEventKind) -> Bool {
        if case .update(let table, let columns) = eventKind { return table == "conversations" && columns.contains("checkpointHistory") }
        return false
    }
    func databaseDidChange(with event: DatabaseEvent) { lock.withLock { n += 1 } }
    func databaseDidCommit(_ db: Database) {}
    func databaseDidRollback(_ db: Database) {}
}

/// #205: the checkpoint history holds every checkpoint's verdicts, so it's written only when it
/// changes, never on the metadata write every model response makes.
@MainActor
@Suite("Checkpoint history writes (#205)")
struct CheckpointHistoryWriteTests {
    private func ladder(_ app: AppState, _ id: UUID) -> GoalContract {
        let a = Criterion(text: "parser builds", kind: .qualitative, check: nil)
        let b = Criterion(text: "wired up", kind: .qualitative, check: nil)
        var c = GoalContract(objective: "Ship the parser", criteria: [a, b])
        c.milestones = [Milestone(title: "Parser", criterionIds: [a.id]), Milestone(title: "Integration", criterionIds: [b.id])]
        app.createNewConversation(id: id)
        app.setGoalContract(for: id, c)
        app.recordEvaluation(for: id, GoalEvaluation(status: .graded, criteria: [
            CriterionVerdict(criterionId: a.id, criterionText: a.text, kind: .qualitative, verdict: .met,
                             evidence: "it builds", method: .judge)
        ], startedAt: Date()))
        app.setCheckpointPaused(for: id)
        return c
    }

    @Test("an appended checkpoint writes the column once; token-usage writes after it write none of it")
    func writtenOnlyWhenChanged() throws {
        let store = try ConversationStore.inMemory()
        let app = AppState(store: store, createIfEmpty: false, emitLaunchNotices: false)
        let id = UUID()
        let contract = ladder(app, id)
        app.flushSave()
        let writes = HistoryColumnWrites()
        store.writer.add(transactionObserver: writes, extent: .observerLifetime)

        app.advanceCheckpoint(for: id)
        app.flushSave()
        #expect(writes.count == 1, "the append is the one write")

        for n in 1...5 {
            app.updateTokenUsage(for: id, usage: UsageMetadata(promptTokenCount: 100 * n, candidatesTokenCount: 10, totalTokenCount: nil))
            app.flushSave()
        }
        #expect(writes.count == 1, "a metadata write leaves the history column alone")

        // Still there, and still right, on reload: a metadata write didn't clobber it either.
        let loaded = try #require(try store.loadAll().conversations.first { $0.id == id })
        #expect(loaded.checkpointHistory.count == 1)
        #expect(loaded.checkpointHistory.first?.resolution == .humanApproved)
        #expect(loaded.checkpointHistory.first?.contractId == contract.id)
        #expect(loaded.tokenUsage == app.conversations.first { $0.id == id }?.tokenUsage, "the metadata itself was written")
    }

    @Test("a new conversation's insert carries its history")
    func insertWritesHistory() throws {
        let store = try ConversationStore.inMemory()
        var c = Conversation(title: "history")
        c.checkpointHistory = [CheckpointOutcome(milestoneIndex: 0, milestoneTitle: "One", resolution: .autoAdvanced)]
        var changes = ChangeSet()
        changes.add(.created)
        try store.apply([ConversationWrite(id: c.id, snapshot: c, changes: changes)])
        #expect(try store.loadAll().conversations.first { $0.id == c.id }?.checkpointHistory.count == 1)
    }

    @Test("a re-queued batch keeps the history change")
    func changeSetCarriesIt() {
        var failed = ChangeSet()
        failed.add(.checkpointHistory)
        #expect(!failed.isEmpty)
        var newer = ChangeSet()
        newer.add(.metadata)
        newer.merge(failed)
        #expect(newer.checkpointHistory && newer.metadata)
    }

    @Test("a record keeps at most evidenceLimit characters of each verdict's evidence, and says so")
    func evidenceCapped() {
        let long = String(repeating: "x", count: CheckpointOutcome.evidenceLimit * 3)
        let eval = GoalEvaluation(status: .graded, criteria: [
            CriterionVerdict(criterionId: UUID(), criterionText: "a", kind: .qualitative, verdict: .met, evidence: long, method: .judge),
            CriterionVerdict(criterionId: UUID(), criterionText: "b", kind: .qualitative, verdict: .met, evidence: "short", method: .judge),
        ], startedAt: Date())
        let record = CheckpointOutcome(milestoneIndex: 0, milestoneTitle: "M", evaluation: eval, resolution: .autoAdvanced)
        let kept = record.evaluation?.criteria.map(\.evidence) ?? []
        #expect(kept[0].hasPrefix(String(long.prefix(CheckpointOutcome.evidenceLimit))))
        #expect(kept[0].count < CheckpointOutcome.evidenceLimit + 60 && kept[0].hasSuffix("characters]"))
        #expect(kept[1] == "short")
    }

    @Test("a record stored before contractId existed still decodes (invariant 1)")
    func oldRecordDecodes() throws {
        let json = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","milestoneIndex":2,"milestoneTitle":"Old","resolution":"humanApproved"}"#
        let record = try JSONDecoder().decode(CheckpointOutcome.self, from: Data(json.utf8))
        #expect(record.milestoneIndex == 2 && record.contractId == nil)
    }
}
