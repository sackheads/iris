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
        #expect(conv?.goalContract == nil, "the terminal gate cleared the goal")
        // #191: clearGoal now nils the surfacing fields with the contract (both the terminal
        // gate and /stop route through it), so gateOutcome is no longer readable here.
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

    @Test("a waived not_met is not the user's rejection — an accept still completes the goal")
    func waivedNotMetDoesNotReadAsAHumanRejection() throws {
        // D1 lets the agent waive a criterion it cannot satisfy, and `blockingCriteria` excludes a
        // waived `not_met` — which is exactly why the judgement pause can fire while one is still
        // sitting in the evaluation. Counting it as "rejected" resumed the agent instead of
        // completing, told it the USER had rejected a criterion the grader failed, and looped a
        // full grader run per turn until the iteration cap soft-stopped the goal.
        let app = AppState()
        let id = UUID()
        app.createNewConversation(id: id)
        let waived = Criterion(text: "ships a changelog", kind: .qualitative, check: nil)
        let judged = Criterion(text: "reads well", kind: .humanJudged, check: nil)
        app.setGoalContract(for: id, GoalContract(objective: "ship", criteria: [waived, judged]))
        let i = try #require(app.conversations.firstIndex { $0.id == id })
        app.conversations[i].goalContract?.waivers[waived.id] = "this repo has no changelog"
        app.beginJudgementPause(for: id)
        app.recordEvaluation(for: id, GoalEvaluation(status: .graded, criteria: [
            CriterionVerdict(criterionId: waived.id, criterionText: waived.text, kind: .qualitative,
                             verdict: .notMet, evidence: "no CHANGELOG.md", method: .judge),
            CriterionVerdict(criterionId: judged.id, criterionText: judged.text, kind: .humanJudged,
                             verdict: .humanPending, evidence: "", method: .human)
        ], startedAt: Date(), completedAt: Date()))

        app.recordHumanJudgement(for: id, criterionId: judged.id, accepted: true)

        let conv = try #require(app.conversations.first { $0.id == id })
        #expect(conv.activeGoal == nil, "the user accepted everything outstanding — the goal is done")
        // #191: clearGoal now nils lastGoalEvaluation with the contract, so gateOutcome is no
        // longer readable here; goalContract == nil already proves the terminal gate ran.
        #expect(conv.goalContract == nil)
        #expect(!conv.messages.contains { $0.content.contains("in the user's judgement") },
                "the user never rejected anything, so nothing may be attributed to them")
    }

    @Test("a completion via judgement pushes the goal_complete summary, as D1 does")
    func acceptPushesTheSummary() throws {
        // Spec §7: the goal "completes exactly as D1 completes it". The goal_complete handler
        // returns at the pause, before its own push, so the accept branch has to do it.
        let app = AppState()
        let id = UUID()
        app.createNewConversation(id: id)
        let judged = Criterion(text: "reads well", kind: .humanJudged, check: nil)
        app.setGoalContract(for: id, GoalContract(objective: "ship", criteria: [judged]))
        app.beginJudgementPause(for: id, summary: "Rewrote the intro and trimmed the middle section.")
        app.recordEvaluation(for: id, GoalEvaluation(status: .graded, criteria: [
            CriterionVerdict(criterionId: judged.id, criterionText: judged.text, kind: .humanJudged,
                             verdict: .humanPending, evidence: "", method: .human)
        ], startedAt: Date(), completedAt: Date()))

        app.recordHumanJudgement(for: id, criterionId: judged.id, accepted: true)

        let conv = try #require(app.conversations.first { $0.id == id })
        #expect(conv.messages.contains {
            $0.role == .agent && $0.content == "Rewrote the intro and trimmed the middle section."
        }, "the summary must not be lost just because the goal finished through the user")
    }

    @Test("a rejection resets the iteration budget, as the checkpoint resumes do")
    func rejectionResetsTheIterationCount() throws {
        // The agent is being sent back to work on something new. Without the reset a rejection
        // landing late in a long run soft-stops after a single turn.
        let app = AppState()
        let id = UUID()
        let judged = pausedGoal(on: app, id, judged: 1)
        let i = try #require(app.conversations.firstIndex { $0.id == id })
        app.conversations[i].goalIterationCount = 9

        app.recordHumanJudgement(for: id, criterionId: judged[0].id, accepted: false)

        #expect(app.conversations.first { $0.id == id }?.goalIterationCount == 0)
    }

    @Test("the rejection reprompt is worded for a terminal gate, not for a checkpoint")
    func rejectionFramingIsNotCheckpointWording() {
        // A goal that reached the terminal gate often has no ladder at all, so "feedback at this
        // checkpoint" / "continue toward the current checkpoint" describes something that does not
        // exist. The checkpoint callers keep their own wording.
        let judgement = AppState.GoalResumeFraming.judgementRejection
        #expect(!judgement.steerHeading.lowercased().contains("checkpoint"))
        #expect(!judgement.closingLine.lowercased().contains("checkpoint"))
        #expect(judgement.closingLine.contains("goal_complete"),
                "the agent has to know what to do once it has addressed the rejection")

        let checkpoint = AppState.GoalResumeFraming.checkpoint
        #expect(checkpoint.steerHeading.contains("checkpoint"))
        #expect(checkpoint.closingLine.contains("checkpoint"))
    }
}
