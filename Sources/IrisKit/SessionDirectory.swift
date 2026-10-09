import Foundation

/// What a peer is doing, as the harness observes it (#418). Never read from the session's card:
/// liveness is exactly the field a peer must not be able to misreport (#185 §6.1, #419 point 2).
enum SessionStatus: Equatable, Sendable {
    /// A turn is in flight and nothing it waits on is owed by the user.
    case busy
    /// Blocked on a decision the user owes — `on` is a short harness-written phrase such as
    /// "approval: run_command" — since `since`.
    case waiting(on: String, since: Date)
    /// No turn in flight and nothing owed.
    case idle

    var isLive: Bool {
        if case .idle = self { return false }
        return true
    }
}

/// One peer as `list_sessions` reports it (#185 §6.1). Identity comes from the session's own card
/// and is *advertised, not authoritative*; `status` and `lastActive` come from the harness.
struct SessionPeer: Equatable, Sendable {
    let id: UUID
    let name: String?
    let description: String?
    let workspace: String?
    let status: SessionStatus
    /// When the session last did anything: now for a busy one (a long command writes nothing while
    /// it runs), otherwise the conversation's `updatedAt`.
    let lastActive: Date
}

enum SessionDirectory {
    /// Bounded by construction rather than by habit: §3's active predicate keeps the realistic
    /// count low, but that rests on the user archiving, which is a habit and not a guarantee.
    /// Kept at 20 under #418: each row is at most ~600 bytes, so the cap bounds a listing near
    /// 12 KB, and with the list ordered by activity and live sessions kept ahead of idle ones at
    /// the cut, what falls off the end is the stalest idle tabs — the rows least worth the tokens.
    static let listCap = 20

    /// The active set, without the busy/waiting derivation — for the peer count, which needs only
    /// how many there are.
    static func activePeers(in conversations: [Conversation], excluding selfId: UUID) -> [Conversation] {
        // `isUserFacing` rather than `!isSubagent`: a job run's conversation is a background one
        // (#187) — hidden from the sidebar, fail-closed on every gated tool, and with nobody
        // reading it. Listing it would advertise an address `send_to_session` then refuses.
        conversations.filter { $0.id != selfId && !$0.isArchived && $0.isUserFacing }
    }

    static func peers(in conversations: [Conversation], excluding selfId: UUID,
                      busy: (UUID) -> Bool) -> (peers: [SessionPeer], total: Int) {
        peers(in: conversations, excluding: selfId, now: Date(), status: { busy($0.id) ? .busy : .idle })
    }

    /// Most recently active first (#418). When the set is over the cap, live sessions (busy or
    /// waiting) are kept ahead of idle ones, so a session blocked on the user for a day is not
    /// pushed off the list by twenty tabs someone opened this morning.
    static func peers(in conversations: [Conversation], excluding selfId: UUID, now: Date,
                      status: (Conversation) -> SessionStatus) -> (peers: [SessionPeer], total: Int) {
        let active = activePeers(in: conversations, excluding: selfId)
        // Keyed on the conversation, not `card.updatedAt`, which would rank a session that
        // re-describes itself above one actually doing work.
        let all = active.map { c -> SessionPeer in
            let s = status(c)
            return SessionPeer(id: c.id, name: c.sessionCard?.name, description: c.sessionCard?.description,
                               workspace: c.workspacePath, status: s,
                               lastActive: s == .busy ? now : c.updatedAt)
        }
        let byActivity: (SessionPeer, SessionPeer) -> Bool = {
            $0.lastActive != $1.lastActive ? $0.lastActive > $1.lastActive : $0.id.uuidString < $1.id.uuidString
        }
        let kept = (all.filter { $0.status.isLive }.sorted(by: byActivity)
                    + all.filter { !$0.status.isLive }.sorted(by: byActivity)).prefix(listCap)
        return (kept.sorted(by: byActivity), active.count)
    }

    /// "<1m", "12m", "3h", "4d": how long ago `date` was, coarse on purpose — a peer deciding
    /// whether to wait needs the order of magnitude, and a precise figure churns every call.
    static func age(since date: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return "<1m" }
        if seconds < 3_600 { return "\(Int(seconds / 60))m" }
        if seconds < 86_400 { return "\(Int(seconds / 3_600))h" }
        return "\(Int(seconds / 86_400))d"
    }
}
