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

    @Test("clearGoal keeps both surfacing fields after an ordinary completion, in memory and on disk")
    func clearGoalKeepsFieldsAfterOrdinaryCompletion() throws {
        let store = try ConversationStore.inMemory()
        let id = UUID()
        let a = Self.isolatedApp(store)
        let c = Criterion(text: "tests pass", kind: .qualitative, check: nil)
        a.createNewConversation(id: id)
        a.setGoalContract(for: id, GoalContract(objective: "ship", criteria: [c]))
        let eval = GoalEvaluation(status: .graded, criteria: [
            CriterionVerdict(criterionId: c.id, criterionText: c.text, kind: .qualitative,
                             verdict: .met, evidence: "ok", method: .judge)
        ], startedAt: Date())
        a.recordEvaluation(for: id, eval)
        a.recordCompletionSelfReport(for: id, statusJSON: .array([]))
        // No pause opened — no beginJudgementPause, no setCheckpointPaused. This is the terminal
        // gate's ordinary finishGatedGoal -> clearGoal path (spec §9.1), which must leave both
        // fields alone so the completion-report chip still has something to show and dismiss.
        a.clearGoal(for: id)
        let live = a.conversations.first { $0.id == id }
        #expect(live?.lastGoalEvaluation != nil)
        #expect(live?.lastGoalCompletionReport != nil)
        a.flushSave()
        let row = try #require(try store.loadAll().conversations.first { $0.id == id })
        #expect(row.goalContract == nil, "the contract is still cleared")
        #expect(row.lastGoalEvaluation != nil, "an ordinary completion's report survives for the chip")
        #expect(row.lastGoalCompletionReport != nil)
    }

    // MARK: §6 the approve gate

    static func ladder(_ human: Criterion, _ other: Criterion, current: Int) -> GoalContract {
        var c = GoalContract(objective: "o", criteria: [human, other])
        c.milestones = [Milestone(title: "A", criterionIds: [human.id]),
                        Milestone(title: "B", criterionIds: [other.id])]
        c.currentMilestone = current
        return c
    }
    static func eval(_ verdicts: [CriterionVerdict]) -> GoalEvaluation {
        GoalEvaluation(status: .graded, criteria: verdicts, startedAt: Date())
    }
    static func pending(_ c: Criterion) -> CriterionVerdict {
        CriterionVerdict(criterionId: c.id, criterionText: c.text, kind: .humanJudged, verdict: .humanPending, evidence: "", method: .human)
    }

    @Test("Approve is blocked by an unjudged humanJudged criterion of the current milestone")
    func gateBlocksUnjudged() {
        let h = Criterion(text: "reads well", kind: .humanJudged, check: nil)
        let b = Criterion(text: "wired", kind: .qualitative, check: nil)
        let c = Self.ladder(h, b, current: 0)
        #expect(c.checkpointApproveBlockers(from: Self.eval([Self.pending(h)])).map(\.criterionId) == [h.id])
    }

    @Test("Approve is blocked by a REJECTED humanJudged criterion of the current milestone")
    func gateBlocksRejected() {
        let h = Criterion(text: "reads well", kind: .humanJudged, check: nil)
        let b = Criterion(text: "wired", kind: .qualitative, check: nil)
        var c = Self.ladder(h, b, current: 0)
        c.judgements[h.id] = false
        var v = Self.pending(h); v.verdict = .notMet
        #expect(c.checkpointApproveBlockers(from: Self.eval([v])).map(\.criterionId) == [h.id])
    }

    @Test("Approve is not blocked once the criterion is accepted")
    func gateOpensOnAcceptance() {
        let h = Criterion(text: "reads well", kind: .humanJudged, check: nil)
        let b = Criterion(text: "wired", kind: .qualitative, check: nil)
        var c = Self.ladder(h, b, current: 0)
        c.judgements[h.id] = true
        var v = Self.pending(h); v.verdict = .met
        #expect(c.checkpointApproveBlockers(from: Self.eval([v])).isEmpty)
    }

    @Test("the gate's set equals send-back's set: a rejection in an EARLIER milestone does not block Approve later (§6)")
    func gateIsScopedToCurrentMilestone() {
        // Constructed directly: §7's induction makes this unreachable in normal operation, and this
        // test exists for the day the induction stops holding.
        let h = Criterion(text: "reads well", kind: .humanJudged, check: nil)
        let b = Criterion(text: "wired", kind: .qualitative, check: nil)
        var c = Self.ladder(h, b, current: 1)
        c.judgements[h.id] = false
        var v = Self.pending(h); v.verdict = .notMet
        let bv = CriterionVerdict(criterionId: b.id, criterionText: b.text, kind: .qualitative, verdict: .met, evidence: "ok", method: .judge)
        #expect(c.checkpointApproveBlockers(from: Self.eval([v, bv])).isEmpty,
                "milestone 1 is current; milestone 0's rejection is not this gate's to hold")
    }

    @Test("no evaluation means nothing blocks (the chip has no rows to decide)")
    func gateWithoutEvaluation() {
        let h = Criterion(text: "reads well", kind: .humanJudged, check: nil)
        let b = Criterion(text: "wired", kind: .qualitative, check: nil)
        #expect(Self.ladder(h, b, current: 0).checkpointApproveBlockers(from: nil).isEmpty)
    }

    // MARK: §7 the waiver branch is ordered before the humanJudged branch

    @Test("canAutoAdvance passes a WAIVED humanJudged criterion with no judgement recorded (§7 dependency)")
    func waiverPrecedesJudgement() {
        // Spec §7: the guarantee "every humanJudged criterion in the checkpoint is accepted" holds
        // only because checkpoint-level waivers cannot exist today. If they ever can, this ordering
        // is the single thing that decides whether §7 is still true. This test fails the day the
        // ordering changes, which is the right moment to decide which of the two §7 should say.
        let h = Criterion(text: "reads well", kind: .humanJudged, check: nil)
        let b = Criterion(text: "wired", kind: .qualitative, check: nil)
        var c = Self.ladder(h, b, current: 0)
        c.lock()
        c.waivers[h.id] = "user said skip"
        var v = Self.pending(h)
        v.verdict = .humanPending
        #expect(c.judgements[h.id] == nil)
        #expect(c.canAutoAdvance(from: Self.eval([v])))
    }

    // MARK: §11 the history entry carries the post-judgement evaluation

    @Test("the humanApproved history entry carries the verdict the user gave, not the grader's humanPending")
    func historyCarriesPostJudgementEvaluation() throws {
        let store = try ConversationStore.inMemory()
        let id = UUID()
        let a = Self.isolatedApp(store)
        let (h, _) = Self.pausedAtCheckpoint(a, id)
        #expect(a.recordHumanJudgement(for: id, criterionId: h.id, accepted: true))
        a.advanceCheckpoint(for: id)
        let entry = try #require(a.conversations.first { $0.id == id }?.checkpointHistory.last)
        #expect(entry.resolution == .humanApproved)
        let verdict = try #require(entry.evaluation?.criteria.first { $0.criterionId == h.id })
        #expect(verdict.verdict == .met && verdict.method == .human)
    }
}
