import Testing
import Foundation
@testable import iris

/// What happens when the last judgement lands (spec §7). The grader is NOT re-run: the verdicts
/// are already in hand, and re-running would overwrite the user's decision with a fresh
/// human_pending.
@MainActor
@Suite("Human judgement resume (D2)")
struct HumanJudgementResumeTests {
    private func pausedGoal(on app: AppState, _ id: UUID, judged: Int) -> [Criterion] {
        app.createNewConversation(id: id)
        let machine = Criterion(text: "builds", kind: .qualitative, check: nil)
        let judgedCriteria = (0..<judged).map {
            Criterion(text: "human call \($0)", kind: .humanJudged, check: nil)
        }
        app.setGoalContract(for: id, GoalContract(objective: "ship", criteria: [machine] + judgedCriteria))
        app.beginJudgementPause(for: id)
        app.recordEvaluation(for: id, GoalEvaluation(
            status: .graded,
            criteria: [CriterionVerdict(criterionId: machine.id, criterionText: machine.text,
                                        kind: .qualitative, verdict: .met, evidence: "ok", method: .judge)]
                + judgedCriteria.map {
                    CriterionVerdict(criterionId: $0.id, criterionText: $0.text, kind: .humanJudged,
                                     verdict: .humanPending, evidence: "", method: .human)
                },
            startedAt: Date(), completedAt: Date()))
        return judgedCriteria
    }

    @Test("accepting the last outstanding criterion completes the goal")
    func lastAcceptCompletes() {
        let app = AppState()
        let id = UUID()
        let judged = pausedGoal(on: app, id, judged: 1)

        app.recordHumanJudgement(for: id, criterionId: judged[0].id, accepted: true)

        let conv = app.conversations.first { $0.id == id }
        #expect(conv?.activeGoal == nil, "all criteria resolved — the goal is done")
        #expect(conv?.lastGoalEvaluation?.gateOutcome == .passed)
    }

    @Test("judging one of several leaves the goal paused")
    func partialJudgementStaysPaused() {
        let app = AppState()
        let id = UUID()
        let judged = pausedGoal(on: app, id, judged: 2)

        app.recordHumanJudgement(for: id, criterionId: judged[0].id, accepted: true)

        let conv = app.conversations.first { $0.id == id }
        #expect(conv?.goalContract?.awaitingHumanJudgement == true)
        #expect(conv?.activeGoal != nil)
    }

    @Test("a rejection sends the agent back to work rather than completing")
    func rejectionResumesTheAgent() {
        let app = AppState()
        let id = UUID()
        let judged = pausedGoal(on: app, id, judged: 1)

        app.recordHumanJudgement(for: id, criterionId: judged[0].id, accepted: false)

        let conv = app.conversations.first { $0.id == id }
        #expect(conv?.goalContract?.awaitingHumanJudgement == false, "the pause is over")
        #expect(conv?.activeGoal != nil, "but the goal is not — the agent has work to do")
        #expect(conv?.goalContract?.gateAttempts == 0,
                "the agent has not yet had a chance to respond, so it has not used an attempt")
    }

    @Test("a rejection's persisted state survives a restart — the flag and the verdict land together")
    func rejectionPersistsConsistently() throws {
        // Regression for a crash/quit window: if the `awaitingHumanJudgement = false` flip were
        // saved separately from (or later than) the verdict change, a restart between the two
        // saves would decode a goal that is permanently stuck — still "awaiting judgement" with no
        // human_pending criterion left to resolve it, and no button rendered to un-stick it. Encode
        // and decode the conversation to assert on exactly what a restart would see, not on the
        // live in-memory AppState.
        let app = AppState()
        let id = UUID()
        let judged = pausedGoal(on: app, id, judged: 1)

        app.recordHumanJudgement(for: id, criterionId: judged[0].id, accepted: false)

        let live = try #require(app.conversations.first { $0.id == id })
        let restarted = try JSONDecoder().decode(Conversation.self, from: JSONEncoder().encode(live))

        #expect(restarted.goalContract?.awaitingHumanJudgement == false,
                "the flag must not still say 'awaiting judgement' once the verdict is in")
        #expect(!(restarted.lastGoalEvaluation?.criteria.contains { $0.verdict == .humanPending } ?? false),
                "no human_pending criterion may remain once awaitingHumanJudgement is false")
    }

    @Test("a mixed verdict resumes the agent, it does not complete")
    func mixedVerdictResumes() {
        let app = AppState()
        let id = UUID()
        let judged = pausedGoal(on: app, id, judged: 2)

        app.recordHumanJudgement(for: id, criterionId: judged[0].id, accepted: true)
        app.recordHumanJudgement(for: id, criterionId: judged[1].id, accepted: false)

        let conv = app.conversations.first { $0.id == id }
        #expect(conv?.activeGoal != nil, "one rejection is enough to send it back")
        #expect(conv?.goalContract?.awaitingHumanJudgement == false)
    }
}
