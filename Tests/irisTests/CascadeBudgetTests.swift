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

    /// The discriminating shape for "shared" versus "copied" (whole-branch review, C1). The
    /// existing ping-pong and fan-out tests cannot tell the two apart: in a ping-pong the sender
    /// is always the most recent target, and in a fan-out the sender never changes, so a copied
    /// allowance and a shared one produce identical numbers. A chain that walks AWAY from the
    /// original sender separates them — x is left holding whatever it was given at step one.
    @Test("a chain that spends the budget binds the original sender too")
    func spentChainBindsOriginalSender() {
        let a = AppState(); a.conversations.removeAll()
        let budget = ConfigManager.shared.maxSessionCascade
        // One conversation per chain link, plus a fresh target for the probe at the end.
        let ids = (0...(budget + 1)).map { _ in UUID() }
        for id in ids { a.createNewConversation(id: id) }

        // x -> y, y -> z, z -> a, ... exactly `budget` deliveries; each target becomes the next
        // sender, so the cascade is spent by the last one.
        for step in 0..<budget {
            #expect(a.beginPeerCascade(into: ids[step + 1], from: ids[step]) == true,
                    "delivery \(step + 1) of \(budget) is still within the allowance")
        }
        #expect(a.cascadeRemaining(for: ids[budget]) == 0, "the chain's tail is spent")

        // The original sender is in the SAME cascade, so it is spent too. Under a per-conversation
        // copy of the allowance x still holds the high count it was handed at step one.
        #expect(a.beginPeerCascade(into: ids[budget + 1], from: ids[0]) == false,
                "the budget belongs to the cascade, not to each conversation in it")
    }

    /// `clearCascade` is per conversation by design (§7): a person typing frees THAT conversation,
    /// and sibling branches keep whatever the cascade has left. Sharing the counter must not turn
    /// one user turn into a refund for every session still in the old cascade.
    @Test("a user turn frees only its own conversation, not the rest of the cascade")
    func clearingOneDoesNotRefundSiblings() {
        let (a, x, y, z) = app()
        #expect(a.beginPeerCascade(into: y, from: x) == true)
        #expect(a.beginPeerCascade(into: z, from: x) == true)
        let spent = a.cascadeRemaining(for: z)

        a.clearCascade(for: y)   // the user types into y
        #expect(a.cascadeRemaining(for: y) == ConfigManager.shared.maxSessionCascade,
                "the conversation the user steered starts fresh")
        #expect(a.cascadeRemaining(for: z) == spent,
                "a sibling still in the old cascade keeps its remaining allowance")
        #expect(a.cascadeRemaining(for: x) == spent,
                "and so does the original sender")
    }
}
