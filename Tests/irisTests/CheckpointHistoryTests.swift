import Testing
import Foundation
@testable import iris

/// Slice D3 state. `judgements` is contract-scoped and dies with the contract; `checkpointHistory`
/// is the audit trail and lives on the CONVERSATION, which outlives the goal. Both are persisted,
/// so invariant 1 applies to each: a record encoded before they existed must decode, not throw —
/// a throw fails the whole [Conversation] decode and drops every conversation.
@Suite("Checkpoint history (D3)")
struct CheckpointHistoryTests {

    @Test("a contract with no judgements key decodes to empty")
    func testLegacyContractDecodes() throws {
        // A contract as slice B1 would have persisted it: no D3 fields at all.
        let legacy = """
        {"id":"\(UUID().uuidString)","objective":"ship it","criteria":[],"state":"locked"}
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(GoalContract.self, from: legacy)

        #expect(decoded.judgements.isEmpty)
    }

    @Test("a conversation with no checkpointHistory key decodes to empty")
    func testLegacyConversationDecodes() throws {
        let legacy = """
        {"id":"\(UUID().uuidString)","title":"old chat"}
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(Conversation.self, from: legacy)

        #expect(decoded.checkpointHistory.isEmpty)
    }

    @Test("checkpoint outcomes survive an encode/decode round trip on the conversation")
    func testOutcomeRoundTrip() throws {
        let criterion = Criterion(text: "tests pass", kind: .executable, check: "swift test")
        var contract = GoalContract(objective: "ship it", criteria: [criterion])
        contract.judgements[criterion.id] = true
        let eval = GoalEvaluation(
            status: .graded,
            criteria: [CriterionVerdict(criterionId: criterion.id, criterionText: criterion.text,
                                        kind: .executable, verdict: .met, evidence: "214 passed",
                                        method: .check)],
            startedAt: Date())
        var conversation = Conversation(title: "ship it", goalContract: contract)
        conversation.checkpointHistory = [
            CheckpointOutcome(milestoneIndex: 0, milestoneTitle: "Parser",
                              evaluation: eval, resolution: .autoAdvanced)
        ]

        let data = try JSONEncoder().encode(conversation)
        let back = try JSONDecoder().decode(Conversation.self, from: data)

        #expect(back.checkpointHistory.count == 1)
        #expect(back.checkpointHistory[0].resolution == .autoAdvanced)
        #expect(back.checkpointHistory[0].milestoneTitle == "Parser")
        #expect(back.checkpointHistory[0].evaluation?.criteria.first?.verdict == .met)
        #expect(back.goalContract?.judgements[criterion.id] == true)
    }

    @Test("an outcome recorded with no grade round-trips as nil, not as a fake failure")
    func testNilEvaluationRoundTrips() throws {
        // `sanitizeLoaded` nils `lastGoalEvaluation` on load, so an Approve/Send-back after a
        // restart genuinely has no grade. A synthesized `.failed` here would be indistinguishable
        // in the audit trail from a grader that actually ran and failed.
        var conversation = Conversation(title: "ship it")
        conversation.checkpointHistory = [
            CheckpointOutcome(milestoneIndex: 1, milestoneTitle: "Integration",
                              evaluation: nil, resolution: .humanApproved)
        ]

        let back = try JSONDecoder().decode(Conversation.self,
                                            from: try JSONEncoder().encode(conversation))

        #expect(back.checkpointHistory.first?.evaluation == nil)
        #expect(back.checkpointHistory.first?.resolution == .humanApproved)
    }
}
