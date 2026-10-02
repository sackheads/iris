import Testing
import Foundation
@testable import iris

/// 5b: the pinned conversation became "Iris", the owner's main conversation (spec §0.1).
@MainActor
@Suite struct PinnedConversationTests {
    private func app() throws -> (ConversationStore, AppState) {
        let store = try ConversationStore.inMemory()
        let state = AppState(store: store, tier2Provisioning: .provisioned, tier3Provisioning: .provisioned)
        return (store, state)
    }

    @Test func newPinnedConversationIsTitledIris() throws {
        let (_, state) = try app()
        let id = state.activityConversationId()
        #expect(state.conversations.first { $0.id == id }?.title == "Iris")
    }

    @Test func legacyTitleIsRetitledButOwnerRenameIsKept() throws {
        let (_, state) = try app()
        let id = state.activityConversationId()
        let idx = state.conversations.firstIndex { $0.id == id }!
        state.conversations[idx].title = "Iris Activity"
        state.retitleLegacyPinnedConversation()
        #expect(state.conversations[idx].title == "Iris")
        state.conversations[idx].title = "My HQ"
        state.retitleLegacyPinnedConversation()
        #expect(state.conversations[idx].title == "My HQ")
    }
}
