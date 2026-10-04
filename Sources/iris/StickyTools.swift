import Foundation

/// 5c §0.1: a state-gated tool, once declared in a conversation, stays declared for the rest of
/// that conversation's turns. A declaration that flaps rewrites every provider's cached prefix
/// after the tools block; a few extra declarations cost far less. In memory only: a restart
/// re-derives the set from the gates at the cost of one rewrite.
struct StickyTools: Sendable {
    /// The state-gated tools. Not the workflow triggers (one turn only, #132), not the pinned-only
    /// job tools (identity, not state), not `set_workspace` (its gate is fixed per conversation).
    static let eligible: Set<String> = [
        "manage_fact", "list_sessions", "send_to_session", "set_session_card",
        "amend_goal_contract", "reach_checkpoint", "delegate_milestone", "waive_criterion",
        "goal_complete",
    ]

    private var byConversation: [UUID: Set<String>] = [:]

    func names(for id: UUID) -> Set<String> { byConversation[id] ?? [] }

    mutating func record(_ declared: some Sequence<String>, for id: UUID) {
        let added = Set(declared).intersection(Self.eligible)
        guard !added.isEmpty else { return }
        byConversation[id, default: []].formUnion(added)
    }

    /// On delete only. An archived conversation can be restored, and its prefix should still match.
    mutating func forget(_ id: UUID) { byConversation[id] = nil }
}
