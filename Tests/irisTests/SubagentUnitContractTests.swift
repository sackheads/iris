import Testing
import Foundation
@testable import iris

/// Slice B3: the parent hands a subagent a bounded definition-of-done and the finished run
/// carries an independently-graded verdict beside B2's unverified self-report.
@Suite("Subagent unit contract (B3)")
struct SubagentUnitContractTests {

    private func criterion(_ text: String, _ kind: CriterionKind = .qualitative,
                           check: String? = nil) -> Criterion {
        Criterion(text: text, kind: kind, check: check)
    }

    private func result(unitContract: GoalContract? = nil,
                        verdict: GoalEvaluation? = nil,
                        status: SubagentTerminalStatus = .completed,
                        files: [String] = ["Sources/A.swift"]) -> SubagentResult {
        SubagentResult(role: "engineer", status: status, calledGoalComplete: status == .completed,
                       summary: "did the thing", filesWritten: files,
                       startedAt: Date(timeIntervalSince1970: 0), endedAt: Date(timeIntervalSince1970: 5),
                       unitContract: unitContract, verdict: verdict)
    }

    private func evaluation(_ pairs: [(Criterion, CriterionVerdictValue, String)],
                            status: EvaluationStatus = .graded) -> GoalEvaluation {
        GoalEvaluation(status: status,
                       criteria: pairs.map { c, v, evidence in
                           CriterionVerdict(criterionId: c.id, criterionText: c.text, kind: c.kind,
                                            verdict: v, evidence: evidence,
                                            method: c.kind == .executable ? .check : .judge)
                       },
                       startedAt: Date(timeIntervalSince1970: 0),
                       completedAt: Date(timeIntervalSince1970: 5))
    }

    // MARK: - Data model

    @Test("a graded result round-trips unitContract and verdict through Codable")
    func codableRoundTripWithVerdict() throws {
        let c = criterion("builds", .executable, check: "swift build")
        let contract = GoalContract(objective: "ship it", criteria: [c])
        let r = result(unitContract: contract, verdict: evaluation([(c, .met, "exit 0")]))
        let back = try JSONDecoder().decode(SubagentResult.self, from: JSONEncoder().encode(r))
        #expect(back == r)
        #expect(back.unitContract?.objective == "ship it")
        #expect(back.verdict?.criteria.first?.verdict == .met)
    }

    @Test("a B2-era result with no unitContract or verdict keys decodes to nil, not a throw")
    func legacyResultDecodesToNil() throws {
        // Exactly the keys slice B2 wrote — the new keys are absent, as they are in every
        // SubagentResult persisted before B3.
        let legacy: [String: Any] = [
            "schemaVersion": 1, "role": "engineer", "status": "completed",
            "calledGoalComplete": true, "summary": "did the thing",
            "filesWritten": ["Sources/A.swift"],
            "startedAt": 0.0, "endedAt": 5.0
        ]
        let data = try JSONSerialization.data(withJSONObject: legacy)
        let back = try JSONDecoder().decode(SubagentResult.self, from: data)
        #expect(back.unitContract == nil)
        #expect(back.verdict == nil)
        #expect(back.summary == "did the thing")
    }

    // MARK: - Prose

    @Test("an ungraded result renders byte-for-byte the B2 prose")
    func ungradedProseUnchanged() {
        let expected = """
        Subagent 'engineer' finished — status: completed (goal_complete called).
        Summary: did the thing
        Files written (1): Sources/A.swift
        """
        #expect(result().renderedForParent() == expected)
    }

    @Test("a graded result renders the verdict block beside the self-report")
    func gradedProseRendersVerdict() {
        let built = criterion("builds", .executable, check: "swift build")
        let tested = criterion("tests pass", .executable, check: "swift test")
        let rendered = criterion("verdict rendered in prose")
        let contract = GoalContract(objective: "ship it", criteria: [built, tested, rendered])
        let verdict = evaluation([(built, .met, ""), (tested, .met, ""),
                                  (rendered, .notMet, "no verdict block found")])
        let s = result(unitContract: contract, verdict: verdict).renderedForParent()

        #expect(s.contains("Independent grader verdict (fresh context): 2/3 met"))
        #expect(s.contains("✓ builds — met"))
        #expect(s.contains("✗ verdict rendered in prose — not_met: no verdict block found"))
        // The self-report is labeled unverified once a trusted verdict sits beside it.
        #expect(s.contains("Summary (UNVERIFIED self-report): did the thing"))
    }

    @Test("a grader that did not finish is surfaced honestly, not hidden")
    func failedGraderSurfaced() {
        let c = criterion("builds", .executable, check: "swift build")
        let contract = GoalContract(objective: "ship it", criteria: [c])
        let verdict = evaluation([(c, .cannotVerify, "grader never submitted")], status: .failed)
        let s = result(unitContract: contract, verdict: verdict).renderedForParent()

        #expect(s.contains("grader status: failed"))
        #expect(s.contains("? builds — cannot_verify"))
    }

    @Test("a human-judged criterion is rendered as pending, never as a passed gate")
    func humanJudgedNotCountedAsMet() {
        let c = criterion("the design reads well", .humanJudged)
        let contract = GoalContract(objective: "ship it", criteria: [c])
        let verdict = evaluation([(c, .humanPending, "")])
        let s = result(unitContract: contract, verdict: verdict).renderedForParent()

        #expect(s.contains("0/1 met"))
        #expect(s.contains("human_pending"))
    }

    // MARK: - Contract input parsing

    @Test("criteria from the parent parse into a locked-shape unit contract with task as objective")
    func parsesUnitContract() throws {
        let criteria = JSONValue.array([
            .object(["text": .string("builds"), "kind": .string("executable"), "check": .string("swift build")]),
            .object(["text": .string("reads well"), "kind": .string("qualitative")])
        ])
        let contract = try #require(GoalContractParsing.unitContract(task: "add a widget", criteriaJSON: criteria))

        #expect(contract.objective == "add a widget")
        #expect(contract.criteria.count == 2)
        #expect(contract.criteria[0].kind == .executable)
        #expect(contract.criteria[0].check == "swift build")
        #expect(contract.criteria[1].kind == .qualitative)
    }

    @Test("absent or empty criteria yield no contract, preserving the B2 path")
    func noCriteriaYieldsNoContract() {
        #expect(GoalContractParsing.unitContract(task: "add a widget", criteriaJSON: nil) == nil)
        #expect(GoalContractParsing.unitContract(task: "add a widget", criteriaJSON: .array([])) == nil)
        // Criteria present but every entry unusable (no `text`) parses to zero criteria.
        #expect(GoalContractParsing.unitContract(task: "add a widget",
                                                 criteriaJSON: .array([.object(["kind": .string("executable")])])) == nil)
    }

    @Test("milestone labels are stripped — B3 does not wire the checkpoint ladder to delegation")
    func milestonesStripped() throws {
        // A subagent can't call `reach_checkpoint` (it is gated to the main principal), so a
        // ladder in a unit contract would strand the run until its iteration cap.
        let criteria = JSONValue.array([
            .object(["text": .string("first"), "kind": .string("qualitative"), "milestone": .string("one")]),
            .object(["text": .string("second"), "kind": .string("qualitative"), "milestone": .string("two")])
        ])
        let contract = try #require(GoalContractParsing.unitContract(task: "staged work", criteriaJSON: criteria))

        #expect(contract.hasLadder == false)
        #expect(contract.criteria.count == 2)
    }
}
