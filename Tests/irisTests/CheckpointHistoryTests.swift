import Testing
import Foundation
@testable import iris

/// Slice D3 state. Both new fields are persisted, so invariant 1 applies: a contract encoded
/// before they existed must decode, not throw — a throw fails the whole [Conversation] decode
/// and drops every conversation.
@Suite("Checkpoint history (D3)")
struct CheckpointHistoryTests {

    @Test("a contract with no checkpointHistory or judgements key decodes to empty")
    func testLegacyContractDecodes() throws {
        // A contract as slice B1 would have persisted it: no D3 fields at all.
        let legacy = """
        {"id":"\(UUID().uuidString)","objective":"ship it","criteria":[],"state":"locked"}
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(GoalContract.self, from: legacy)

        #expect(decoded.checkpointHistory.isEmpty)
        #expect(decoded.judgements.isEmpty)
    }

    @Test("checkpoint outcomes survive an encode/decode round trip")
    func testOutcomeRoundTrip() throws {
        let criterion = Criterion(text: "tests pass", kind: .executable, check: "swift test")
        var contract = GoalContract(objective: "ship it", criteria: [criterion])
        let eval = GoalEvaluation(
            status: .graded,
            criteria: [CriterionVerdict(criterionId: criterion.id, criterionText: criterion.text,
                                        kind: .executable, verdict: .met, evidence: "214 passed",
                                        method: .check)],
            startedAt: Date())
        contract.checkpointHistory = [
            CheckpointOutcome(milestoneIndex: 0, milestoneTitle: "Parser",
                              evaluation: eval, resolution: .autoAdvanced)
        ]
        contract.judgements[criterion.id] = true

        let data = try JSONEncoder().encode(contract)
        let back = try JSONDecoder().decode(GoalContract.self, from: data)

        #expect(back.checkpointHistory.count == 1)
        #expect(back.checkpointHistory[0].resolution == .autoAdvanced)
        #expect(back.checkpointHistory[0].milestoneTitle == "Parser")
        #expect(back.checkpointHistory[0].evaluation.criteria.first?.verdict == .met)
        #expect(back.judgements[criterion.id] == true)
    }
}
