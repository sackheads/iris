import Testing
import Foundation
@testable import iris

/// Pure grouping logic behind the sidebar's "Results" section (#183): fan `ConversationHit`s
/// (already ranked by the store's bm25 order) out into per-conversation groups without losing
/// that rank, and cap how many hits render under any one conversation.
@Suite("Sidebar search results grouping (#183)")
struct SidebarSearchResultsTests {
    private func hit(_ conversationId: UUID, title: String = "conv", ordinal: Int, snippet: String = "snippet") -> ConversationHit {
        ConversationHit(conversationId: conversationId, title: title, role: .user, ordinal: ordinal, snippet: snippet)
    }

    @Test("rank is preserved: groups appear in the order their first hit was seen")
    func rankPreservedByFirstHit() {
        let a = UUID(); let b = UUID(); let c = UUID()
        // b's best hit ranks first, then a, then c.
        let hits = [hit(b, ordinal: 0), hit(a, ordinal: 0), hit(c, ordinal: 0)]
        let groups = SidebarSearchResults.group(hits)
        #expect(groups.map(\.conversationId) == [b, a, c])
    }

    @Test("a conversation's hits are capped at perConversation, keeping the earliest-ranked ones")
    func perConversationCapEnforced() {
        let a = UUID()
        let hits = (0..<5).map { hit(a, ordinal: $0) }
        let groups = SidebarSearchResults.group(hits, perConversation: 3)
        #expect(groups.count == 1)
        #expect(groups[0].hits.map(\.ordinal) == [0, 1, 2])
    }

    @Test("a conversation seen again later, even with a higher-ranked hit, sorts by its first appearance")
    func laterHigherRankedHitDoesNotReorderGroup() {
        let a = UUID(); let b = UUID()
        // a appears first (rank 0), b next (rank 1), then a again (rank 2) — a's group must stay first.
        let hits = [hit(a, ordinal: 0), hit(b, ordinal: 0), hit(a, ordinal: 5)]
        let groups = SidebarSearchResults.group(hits)
        #expect(groups.map(\.conversationId) == [a, b])
        #expect(groups[0].hits.map(\.ordinal) == [0, 5])
    }

    @Test("empty input produces empty output")
    func emptyInputEmptyOutput() {
        #expect(SidebarSearchResults.group([]).isEmpty)
    }
}
