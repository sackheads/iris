import Testing
import Foundation
@testable import iris

@Suite("Goal workspace on the contract (#68)")
struct GoalWorkspaceContractTests {
    @Test("a contract round-trips its workspace")
    func roundTrip() throws {
        var c = GoalContract(objective: "ship", criteria: [])
        c.workspace = "/src/foo"
        let back = try JSONDecoder().decode(GoalContract.self, from: JSONEncoder().encode(c))
        #expect(back.workspace == "/src/foo")
    }

    @Test("a pre-#68 contract decodes with workspace nil, not a throw")
    func legacyDecodes() throws {
        // The failure mode this guards: one missing key fails the WHOLE [Conversation] decode.
        let legacy: [String: Any] = [
            "objective": "ship",
            "criteria": [["id": UUID().uuidString, "text": "builds", "kind": "qualitative"]],
            "state": "locked"
        ]
        let data = try JSONSerialization.data(withJSONObject: legacy)
        let back = try JSONDecoder().decode(GoalContract.self, from: data)
        #expect(back.workspace == nil)
        #expect(back.objective == "ship")
    }

    @Test("a Conversation carrying a pre-#68 contract still decodes")
    func legacyConversationDecodes() throws {
        var conv = Conversation(title: "old")
        conv.goalContract = GoalContract(objective: "ship", criteria: [])
        let back = try JSONDecoder().decode(Conversation.self, from: JSONEncoder().encode(conv))
        #expect(back.goalContract?.workspace == nil)
        #expect(back.title == "old")
    }

    @Test("propose_goal_contract's workspace argument reaches the contract")
    func parsesWorkspace() throws {
        let contract = try #require(GoalContractParsing.contract(from: [
            "objective": .string("fix the parser"),
            "criteria": .array([.object(["text": .string("builds"), "kind": .string("qualitative")])]),
            "workspace": .string("~/src/foo")
        ]))
        #expect(contract.workspace == "~/src/foo")
    }

    @Test("an omitted workspace parses to nil rather than an empty string")
    func absentWorkspaceIsNil() throws {
        let contract = try #require(GoalContractParsing.contract(from: [
            "objective": .string("ship"),
            "criteria": .array([.object(["text": .string("builds"), "kind": .string("qualitative")])])
        ]))
        #expect(contract.workspace == nil)
    }
}
