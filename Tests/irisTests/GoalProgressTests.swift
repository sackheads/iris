import Testing
import Foundation
@testable import IrisKit

/// #882: the goal progress panel's rows, tested on the pure model (the view only draws them).
@Suite("Goal progress rows (#882)")
struct GoalProgressTests {
    private let a = Criterion(text: "parser handles nested lists", kind: .qualitative)
    private let b = Criterion(text: "swift test passes", kind: .executable, check: "swift test")
    private let c = Criterion(text: "docs read well", kind: .humanJudged)

    private func verdict(_ k: Criterion, _ v: CriterionVerdictValue, _ evidence: String = "") -> CriterionVerdict {
        CriterionVerdict(criterionId: k.id, criterionText: k.text, kind: k.kind, verdict: v, evidence: evidence, method: .judge)
    }

    private func eval(_ verdicts: [CriterionVerdict], status: EvaluationStatus = .graded, at: Date = Date()) -> GoalEvaluation {
        GoalEvaluation(status: status, criteria: verdicts, startedAt: at, completedAt: at)
    }

    private func conversation(contract: GoalContract?, history: [CheckpointOutcome] = [], last: GoalEvaluation? = nil) -> Conversation {
        var conv = Conversation(title: "t", goalContract: contract)
        conv.checkpointHistory = history
        conv.lastGoalEvaluation = last
        return conv
    }

    @Test("a conversation with no goal and no history is empty and does not crash")
    func noGoal() {
        let p = GoalProgress(conversation(contract: nil))
        #expect(p.isEmpty && p.criteria.isEmpty && p.checkpoints.isEmpty && !p.isLive)
    }

    @Test("a goal with no checkpoints and no grade shows its criteria as not graded yet")
    func goalNoCheckpoints() {
        let contract = GoalContract(objective: "ship the parser", criteria: [a, b], state: .locked)
        let p = GoalProgress(conversation(contract: contract))
        #expect(p.isLive && p.objective == "ship the parser" && p.criteria.count == 2 && p.checkpoints.isEmpty)
        #expect(p.criteria.allSatisfy { $0.verdict == nil && $0.checkpoint == nil })
        #expect(GoalProgressView.statusLine(for: p.criteria[0]) == "not graded yet")
    }

    @Test("the latest verdict and its evidence come from the newest grade, a later cumulative grade overriding an earlier")
    func latestVerdictWins() {
        let id = UUID()
        let contract = GoalContract(id: id, objective: "o", criteria: [a, b, c],
                                    milestones: [Milestone(title: "Parser", criterionIds: [a.id]), Milestone(title: "Tests", criterionIds: [b.id, c.id])],
                                    currentMilestone: 2, state: .locked)
        let t0 = Date(timeIntervalSince1970: 1_000)
        let history = [
            CheckpointOutcome(milestoneIndex: 0, milestoneTitle: "Parser", evaluation: eval([verdict(a, .notMet, "nested fails")], at: t0),
                              resolution: .humanSentBack, date: t0, contractId: id),
            CheckpointOutcome(milestoneIndex: 0, milestoneTitle: "Parser", evaluation: eval([verdict(a, .met, "nested passes")], at: t0.addingTimeInterval(60)),
                              resolution: .autoAdvanced, date: t0.addingTimeInterval(60), contractId: id),
            CheckpointOutcome(milestoneIndex: 1, milestoneTitle: "Tests", evaluation: eval([verdict(a, .met), verdict(b, .cannotVerify, "no toolchain"), verdict(c, .humanPending)], at: t0.addingTimeInterval(120)),
                              resolution: .humanApproved, date: t0.addingTimeInterval(120), contractId: id),
        ]
        let p = GoalProgress(conversation(contract: contract, history: history))
        #expect(p.criteria.map(\.verdict) == [.met, .cannotVerify, .humanPending])
        #expect(p.criteria[1].evidence == "no toolchain")
        #expect(p.criteria.map(\.checkpoint) == [1, 2, 2])
        #expect(p.checkpoints.map(\.number) == [1, 1, 2], "every record, in order")
        #expect(p.checkpoints.map(\.resolution) == [.humanSentBack, .autoAdvanced, .humanApproved])
        #expect(p.checkpoints[0].met == 0 && p.checkpoints[0].graded == 1)
        #expect(p.checkpoints[2].met == 1 && p.checkpoints[2].graded == 2, "a human-pending criterion is not graded")
        #expect(GoalProgressView.line(for: p.checkpoints[1]).contains("advanced on its own") && GoalProgressView.line(for: p.checkpoints[1]).contains("1 of 1 met"))
    }

    @Test("a grade newer than every checkpoint, from the live evaluation, wins; a grader that is still running does not")
    func liveEvaluation() {
        let id = UUID()
        let contract = GoalContract(id: id, objective: "o", criteria: [a], state: .locked)
        let t0 = Date(timeIntervalSince1970: 1_000)
        let history = [CheckpointOutcome(milestoneIndex: 0, milestoneTitle: "x", evaluation: eval([verdict(a, .notMet, "old")], at: t0),
                                         resolution: .humanSentBack, date: t0, contractId: id)]
        let live = eval([verdict(a, .met, "now")], at: t0.addingTimeInterval(500))
        #expect(GoalProgress(conversation(contract: contract, history: history, last: live)).criteria[0].verdict == .met)
        let verifying = eval([verdict(a, .met, "placeholder")], status: .verifying, at: t0.addingTimeInterval(500))
        #expect(GoalProgress(conversation(contract: contract, history: history, last: verifying)).criteria[0].verdict == .notMet)
    }

    @Test("a waiver or the person's judgement is shown instead of the grader's word")
    func waiverAndJudgement() {
        var contract = GoalContract(objective: "o", criteria: [a, c], state: .locked)
        contract.waivers[a.id] = "out of scope now"
        contract.judgements[c.id] = true
        let p = GoalProgress(conversation(contract: contract, last: eval([verdict(a, .notMet), verdict(c, .humanPending)])))
        #expect(GoalProgressView.statusLine(for: p.criteria[0]) == "waived: out of scope now")
        #expect(GoalProgressView.statusLine(for: p.criteria[1]) == "you judged it met")
    }

    @Test("an amended goal: verdicts for criteria it no longer has are counted, not shown, and a new criterion is not graded")
    func amendedGoal() {
        let id = UUID()
        let fresh = Criterion(text: "added later", kind: .qualitative)
        let contract = GoalContract(id: id, objective: "o", criteria: [a, fresh], state: .locked)
        let history = [CheckpointOutcome(milestoneIndex: 0, milestoneTitle: "x", evaluation: eval([verdict(a, .met), verdict(b, .met)]),
                                         resolution: .autoAdvanced, contractId: id)]
        let p = GoalProgress(conversation(contract: contract, history: history))
        #expect(p.criteria.map(\.text) == [a.text, fresh.text])
        #expect(p.criteria[0].verdict == .met && p.criteria[1].verdict == nil)
        #expect(p.supersededVerdicts == 1)
    }

    @Test("history is scoped to this goal: another goal's records and a nil id are not mixed in")
    func scopedHistory() {
        let mine = UUID(), other = UUID()
        let contract = GoalContract(id: mine, objective: "o", criteria: [a], state: .locked)
        let history = [
            CheckpointOutcome(milestoneIndex: 0, milestoneTitle: "old goal", evaluation: nil, resolution: .humanApproved, contractId: other),
            CheckpointOutcome(milestoneIndex: 0, milestoneTitle: "legacy", evaluation: nil, resolution: .humanApproved, contractId: nil),
            CheckpointOutcome(milestoneIndex: 0, milestoneTitle: "this goal", evaluation: nil, resolution: .autoAdvanced, contractId: mine),
        ]
        let p = GoalProgress(conversation(contract: contract, history: history))
        #expect(p.checkpoints.map(\.title).isEmpty == false && p.checkpoints.map { $0.number } == [1])
        #expect(p.checkpoints.count == 1 && p.checkpoints[0].met == nil)
        #expect(GoalProgressView.line(for: p.checkpoints[0]).contains("not graded"))
    }

    @Test("after the goal ends, the newest goal's checkpoints and its last grade remain as a record")
    func endedGoal() {
        let id = UUID()
        let history = [CheckpointOutcome(milestoneIndex: 0, milestoneTitle: "done", evaluation: eval([verdict(a, .met)]), resolution: .humanApproved, contractId: id)]
        let p = GoalProgress(conversation(contract: nil, history: history, last: eval([verdict(a, .met, "all good")])))
        #expect(!p.isLive && p.objective == nil && !p.isEmpty)
        #expect(p.checkpoints.count == 1 && p.criteria.count == 1 && p.criteria[0].evidence == "all good")
    }
}
