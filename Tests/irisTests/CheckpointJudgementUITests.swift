import Testing
import Foundation
@testable import iris

/// #191: a checkpoint that stops on a humanJudged criterion asks for the verdict inline. These
/// tests pin the state machine and the persistence the spec's §3-§7 and §11 require.
@MainActor
@Suite("Checkpoint judgement UI (#191)")
struct CheckpointJudgementUITests {

    // MARK: fixtures

    static func isolatedApp(_ store: ConversationStore) -> AppState {
        AppState(store: store, tier2Provisioning: .provisioned, tier3Provisioning: .provisioned)
    }

    /// A two-milestone ladder paused at milestone 0 on an unjudged humanJudged criterion, with the
    /// judgement pause open — the state `performCheckpoint` produces after Task 3.
    @discardableResult
    static func pausedAtCheckpoint(_ app: AppState, _ id: UUID) -> (human: Criterion, other: Criterion) {
        let h = Criterion(text: "output reads well", kind: .humanJudged, check: nil)
        let b = Criterion(text: "wired up", kind: .qualitative, check: nil)
        var c = GoalContract(objective: "Ship the parser", criteria: [h, b])
        c.milestones = [Milestone(title: "Parser", criterionIds: [h.id]),
                        Milestone(title: "Integration", criterionIds: [b.id])]
        c.currentMilestone = 0
        app.createNewConversation(id: id)
        app.setGoalContract(for: id, c)
        let eval = GoalEvaluation(status: .graded, criteria: [
            CriterionVerdict(criterionId: h.id, criterionText: h.text, kind: .humanJudged,
                             verdict: .humanPending, evidence: "", method: .human)
        ], startedAt: Date())
        app.recordEvaluation(for: id, eval)
        app.recordCompletionSelfReport(for: id, statusJSON: .array([]))
        app.setCheckpointPaused(for: id)
        app.beginJudgementPause(for: id, summary: "milestone done")
        return (h, b)
    }

    static func pausedConversation() -> Conversation {
        var c = Conversation(id: UUID(), title: "paused")
        var contract = GoalContract(objective: "o", criteria: [])
        contract.checkpointStatus = .pausedForReview
        c.goalContract = contract
        c.lastGoalEvaluation = GoalEvaluation(status: .graded, criteria: [], startedAt: Date())
        c.lastGoalCompletionReport = .array([])
        return c
    }

    // MARK: §3 sanitizeLoaded

    @Test("sanitizeLoaded keeps the surfacing fields while the checkpoint is paused for review")
    func sanitizeKeepsFieldsWhenPausedForReview() {
        let out = AppState.sanitizeLoaded([Self.pausedConversation()])
        #expect(out.first?.lastGoalEvaluation != nil)
        #expect(out.first?.lastGoalCompletionReport != nil)
    }

    @Test("sanitizeLoaded keeps the surfacing fields during a terminal judgement pause")
    func sanitizeKeepsFieldsWhenAwaitingJudgement() {
        var c = Self.pausedConversation()
        c.goalContract?.checkpointStatus = .running
        c.goalContract?.awaitingHumanJudgement = true
        let out = AppState.sanitizeLoaded([c])
        #expect(out.first?.lastGoalEvaluation != nil)
    }

    @Test("sanitizeLoaded still clears the surfacing fields when nothing is paused on the user")
    func sanitizeClearsFieldsWhenRunning() {
        var c = Self.pausedConversation()
        c.goalContract?.checkpointStatus = .running
        c.goalContract?.awaitingHumanJudgement = false
        let out = AppState.sanitizeLoaded([c])
        #expect(out.first?.lastGoalEvaluation == nil && out.first?.lastGoalCompletionReport == nil)
    }

    @Test("sanitizeLoaded clears the surfacing fields when there is no contract at all")
    func sanitizeClearsFieldsWithoutContract() {
        var c = Self.pausedConversation()
        c.goalContract = nil
        let out = AppState.sanitizeLoaded([c])
        #expect(out.first?.lastGoalEvaluation == nil)
    }

    // MARK: §11 restart round trip through the store

    @Test("a checkpoint judgement pause is still answerable after a relaunch")
    func pauseSurvivesRelaunchThroughStore() throws {
        let store = try ConversationStore.inMemory()
        let id = UUID()
        let human: Criterion
        do {
            let a = Self.isolatedApp(store)
            human = Self.pausedAtCheckpoint(a, id).human
            a.flushSave()
        }
        let b = Self.isolatedApp(store)
        let conv = try #require(b.conversations.first { $0.id == id })
        #expect(conv.goalContract?.checkpointStatus == .pausedForReview)
        #expect(conv.goalContract?.awaitingHumanJudgement == true)
        #expect(conv.lastGoalEvaluation?.criteria.first?.verdict == .humanPending, "the chip's row is back")
        #expect(conv.lastGoalCompletionReport != nil)
        #expect(b.recordHumanJudgement(for: id, criterionId: human.id, accepted: true),
                "the restored pause accepts a verdict instead of refusing it")
    }

    @Test("opening a judgement pause schedules a store write carrying the surfacing fields")
    func pauseWritesSurfacingFieldsToDisk() throws {
        let store = try ConversationStore.inMemory()
        let id = UUID()
        let a = Self.isolatedApp(store)
        Self.pausedAtCheckpoint(a, id)
        a.flushSave()
        let row = try #require(try store.loadAll().conversations.first { $0.id == id })
        #expect(row.lastGoalEvaluation != nil, "asserted on the persisted row, not the property (spec §4)")
        #expect(row.goalContract?.awaitingHumanJudgement == true)
    }

    // MARK: §9.1 clearGoal

    @Test("clearGoal nils both surfacing fields and the store row has both columns NULL")
    func clearGoalClearsFieldsOnDisk() throws {
        let store = try ConversationStore.inMemory()
        let id = UUID()
        let a = Self.isolatedApp(store)
        Self.pausedAtCheckpoint(a, id)
        a.flushSave()
        a.clearGoal(for: id)
        a.flushSave()
        let row = try #require(try store.loadAll().conversations.first { $0.id == id })
        #expect(row.goalContract == nil)
        #expect(row.lastGoalEvaluation == nil && row.lastGoalCompletionReport == nil,
                "in-memory nils are correct whether or not the write was scheduled; the row is the proof")
    }
}
