import Testing
import Foundation
@testable import IrisKit

@Suite("GoalContract persistence & migration")
struct GoalContractMigrationTests {
    @Test("a legacy conversation with only activeGoal decodes as a locked single-criterion contract")
    func legacyUpgrade() throws {
        let legacy = #"{"id":"\#(UUID().uuidString)","title":"t","messages":[],"history":[],"tokenUsage":{"promptTokenCount":0,"candidatesTokenCount":0,"totalTokenCount":0},"activeGoal":"ship the thing","messageCountSinceReflection":0}"#
        let conv = try JSONDecoder().decode(Conversation.self, from: Data(legacy.utf8))
        #expect(conv.activeGoal == "ship the thing")
        #expect(conv.goalContract?.isLocked == true)
        #expect(conv.goalContract?.objective == "ship the thing")
        #expect(conv.goalContract?.criteria.count == 1)
        #expect(conv.goalContract?.criteria.first?.kind == .qualitative)
    }

    @Test("a conversation with no goal decodes with nil contract")
    func noGoal() throws {
        let json = #"{"id":"\#(UUID().uuidString)","title":"t","messages":[],"history":[],"tokenUsage":{"promptTokenCount":0,"candidatesTokenCount":0,"totalTokenCount":0},"messageCountSinceReflection":0}"#
        let conv = try JSONDecoder().decode(Conversation.self, from: Data(json.utf8))
        #expect(conv.goalContract == nil)
        #expect(conv.activeGoal == nil)
    }
}
