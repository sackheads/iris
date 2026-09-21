import Foundation

/// One peer as `list_sessions` reports it (#185 §6.1). Identity comes from the session's own card
/// and is *advertised, not authoritative*; `isBusy` comes from the harness, because liveness is
/// exactly the field a peer must not be able to misreport.
struct SessionPeer: Equatable, Sendable {
    let id: UUID
    let name: String?
    let description: String?
    let workspace: String?
    let isBusy: Bool
}

enum SessionDirectory {
    /// Bounded by construction rather than by habit: §3's active predicate keeps the realistic
    /// count low, but that rests on the user archiving, which is a habit and not a guarantee.
    static let listCap = 20

    static func peers(in conversations: [Conversation], excluding selfId: UUID,
                      busy: (UUID) -> Bool, now: Date) -> (peers: [SessionPeer], total: Int) {
        let active = conversations.filter {
            $0.id != selfId && !$0.isArchived && !$0.isSubagent
        }
        // Most-recently-active first, keyed on the conversation — not `card.updatedAt`, which
        // would rank a session that re-describes itself above one actually doing work.
        let ordered = active.sorted { $0.updatedAt > $1.updatedAt }
        let peers = ordered.prefix(listCap).map {
            SessionPeer(id: $0.id, name: $0.sessionCard?.name, description: $0.sessionCard?.description,
                        workspace: $0.workspacePath, isBusy: busy($0.id))
        }
        return (Array(peers), active.count)
    }
}
