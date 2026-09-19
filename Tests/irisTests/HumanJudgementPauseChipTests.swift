import Testing
import Foundation
@testable import iris

/// The chip that hosts Accept/Reject while a goal is paused for judgement: what its ✕ may do, and
/// what its header says. Both are pure enough to test without a SwiftUI harness.
@MainActor
@Suite("Human judgement pause chip (D2 follow-up)")
struct HumanJudgementPauseChipTests {
    private func pausedGoal(on app: AppState, _ id: UUID) -> Criterion {
        app.createNewConversation(id: id)
        let judged = Criterion(text: "reads well", kind: .humanJudged, check: nil)
        app.setGoalContract(for: id, GoalContract(objective: "ship", criteria: [judged]))
        app.beginJudgementPause(for: id)
        app.recordEvaluation(for: id, GoalEvaluation(status: .graded, criteria: [
            CriterionVerdict(criterionId: judged.id, criterionText: judged.text, kind: .humanJudged,
                             verdict: .humanPending, evidence: "", method: .human)
        ], startedAt: Date(), completedAt: Date()))
        return judged
    }

    @Test("dismissing during a judgement pause does not destroy the evaluation")
    func dismissIsRefusedWhilePaused() throws {
        // The evaluation is the only thing the Accept/Reject buttons act on, and the only reason
        // the chip renders. Nil it mid-pause and the goal is awaiting a judgement that can never
        // be given, with no chip, no resume guard that wakes the loop, and no route back but /stop.
        let app = AppState()
        let id = UUID()
        _ = pausedGoal(on: app, id)

        app.dismissCompletionReport(for: id)

        let conv = try #require(app.conversations.first { $0.id == id })
        #expect(conv.lastGoalEvaluation != nil, "the verdicts must survive the ✕")
        #expect(conv.goalContract?.awaitingHumanJudgement == true)
    }

    @Test("the goal is still resolvable after a dismiss attempt during the pause")
    func goalStaysResolvableAfterDismiss() throws {
        let app = AppState()
        let id = UUID()
        let judged = pausedGoal(on: app, id)

        app.dismissCompletionReport(for: id)
        #expect(app.recordHumanJudgement(for: id, criterionId: judged.id, accepted: true),
                "the judgement must still land")

        let conv = try #require(app.conversations.first { $0.id == id })
        #expect(conv.activeGoal == nil, "and it must still complete the goal")
    }

    @Test("dismissing a finished report still works")
    func dismissStillWorksWhenNotPaused() throws {
        // The guard is narrow on purpose: the ✕ is the only way to put away a completed goal's
        // report, and that must keep working.
        let app = AppState()
        let id = UUID()
        let judged = pausedGoal(on: app, id)
        app.recordHumanJudgement(for: id, criterionId: judged.id, accepted: true)

        app.dismissCompletionReport(for: id)

        let conv = try #require(app.conversations.first { $0.id == id })
        #expect(conv.lastGoalEvaluation == nil)
        #expect(conv.lastGoalCompletionReport == nil)
    }

    @Test("the locked chip header says the run is waiting on the user")
    func headerReflectsTheJudgementPause() {
        var contract = GoalContract(objective: "ship", criteria: [])
        contract.lock()
        contract.awaitingHumanJudgement = true

        let header = contract.lockedChipHeader
        #expect(header.isPaused)
        #expect(!header.title.contains("LOCKED"), "'LOCKED / Read-only' hides that the run is waiting")
        #expect(header.title.lowercased().contains("judgement"))
        #expect(header.trailing != "Read-only")
    }

    @Test("a running locked contract keeps the LOCKED header")
    func headerUnchangedWhileRunning() {
        var contract = GoalContract(objective: "ship", criteria: [])
        contract.lock()

        let header = contract.lockedChipHeader
        #expect(header.title == "GOAL CONTRACT · LOCKED")
        #expect(header.trailing == "Read-only")
        #expect(header.symbolName == "lock.fill")
        #expect(!header.isPaused)
    }

    @Test("a checkpoint pause keeps its own header wording")
    func headerUnchangedForCheckpointPause() {
        var contract = GoalContract(objective: "ship", criteria: [])
        contract.lock()
        contract.checkpointStatus = .pausedForReview

        let header = contract.lockedChipHeader
        #expect(header.title == "GOAL CONTRACT · PAUSED FOR REVIEW")
        #expect(header.trailing == "Awaiting your decision")
        #expect(header.isPaused)
    }
}
