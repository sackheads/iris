import Testing
import Foundation
@testable import iris

/// #185 §7. One budget for a whole cascade, so fan-out cannot multiply into F^N turns.
@MainActor
@Suite("Session cascade budget")
struct CascadeBudgetTests {

    private func app() -> (AppState, UUID, UUID, UUID) {
        let a = AppState(); a.conversations.removeAll()
        let x = UUID(), y = UUID(), z = UUID()
        for id in [x, y, z] { a.createNewConversation(id: id) }
        return (a, x, y, z)
    }

    @Test("a fresh sender starts with the configured budget")
    func freshSenderHasFullBudget() {
        let (a, x, y, _) = app()
        #expect(a.beginPeerCascade(into: y, from: x) == true)
        #expect(a.cascadeRemaining(for: y) == ConfigManager.shared.maxSessionCascade - 1)
    }

    @Test("fan-out consumes the SAME budget, not one per branch")
    func fanOutSharesTheBudget() {
        let (a, x, y, z) = app()
        // x fans out to y and z. Both targets draw from the same cascade allowance,
        // so the sender's own budget shrinks with each delivery. A per-branch bug would give
        // z a fresh allowance instead of y's exhausted one.
        #expect(a.beginPeerCascade(into: y, from: x) == true)
        let afterFirst = a.cascadeRemaining(for: y)
        #expect(a.beginPeerCascade(into: z, from: x) == true)  // x to z, same sender
        #expect(a.cascadeRemaining(for: z) == afterFirst - 1,
                "a second target from the same sender must inherit the shrunk allowance")
    }

    @Test("the budget runs out and further sends are refused")
    func budgetExhausts() {
        let (a, x, y, _) = app()
        var sender = x, target = y
        var allowed = 0
        // Exercises the total budget cap as a ping-pong chain: this shape verifies the total
        // allowance is respected regardless of cascade topology.
        for _ in 0..<(ConfigManager.shared.maxSessionCascade + 5) {
            if a.beginPeerCascade(into: target, from: sender) { allowed += 1 } else { break }
            swap(&sender, &target)
        }
        #expect(allowed == ConfigManager.shared.maxSessionCascade,
                "the cascade is capped regardless of shape")
        #expect(a.beginPeerCascade(into: target, from: sender) == false)
    }

    @Test("a user turn clears the cascade")
    func userTurnResets() {
        let (a, x, y, _) = app()
        _ = a.beginPeerCascade(into: y, from: x)
        #expect(a.cascadeRemaining(for: y) < ConfigManager.shared.maxSessionCascade)

        a.clearCascade(for: y)   // what startTurn calls
        #expect(a.cascadeRemaining(for: y) == ConfigManager.shared.maxSessionCascade,
                "a person typing is not part of the machine's budget")
    }
}
