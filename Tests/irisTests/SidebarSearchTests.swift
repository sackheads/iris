import Testing
import Foundation
@testable import iris

/// `AppState.reveal(hit:)` (#183): what a tap on a sidebar search result does — select the
/// conversation and point the transcript at the matching message. Reuses the
/// `ConversationStore.inMemory()` + `ConversationWrite` fixture pattern from
/// `ConversationSearchTests` rather than inventing a new one.
@MainActor
@Suite("Sidebar search reveal (#183)")
struct SidebarSearchTests {
    private func conversation(id: UUID = UUID(), title: String, _ messages: [ChatMessage]) -> Conversation {
        var c = Conversation(id: id, title: title)
        c.messages = messages
        return c
    }

    private func created(_ c: Conversation) -> ConversationWrite {
        var s = ChangeSet(); s.add(.created); s.add(.messagesAppended(from: 0))
        return ConversationWrite(id: c.id, snapshot: c, changes: s)
    }

    @Test("reveal selects the hit's conversation and sets pendingScrollTarget to the message at its ordinal")
    func revealSelectsAndScrolls() throws {
        let store = try ConversationStore.inMemory()
        let firstMessages = [ChatMessage(role: .user, content: "kubeconfig question")]
        let secondMessages = [
            ChatMessage(role: .user, content: "how do pelicans fish"),
            ChatMessage(role: .agent, content: "pelicans plunge-dive"),
        ]
        let first = conversation(title: "first", firstMessages)
        let second = conversation(title: "second", secondMessages)
        try store.apply([created(first), created(second)])

        let state = AppState(store: store)
        let hit = ConversationHit(conversationId: second.id, title: "second", role: .agent, ordinal: 1, snippet: "plunge-dive")
        state.reveal(hit: hit)

        #expect(state.selectedConversationId == second.id)
        #expect(state.pendingScrollTarget == secondMessages[1].id)
    }

    @Test("an out-of-range ordinal selects the conversation but leaves pendingScrollTarget nil")
    func revealOutOfRangeOrdinalSelectsOnly() throws {
        let store = try ConversationStore.inMemory()
        let messages = [ChatMessage(role: .user, content: "only one message")]
        let conv = conversation(title: "solo", messages)
        try store.apply([created(conv)])

        let state = AppState(store: store)
        state.pendingScrollTarget = UUID() // prove reveal clears a stale value too
        let hit = ConversationHit(conversationId: conv.id, title: "solo", role: .user, ordinal: 7, snippet: "n/a")
        state.reveal(hit: hit)

        #expect(state.selectedConversationId == conv.id)
        #expect(state.pendingScrollTarget == nil)
    }

    @Test("a hit for a conversation not in memory leaves the current selection untouched (review finding 1)")
    func revealMissingConversationLeavesSelectionUnchanged() throws {
        let store = try ConversationStore.inMemory()
        let conv = conversation(title: "still here", [ChatMessage(role: .user, content: "hello")])
        try store.apply([created(conv)])

        let state = AppState(store: store)
        state.selectedConversationId = conv.id
        state.pendingScrollTarget = UUID() // prove a miss clears a stale target too

        // The FTS index can outlive the in-memory list (e.g. a conversation the load left
        // untouched on disk, or a stale legacy subagent row); reveal must not select its id.
        let missingId = UUID()
        let hit = ConversationHit(conversationId: missingId, title: "gone", role: .user, ordinal: 0, snippet: "n/a")
        state.reveal(hit: hit)

        #expect(state.selectedConversationId == conv.id)
        #expect(state.pendingScrollTarget == nil)
    }

    @Test("end-to-end through the store: search, group, and reveal the winning hit")
    func endToEndSearchGroupReveal() throws {
        let store = try ConversationStore.inMemory()
        let ospreyMessages = [ChatMessage(role: .user, content: "ospreys dive for fish too")]
        let heronMessages = [
            ChatMessage(role: .user, content: "tell me about herons"),
            ChatMessage(role: .agent, content: "herons stand still and wait"),
        ]
        let ospreyConv = conversation(title: "ospreys", ospreyMessages)
        let heronConv = conversation(title: "herons", heronMessages)
        try store.apply([created(ospreyConv), created(heronConv)])

        let hits = try store.searchConversations(query: "herons wait", limit: 50)
        let groups = SidebarSearchResults.group(hits)
        let winner = try #require(groups.first?.hits.first)

        let state = AppState(store: store)
        state.reveal(hit: winner)

        #expect(state.selectedConversationId == heronConv.id)
        #expect(state.pendingScrollTarget == heronMessages[winner.ordinal].id)
    }
}
