import Testing
import Foundation
@testable import IrisKit

@MainActor
@Suite("GoalContract amend")
struct GoalContractAmendTests {
    private func lockedConv(_ app: AppState) -> UUID {
        let id = UUID()
        app.createNewConversation(id: id)
        var c = GoalContract(objective: "obj", criteria: [Criterion(text: "old", kind: .qualitative, check: nil)])
        c.lock()
        app.setGoalContract(for: id, c)
        return id
    }

    @Test("adding a criterion with a rationale succeeds and logs the change")
    func addWithRationale() {
        let app = AppState(); let id = lockedConv(app)
        let ok = app.amendGoalContract(for: id, action: "add", criterionText: "new", kind: "qualitative", check: nil, rationale: "found a missing case")
        #expect(ok)
        let c = app.conversations.first { $0.id == id }?.goalContract
        #expect(c?.criteria.contains { $0.text == "new" } == true)
        #expect(c?.changeLog.count == 1)
    }

    @Test("amending without a rationale is rejected and changes nothing")
    func rejectNoRationale() {
        let app = AppState(); let id = lockedConv(app)
        let ok = app.amendGoalContract(for: id, action: "add", criterionText: "new", kind: "qualitative", check: nil, rationale: "  ")
        #expect(!ok)
        #expect(app.conversations.first { $0.id == id }?.goalContract?.criteria.count == 1)
    }
}
