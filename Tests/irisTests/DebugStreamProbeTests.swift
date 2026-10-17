import Testing
import Foundation
@testable import IrisKit

/// #541's probe on its measurement branch: one conversation under a fixed id, titled for the
/// script's window check however its first message would have renamed it, and earlier probe
/// conversations cleared through `deleteConversation`.
@MainActor
@Suite("Stream probe conversation (#541)")
struct DebugStreamProbeTests {
    @Test("the probe keeps one conversation, under its id and title, and clears the old ones")
    func oneConversation() throws {
        let state = AppState(store: try ConversationStore.inMemory(), tier2Provisioning: .provisioned,
                             tier3Provisioning: .provisioned)
        let old = state.createNewConversation(title: DebugStreamProbe.title)
        state.appendMessage(role: .user, content: DebugStreamProbe.firstQuestion, to: old)
        #expect(state.conversations.first { $0.id == old }?.title != DebugStreamProbe.title,
                "precondition: the first message renamed the old one, as on work")
        let other = state.createNewConversation()
        state.appendMessage(role: .user, content: "something else", to: other)

        let id = DebugStreamProbe.conversation(in: state)
        #expect(id == DebugStreamProbe.id)
        #expect(state.conversations.first { $0.id == id }?.title == DebugStreamProbe.title)
        #expect(state.conversations.first { $0.id == id }?.messages.count == 40)
        #expect(!state.conversations.contains { $0.id == old }, "the old probe conversation is gone")
        #expect(state.conversations.contains { $0.id == other }, "nothing else is touched")

        #expect(DebugStreamProbe.conversation(in: state) == id, "found again, not seeded again")
        #expect(state.conversations.filter { $0.id == id }.count == 1)
        #expect(state.conversations.first { $0.id == id }?.messages.count == 40)
    }
}
