import Foundation

/// Groups the sidebar search field's `ConversationHit`s for display (#183): the store already
/// ranks hits by bm25 best-match-first, so this only needs to fan them out per conversation
/// without disturbing that order, and cap how many render under any one conversation. Kept as a
/// small pure type, separate from `ChatView`, so the grouping rule is unit-tested without a view.
enum SidebarSearchResults {
    /// One conversation's hits in the Results section, in the order the view renders them.
    struct Group: Identifiable, Equatable {
        let conversationId: UUID
        let title: String
        var hits: [ConversationHit]
        var id: UUID { conversationId }
    }

    /// `hits` is assumed already ranked (best match first). Groups are ordered by each
    /// conversation's *first* appearance in `hits`, not by any later, higher-ranked hit for the
    /// same conversation — otherwise the list would reorder under the user as more of a
    /// conversation's hits are discovered while scanning `hits` in rank order.
    static func group(_ hits: [ConversationHit], perConversation: Int = 3) -> [Group] {
        var order: [UUID] = []
        var byId: [UUID: Group] = [:]
        for hit in hits {
            if var existing = byId[hit.conversationId] {
                guard existing.hits.count < perConversation else { continue }
                existing.hits.append(hit)
                byId[hit.conversationId] = existing
            } else {
                order.append(hit.conversationId)
                byId[hit.conversationId] = Group(conversationId: hit.conversationId, title: hit.title, hits: [hit])
            }
        }
        return order.compactMap { byId[$0] }
    }
}
