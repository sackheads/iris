import Testing
import Foundation
@testable import iris

@Suite("GoalEvaluation model")
struct GoalEvaluationTests {
    private func sample() -> GoalEvaluation {
        GoalEvaluation(
            status: .graded,
            criteria: [
                CriterionVerdict(criterionId: UUID(), criterionText: "swift build green",
                                 kind: .executable, verdict: .met,
                                 evidence: "swift build → exit 0", method: .check),
                CriterionVerdict(criterionId: UUID(), criterionText: "looks good",
                                 kind: .humanJudged, verdict: .humanPending,
                                 evidence: "", method: .human)
            ],
            startedAt: Date(timeIntervalSince1970: 100),
            completedAt: Date(timeIntervalSince1970: 200))
    }

    @Test("round-trips through Codable")
    func codable() throws {
        let e = sample()
        let back = try JSONDecoder().decode(GoalEvaluation.self, from: JSONEncoder().encode(e))
        #expect(back == e)
    }

    @Test("a legacy conversation with no evaluation decodes with nil")
    func legacyNil() throws {
        let json = #"{"id":"\#(UUID().uuidString)","title":"t","messages":[],"history":[],"tokenUsage":{"promptTokenCount":0,"candidatesTokenCount":0,"totalTokenCount":0},"messageCountSinceReflection":0}"#
        let conv = try JSONDecoder().decode(Conversation.self, from: Data(json.utf8))
        #expect(conv.lastGoalEvaluation == nil)
    }

    @Test("verdict + method + status enums are string-coded")
    func rawValues() {
        #expect(CriterionVerdictValue.notMet.rawValue == "not_met")
        #expect(CriterionVerdictValue.cannotVerify.rawValue == "cannot_verify")
        #expect(CriterionVerdictValue.humanPending.rawValue == "human_pending")
        #expect(EvaluationStatus.verifying.rawValue == "verifying")
        #expect(VerdictMethod.check.rawValue == "check")
    }

    // MARK: - #204 round 2: lenient decoder for the nested CriterionVerdict

    @Test("a CriterionVerdict JSON missing every defaultable field decodes to safe defaults")
    func criterionVerdictLenientDecode() throws {
        let criterionId = UUID()
        let json = #"{"criterionId":"\#(criterionId.uuidString)"}"#
        let v = try JSONDecoder().decode(CriterionVerdict.self, from: Data(json.utf8))
        #expect(v.criterionId == criterionId)
        #expect(v.criterionText == "")
        #expect(v.kind == .qualitative)
        #expect(v.verdict == .cannotVerify)
        #expect(v.evidence == "")
        #expect(v.method == .judge)
    }

    @Test("a CriterionVerdict JSON missing criterionId decodes with a freshly minted one (round 3: losing the whole conversation is worse than an orphaned verdict)")
    func criterionVerdictMissingCriterionIdDefaultsToFreshUUID() throws {
        let json = #"{"criterionText":"x"}"#
        let v = try JSONDecoder().decode(CriterionVerdict.self, from: Data(json.utf8))
        #expect(v.criterionText == "x")
        // criterionId is not asserted to any specific value -- only that decode did not throw.
    }

    @Test("a GoalEvaluation whose criteria element is missing defaultable fields still decodes")
    func goalEvaluationWithLenientNestedVerdictDecodes() throws {
        let criterionId = UUID()
        let json = """
        {"status":"graded","criteria":[{"criterionId":"\(criterionId.uuidString)"}],"startedAt":0}
        """
        let e = try JSONDecoder().decode(GoalEvaluation.self, from: Data(json.utf8))
        #expect(e.criteria.count == 1)
        #expect(e.criteria.first?.criterionId == criterionId)
        #expect(e.criteria.first?.verdict == .cannotVerify)
    }
}
