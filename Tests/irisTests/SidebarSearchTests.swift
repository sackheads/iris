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

    /// #187: a job run's transcript is a background conversation — out of the sidebar, read-only,
    /// and with a composer that would refuse anything typed into it. Selecting one from a search
    /// hit would put exactly that dead end in the main pane, so the hit opens the same read-only
    /// sheet the session strip uses instead and the selection is left alone.
    @Test("a search hit on a background run opens the transcript sheet and never selects it")
    func revealBackgroundOpensSheetWithoutSelecting() throws {
        let store = try ConversationStore.inMemory()
        let messages = [ChatMessage(role: .user, content: "the shelved kubeconfig note")]
        var run = conversation(title: "pr-sweep run", messages)
        run.isBackground = true
        let visible = conversation(title: "visible", [ChatMessage(role: .user, content: "hello")])
        try store.apply([created(visible), created(run)])

        let state = AppState(store: store)
        state.selectedConversationId = visible.id
        state.pendingScrollTarget = UUID()

        let hit = ConversationHit(conversationId: run.id, title: "pr-sweep run", role: .user,
                                  ordinal: 0, snippet: "kubeconfig")
        state.reveal(hit: hit)

        #expect(state.selectedConversationId == visible.id, "a hidden run must never become the open conversation")
        #expect(state.pendingScrollTarget == nil)
        #expect(state.transcriptSheetConversationId == run.id, "it is still readable, read-only")
    }

    /// #182 §11: the Results section replaces both sidebar sections while a query is active, so an
    /// archived conversation is reachable by search. Revealing one must select it like any other —
    /// the Archived group's auto-expand is what then makes the selected row visible.
    @Test("a search hit on an archived conversation still reveals and selects it")
    func revealArchivedConversation() throws {
        let store = try ConversationStore.inMemory()
        let messages = [ChatMessage(role: .user, content: "the shelved kubeconfig note")]
        var conv = conversation(title: "shelved", messages)
        conv.isArchived = true
        try store.apply([created(conv)])

        let state = AppState(store: store)
        #expect(state.conversations.first { $0.id == conv.id }?.isArchived == true,
                "the fixture only tests the reveal if the row really is archived")

        let hit = try #require(try store.searchConversations(query: "kubeconfig", limit: 50).first)
        state.reveal(hit: hit)

        #expect(state.selectedConversationId == conv.id)
        #expect(state.pendingScrollTarget == messages[hit.ordinal].id)
        #expect(state.conversations.first { $0.id == conv.id }?.isArchived == true,
                "revealing is reading, not work: it must not un-archive")
    }
}
