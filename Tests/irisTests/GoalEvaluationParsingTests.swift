import Testing
import Foundation
@testable import iris

@Suite("GoalEvaluation parsing")
struct GoalEvaluationParsingTests {
    private func criteria() -> [Criterion] {
        [Criterion(text: "build", kind: .executable, check: "swift build"),
         Criterion(text: "playable", kind: .qualitative, check: nil),
         Criterion(text: "tasteful", kind: .humanJudged, check: nil)]
    }

    @Test("maps submitted verdicts to the right criteria by id")
    func maps() {
        let c = criteria()
        let args: [String: JSONValue] = ["evaluations": .array([
            .object(["criterion_id": .string(c[0].id.uuidString), "verdict": .string("met"), "evidence": .string("exit 0")]),
            .object(["criterion_id": .string(c[1].id.uuidString), "verdict": .string("not_met"), "evidence": .string("crashes on start")])
        ])]
        let out = GoalEvaluationParsing.verdicts(from: args, criteria: c)
        #expect(out.count == 3)
        #expect(out.first { $0.criterionId == c[0].id }?.verdict == .met)
        #expect(out.first { $0.criterionId == c[0].id }?.method == .check)     // executable → check
        #expect(out.first { $0.criterionId == c[1].id }?.verdict == .notMet)
        #expect(out.first { $0.criterionId == c[1].id }?.method == .judge)     // qualitative → judge
    }

    @Test("an omitted humanJudged criterion becomes humanPending, other omissions cannot_verify")
    func reconciliation() {
        let c = criteria()
        // Only the executable criterion is reported; the other two are omitted.
        let args: [String: JSONValue] = ["evaluations": .array([
            .object(["criterion_id": .string(c[0].id.uuidString), "verdict": .string("met"), "evidence": .string("ok")])
        ])]
        let out = GoalEvaluationParsing.verdicts(from: args, criteria: c)
        #expect(out.first { $0.criterionId == c[1].id }?.verdict == .cannotVerify)   // qualitative omitted
        #expect(out.first { $0.criterionId == c[2].id }?.verdict == .humanPending)   // humanJudged omitted
        #expect(out.first { $0.criterionId == c[2].id }?.method == .human)
    }

    @Test("a grader that volunteers a verdict on a humanJudged criterion is ignored")
    func graderCannotGradeAHumanJudgedCriterion() {
        let c = criteria()
        // The prompt forbids this twice, but a prompt is not a guarantee. Taking the verdict would
        // complete the goal `.passed` with nobody having judged — the exact hole D2 exists to
        // close — and would then announce a grader's call as "your judgement" (spec §4.4, §6).
        let args: [String: JSONValue] = ["evaluations": .array([
            .object(["criterion_id": .string(c[2].id.uuidString), "verdict": .string("met"),
                     "evidence": .string("looks tasteful to me")])
        ])]
        let out = GoalEvaluationParsing.verdicts(from: args, criteria: c)
        let judged = out.first { $0.criterionId == c[2].id }
        #expect(judged?.verdict == .humanPending, "only the user may decide a humanJudged criterion")
        #expect(judged?.evidence == "", "the grader's reasoning is not evidence for the user's call")
    }

    @Test("a grader rejecting a humanJudged criterion is ignored too")
    func graderCannotFailAHumanJudgedCriterion() {
        let c = criteria()
        let args: [String: JSONValue] = ["evaluations": .array([
            .object(["criterion_id": .string(c[2].id.uuidString), "verdict": .string("not_met"),
                     "evidence": .string("I did not like it")])
        ])]
        let out = GoalEvaluationParsing.verdicts(from: args, criteria: c)
        #expect(out.first { $0.criterionId == c[2].id }?.verdict == .humanPending)
    }

    @Test("an unknown verdict string falls back to cannot_verify")
    func unknownVerdict() {
        let c = criteria()
        let args: [String: JSONValue] = ["evaluations": .array([
            .object(["criterion_id": .string(c[0].id.uuidString), "verdict": .string("bogus"), "evidence": .string("")])
        ])]
        let out = GoalEvaluationParsing.verdicts(from: args, criteria: c)
        #expect(out.first { $0.criterionId == c[0].id }?.verdict == .cannotVerify)
    }
}
