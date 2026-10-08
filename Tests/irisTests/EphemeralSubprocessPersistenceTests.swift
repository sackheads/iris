import Testing
import Foundation
@testable import IrisKit

@Suite("Ephemeral sub-process persistence")
struct EphemeralSubprocessPersistenceTests {
    private func conv(_ title: String, isSubagent: Bool) -> Conversation {
        var c = Conversation(id: UUID(), title: title)
        c.isSubagent = isSubagent
        return c
    }

    @Test("durableConversations drops subagent/evaluator scratch conversations")
    func durableFilters() {
        let all = [conv("main", isSubagent: false),
                   conv("Evaluator", isSubagent: true),
                   conv("Subagent: coder", isSubagent: true)]
        let durable = AppState.durableConversations(all)
        #expect(durable.count == 1)
        #expect(durable.first?.title == "main")
    }

    @Test("sanitizeLoaded purges orphaned sub-process conversations from old data")
    func loadPurgesOrphans() {
        let decoded = [conv("main", isSubagent: false), conv("Evaluator", isSubagent: true)]
        let loaded = AppState.sanitizeLoaded(decoded)
        #expect(loaded.map { $0.isSubagent } == [false])   // only the durable one survives
    }

    @Test("sanitizeLoaded clears the transient completion-chip surfacing on load")
    func loadClearsCompletionSurfacing() {
        var main = conv("main", isSubagent: false)
        main.lastGoalEvaluation = GoalEvaluation(
            status: .verifying,
            criteria: [CriterionVerdict(criterionId: UUID(), criterionText: "c", kind: .qualitative,
                                        verdict: .cannotVerify, evidence: "", method: .judge)],
            startedAt: Date(timeIntervalSince1970: 100), completedAt: nil)
        main.lastGoalCompletionReport = .array([.object(["criterion": .string("c"), "status": .string("met")])])
        let loaded = AppState.sanitizeLoaded([main])
        #expect(loaded.first?.lastGoalEvaluation == nil)          // chip surfacing dropped
        #expect(loaded.first?.lastGoalCompletionReport == nil)
    }

    @Test("sanitizeLoaded preserves the conversation itself and its goal state")
    func loadKeepsConversation() {
        var main = conv("main", isSubagent: false)
        main.activeGoal = "ship it"
        main.lastGoalCompletionReport = .array([.object(["criterion": .string("c"), "status": .string("met")])])
        let loaded = AppState.sanitizeLoaded([main])
        #expect(loaded.count == 1)                                 // conversation survives
        #expect(loaded.first?.activeGoal == "ship it")             // durable goal state intact
        #expect(loaded.first?.lastGoalCompletionReport == nil)     // only the chip surfacing cleared
    }
}
