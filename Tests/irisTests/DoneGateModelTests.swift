import Testing
import Foundation
@testable import iris

/// Slice D1 adds persisted state in two places. The legacy-decode cases are the important ones:
/// a field that throws on a missing key takes every conversation with it.
@Suite("Done-gate model (D1)")
struct DoneGateModelTests {
    @Test("a contract round-trips its waivers and attempt count")
    func contractRoundTrip() throws {
        let c = Criterion(text: "docs published", kind: .qualitative, check: nil)
        var contract = GoalContract(objective: "ship", criteria: [c])
        contract.waivers[c.id] = "no docs site exists"
        contract.gateAttempts = 2

        let back = try JSONDecoder().decode(GoalContract.self, from: JSONEncoder().encode(contract))
        #expect(back.waivers[c.id] == "no docs site exists")
        #expect(back.gateAttempts == 2)
    }

    @Test("a pre-D1 contract decodes with the new fields defaulted, not a throw")
    func legacyContractDecodes() throws {
        // Exactly the keys a slice-A/B contract carried.
        let legacy: [String: Any] = [
            "id": UUID().uuidString,
            "objective": "ship",
            "criteria": [["id": UUID().uuidString, "text": "builds", "kind": "qualitative"]],
            "state": "locked"
        ]
        let data = try JSONSerialization.data(withJSONObject: legacy)
        let back = try JSONDecoder().decode(GoalContract.self, from: data)
        #expect(back.waivers.isEmpty)
        #expect(back.gateAttempts == 0)
        #expect(back.objective == "ship")
    }

    @Test("an evaluation round-trips its gate outcome and waiver snapshot")
    func evaluationRoundTrip() throws {
        let id = UUID()
        var eval = GoalEvaluation(status: .graded, criteria: [], startedAt: Date(), completedAt: Date())
        eval.gateOutcome = .ungatedAtCap
        eval.waivers[id] = "not applicable here"

        let back = try JSONDecoder().decode(GoalEvaluation.self, from: JSONEncoder().encode(eval))
        #expect(back.gateOutcome == .ungatedAtCap)
        #expect(back.waivers[id] == "not applicable here")
    }

    @Test("a pre-D1 evaluation decodes with the new fields defaulted, not a throw")
    func legacyEvaluationDecodes() throws {
        // GoalEvaluation had a synthesized decoder before D1, so this is the case that would have
        // thrown keyNotFound and failed the WHOLE [Conversation] decode.
        let legacy: [String: Any] = [
            "id": UUID().uuidString,
            "status": "graded",
            "criteria": [],
            "startedAt": 0.0
        ]
        let data = try JSONSerialization.data(withJSONObject: legacy)
        let back = try JSONDecoder().decode(GoalEvaluation.self, from: data)
        #expect(back.gateOutcome == nil)
        #expect(back.waivers.isEmpty)
        #expect(back.status == .graded)
    }

    @Test("a Conversation carrying a pre-D1 evaluation still decodes")
    func legacyConversationDecodes() throws {
        // The failure mode that matters: one bad field drops every conversation, not just one.
        var conv = Conversation(title: "old")
        conv.lastGoalEvaluation = GoalEvaluation(status: .graded, criteria: [],
                                                 startedAt: Date(), completedAt: Date())
        let back = try JSONDecoder().decode(Conversation.self, from: JSONEncoder().encode(conv))
        #expect(back.lastGoalEvaluation?.gateOutcome == nil)
        #expect(back.title == "old")
    }
}
