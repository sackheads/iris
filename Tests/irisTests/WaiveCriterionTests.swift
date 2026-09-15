import Testing
import Foundation
@testable import iris

/// The escape hatch. Unlocks only after a grade has failed, so the agent must try before declaring
/// something inapplicable (spec §5).
@MainActor
@Suite("waive_criterion (D1)")
struct WaiveCriterionTests {
    private func lockedContract(on app: AppState, _ id: UUID, attempts: Int = 0) -> Criterion {
        app.createNewConversation(id: id)
        let c = Criterion(text: "docs published", kind: .qualitative, check: nil)
        app.setGoalContract(for: id, GoalContract(objective: "ship", criteria: [c]))
        if attempts > 0 {
            for _ in 0..<attempts { app.recordGateRefusal(for: id) }
        }
        return c
    }

    @Test("waiving records the reason against the criterion")
    func waiveRecordsReason() {
        let app = AppState()
        let id = UUID()
        let c = lockedContract(on: app, id, attempts: 1)

        let ok = app.waiveCriterion(for: id, criterionId: c.id, reason: "no docs site exists")

        #expect(ok)
        #expect(app.conversations.first { $0.id == id }?.goalContract?.waivers[c.id] == "no docs site exists")
    }

    @Test("waiving before any failed grade is refused — try first")
    func refusedBeforeAFailedGrade() {
        let app = AppState()
        let id = UUID()
        let c = lockedContract(on: app, id, attempts: 0)

        let ok = app.waiveCriterion(for: id, criterionId: c.id, reason: "cannot be bothered")

        #expect(!ok, "a waiver available on the first attempt is a gate that can be skipped in one move")
        #expect(app.conversations.first { $0.id == id }?.goalContract?.waivers.isEmpty == true)
    }

    @Test("an unknown criterion id is refused")
    func unknownIdRefused() {
        let app = AppState()
        let id = UUID()
        _ = lockedContract(on: app, id, attempts: 1)

        #expect(!app.waiveCriterion(for: id, criterionId: UUID(), reason: "n/a"))
    }

    @Test("a blank reason is refused — the point is the stated reason")
    func blankReasonRefused() {
        let app = AppState()
        let id = UUID()
        let c = lockedContract(on: app, id, attempts: 1)

        #expect(!app.waiveCriterion(for: id, criterionId: c.id, reason: "   "))
    }

    @Test("waiving with no contract is refused")
    func noContractRefused() {
        let app = AppState()
        let id = UUID()
        app.createNewConversation(id: id)

        #expect(!app.waiveCriterion(for: id, criterionId: UUID(), reason: "n/a"))
    }
}
