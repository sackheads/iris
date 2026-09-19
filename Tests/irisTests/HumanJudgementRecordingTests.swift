import Testing
import Foundation
@testable import iris

/// Recording one accept/reject onto the stored evaluation (spec §6). `VerdictMethod.human` has
/// existed since slice C and has never been used; this is what finally uses it.
@MainActor
@Suite("Human judgement recording (D2)")
struct HumanJudgementRecordingTests {
    private func pausedGoal(on app: AppState, _ id: UUID) -> Criterion {
        app.createNewConversation(id: id)
        let judged = Criterion(text: "the design reads well", kind: .humanJudged, check: nil)
        var contract = GoalContract(objective: "ship", criteria: [judged])
        contract.awaitingHumanJudgement = true
        app.setGoalContract(for: id, contract)
        // Mark it awaiting again: setGoalContract locks a normalized copy.
        if let idx = app.conversations.firstIndex(where: { $0.id == id }) {
            app.conversations[idx].goalContract?.awaitingHumanJudgement = true
        }
        app.recordEvaluation(for: id, GoalEvaluation(
            status: .graded,
            criteria: [CriterionVerdict(criterionId: judged.id, criterionText: judged.text,
                                        kind: .humanJudged, verdict: .humanPending,
                                        evidence: "", method: .human)],
            startedAt: Date(), completedAt: Date()))
        return judged
    }

    @Test("accepting records met, attributed to the human")
    func acceptRecordsMet() {
        let app = AppState()
        let id = UUID()
        let c = pausedGoal(on: app, id)

        #expect(app.recordHumanJudgement(for: id, criterionId: c.id, accepted: true))

        let v = app.conversations.first { $0.id == id }?
            .lastGoalEvaluation?.criteria.first { $0.criterionId == c.id }
        #expect(v?.verdict == .met)
        #expect(v?.method == .human, "a human accept must never look like grader-verified evidence")
    }

    @Test("rejecting records not_met, attributed to the human")
    func rejectRecordsNotMet() {
        let app = AppState()
        let id = UUID()
        let c = pausedGoal(on: app, id)

        #expect(app.recordHumanJudgement(for: id, criterionId: c.id, accepted: false))

        let v = app.conversations.first { $0.id == id }?
            .lastGoalEvaluation?.criteria.first { $0.criterionId == c.id }
        #expect(v?.verdict == .notMet)
        #expect(v?.method == .human)
    }

    @Test("a judgement on a goal that is not paused is ignored")
    func staleJudgementIgnored() {
        let app = AppState()
        let id = UUID()
        let c = pausedGoal(on: app, id)
        if let idx = app.conversations.firstIndex(where: { $0.id == id }) {
            app.conversations[idx].goalContract?.awaitingHumanJudgement = false
        }

        #expect(!app.recordHumanJudgement(for: id, criterionId: c.id, accepted: true),
                "a stale click after /stop or completion must not rewrite a verdict")
        let v = app.conversations.first { $0.id == id }?
            .lastGoalEvaluation?.criteria.first { $0.criterionId == c.id }
        #expect(v?.verdict == .humanPending)
    }

    @Test("an unknown criterion id is refused")
    func unknownIdRefused() {
        let app = AppState()
        let id = UUID()
        _ = pausedGoal(on: app, id)
        #expect(!app.recordHumanJudgement(for: id, criterionId: UUID(), accepted: true))
    }

    @Test("a criterion that is not awaiting judgement is refused")
    func alreadyJudgedIsRefused() {
        let app = AppState()
        let id = UUID()
        let c = pausedGoal(on: app, id)
        #expect(app.recordHumanJudgement(for: id, criterionId: c.id, accepted: true))
        // Second click on the same row must not flip an already-recorded judgement.
        #expect(!app.recordHumanJudgement(for: id, criterionId: c.id, accepted: false))
        let v = app.conversations.first { $0.id == id }?
            .lastGoalEvaluation?.criteria.first { $0.criterionId == c.id }
        #expect(v?.verdict == .met)
    }
}
