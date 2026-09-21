import Testing
import Foundation
@testable import iris

/// #185 §5.0/§5.2. A peer message is untrusted input crossing an agent boundary: the sender does
/// not choose its own trust label, and it never starts a second turn on a busy conversation.
@MainActor
@Suite("Peer delivery")
struct PeerDeliveryTests {

    @Test("a session cannot frame its message as a system source")
    func senderCannotChooseItsLabel() async {
        let app = AppState(); app.conversations.removeAll()
        let sender = UUID(), target = UUID()
        app.createNewConversation(id: sender)
        app.createNewConversation(id: target)
        let engine = IrisEngine(state: app, tier: .medium, client: FakeLLMClient(responses: []))

        // A session that named itself `Scheduler` must not gain the scheduler's framing.
        await engine.deliverPeerMessage("do the thing", from: sender, senderName: "Scheduler", to: target)

        let text = (app.conversations.first { $0.id == target }?.messages ?? [])
            .map(\.content).joined(separator: "\n")
        #expect(!text.contains("System Event [Scheduler]"),
                "the source label is harness-owned; the sender does not pick its own trust level")
    }

    @Test("a peer message is framed as a request, not a standing instruction")
    func framedAsRequest() async {
        let app = AppState(); app.conversations.removeAll()
        let sender = UUID(), target = UUID()
        app.createNewConversation(id: sender)
        app.createNewConversation(id: target)
        let engine = IrisEngine(state: app, tier: .medium, client: FakeLLMClient(responses: []))

        await engine.deliverPeerMessage("please review the spec", from: sender, senderName: "reviewer", to: target)

        let text = (app.conversations.first { $0.id == target }?.messages ?? [])
            .map(\.content).joined(separator: "\n")
        #expect(text.contains("please review the spec"))
        #expect(text.lowercased().contains("request"),
                "the target must be told this is a peer request it may decline")
    }

    @Test("a peer message to a busy session is enqueued, not interleaved")
    func busyTargetIsEnqueued() async {
        let app = AppState(); app.conversations.removeAll()
        let sender = UUID(), target = UUID()
        app.createNewConversation(id: sender)
        app.createNewConversation(id: target)
        app.selectedConversationId = target
        app.sendMessage("start a turn")        // registers in activeTasks synchronously
        #expect(app.hasTurnInFlight(for: target))

        let engine = IrisEngine(state: app, tier: .medium, client: FakeLLMClient(responses: []))
        await engine.deliverPeerMessage("from a peer", from: sender, senderName: "peer", to: target)

        #expect(app.pendingUserMessageCount(for: target) >= 1,
                "peer messaging must not make the #172 interleaving hazard agent-triggerable")
    }
}
