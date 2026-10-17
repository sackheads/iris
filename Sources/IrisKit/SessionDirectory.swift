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

/// What a peer is, as the harness tells it apart — never claimed by the session itself (#469
/// §4.1).
enum SessionKind: String, Sendable { case iris, role, worker }

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
    var kind: SessionKind = .worker
    var role: String? = nil
    var lane: String? = nil
    var skills: [AgentSkill] = []
    var project: GitProject? = nil

    init(id: UUID, name: String?, description: String?, workspace: String?, status: SessionStatus,
         lastActive: Date, kind: SessionKind = .worker, role: String? = nil, lane: String? = nil,
         skills: [AgentSkill] = [], project: GitProject? = nil) {
        self.id = id; self.name = name; self.description = description; self.workspace = workspace
        self.status = status; self.lastActive = lastActive
        self.kind = kind; self.role = role; self.lane = lane; self.skills = skills; self.project = project
    }
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

    /// One conversation's row. Shared by `peers(in:...)` and `describe_session`'s direct lookup,
    /// which must be able to build a peer that the 20-entry cap below would otherwise hide.
    /// `project` has no default: both callers pass `false` and fill it in afterwards with
    /// `withProjects(_:)`, off the MainActor — a listing or a single-row lookup reading `.git`
    /// inline, inside the MainActor hop both run under, would block the UI actor on filesystem
    /// I/O with no bound of its own. A default here was unused by any caller and invited a third
    /// one to reintroduce exactly that inline read by omission.
    static func peer(for c: Conversation, now: Date, status: SessionStatus, project: Bool) -> SessionPeer {
        let kind: SessionKind = c.isPinned ? .iris : (c.role != nil ? .role : .worker)
        return SessionPeer(id: c.id, name: c.sessionCard?.name, description: c.sessionCard?.description,
                           workspace: c.workspacePath, status: status,
                           lastActive: status == .busy ? now : c.updatedAt,
                           kind: kind, role: c.role, lane: c.sessionCard?.lane,
                           skills: c.role != nil ? (c.sessionCard?.skills ?? []) : [],
                           project: project ? c.workspacePath.flatMap { GitHead.read(workspace: $0) } : nil)
    }

    /// Most recently active first (#418). When the set is over the cap, live sessions (busy or
    /// waiting) are kept ahead of idle ones, so a session blocked on the user for a day is not
    /// pushed off the list by twenty tabs someone opened this morning.
    ///
    /// Returns rows with `project` unfilled (#480 review item 3): `GitHead.read` is a filesystem
    /// read — symlink-chasing, and a `gitdir:` that can point at an iCloud or network mount — and
    /// this function runs inside the caller's `MainActor.run`, alongside everything else reading
    /// `conversations`. Doing that I/O there blocks the UI actor on a read with no bound of its
    /// own. Callers fill `project` afterwards, off the MainActor, with `withProjects(_:)`.
    static func peers(in conversations: [Conversation], excluding selfId: UUID, now: Date,
                      status: (Conversation) -> SessionStatus) -> (peers: [SessionPeer], total: Int) {
        let active = activePeers(in: conversations, excluding: selfId)
        // Keyed on the conversation, not `card.updatedAt`, which would rank a session that
        // re-describes itself above one actually doing work.
        let all = active.map { c -> (Conversation, SessionPeer) in (c, peer(for: c, now: now, status: status(c), project: false)) }
        let byActivity: (SessionPeer, SessionPeer) -> Bool = {
            $0.lastActive != $1.lastActive ? $0.lastActive > $1.lastActive : $0.id.uuidString < $1.id.uuidString
        }
        let byActivityPair: ((Conversation, SessionPeer), (Conversation, SessionPeer)) -> Bool = { byActivity($0.1, $1.1) }
        // #469 §4.6 / #480 review item 7: role-holders AND the pinned Iris (at most one row) are
        // both exempt from the 20-entry cap below, so a large worker pool can never push either
        // out of view — "Iris last" (docs/sessions.md and this tool's own description) is then always
        // true, rather than true only until enough workers pile up. Workers alone keep #418's
        // live-ahead-of-idle cut.
        let roles = all.filter { $0.1.kind == .role }.sorted(by: byActivityPair)
        let iris = all.filter { $0.1.kind == .iris }
        let workers = all.filter { $0.1.kind == .worker }
        // Live-ahead-of-idle decides who SURVIVES the cut — a session blocked on the user for a
        // day must not be pushed off by twenty tabs opened this morning — but the surviving set
        // then displays by activity alone, oldest last, same as every other row: `capKeepsLiveSessions`
        // pins a blocked session kept ahead of fresher idle ones for survival, yet still LAST in
        // the rendered order, because it is the stalest thing on the list once idle rows that
        // outrank it by recency are no longer competing for the same cap slot.
        let kept = (workers.filter { $0.1.status.isLive }.sorted(by: byActivityPair)
                    + workers.filter { !$0.1.status.isLive }.sorted(by: byActivityPair)).prefix(listCap)
        let displayOrder = kept.sorted(by: byActivityPair)
        let final = (roles + displayOrder + iris).map(\.1)
        return (final, active.count)
    }

    /// Fills `project` for each row by reading ITS OWN `workspace` path (#480 review item 3) —
    /// there is no need to thread `conversations` or a separate id-to-path map through, since
    /// `SessionPeer.workspace` already carries exactly the path `peer(for:)` would otherwise read
    /// `project` from. `nonisolated`: pure file I/O with no actor affinity of its own, so callers
    /// run it off the MainActor, after the hop that produced `peers` — `list_sessions` and
    /// `describe_session` in `iris.swift` do, each only for the rows that survived the cut.
    nonisolated static func withProjects(_ peers: [SessionPeer]) -> [SessionPeer] {
        peers.map { peer in
            var peer = peer
            peer.project = peer.workspace.flatMap { GitHead.read(workspace: $0) }
            return peer
        }
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

enum SessionAddressError: Error, Equatable {
    case notFound, ambiguous(Int), inactive, isSelf, malformed

    var message: String {
        switch self {
        case .notFound: return "No active session matches that."
        case .ambiguous(let n): return "\(n) sessions share that name; use a session_id from list_sessions."
        case .inactive: return "That session is no longer active."
        case .isSelf: return "That is this session — refused."
        case .malformed: return "Address a session as a session_id, role:<name>, name:<name>, or iris."
        }
    }
}

extension SessionDirectory {
    /// #469 §5.2: resolved at delivery time, so a role that moved since the sender last listed
    /// reaches its current holder.
    static func resolve(_ to: String, in conversations: [Conversation], excluding selfId: UUID) -> Result<UUID, SessionAddressError> {
        let raw = to.trimmingCharacters(in: .whitespacesAndNewlines)
        let active = { (c: Conversation) in !c.isArchived && c.isUserFacing }
        let target: UUID
        if raw.lowercased() == "iris" {
            guard let c = conversations.first(where: { $0.isPinned && active($0) }) else { return .failure(.notFound) }
            target = c.id
        } else if raw.lowercased().hasPrefix("role:") {
            guard let role = SessionRoles.normalizedName(String(raw.dropFirst(5))) else { return .failure(.malformed) }
            guard let id = SessionRoles.holder(of: role, in: conversations) else { return .failure(.notFound) }
            target = id
        } else if raw.lowercased().hasPrefix("name:") {
            let ids = SessionRoles.sessions(named: String(raw.dropFirst(5)), in: conversations, excluding: nil)
            guard !ids.isEmpty else { return .failure(.notFound) }
            guard ids.count == 1 else { return .failure(.ambiguous(ids.count)) }
            target = ids[0]
        } else if let id = UUID(uuidString: raw) {
            guard let c = conversations.first(where: { $0.id == id }) else { return .failure(.notFound) }
            guard active(c), !c.isSubagent else { return .failure(.inactive) }
            target = id
        } else {
            return .failure(.malformed)
        }
        return target == selfId ? .failure(.isSelf) : .success(target)
    }
}
