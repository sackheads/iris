import Foundation

/// #187 — which conversations the sidebar shows, and in what order. Pure and free of SwiftUI so
/// the rule is testable without a view: the sidebar's two `ForEach` sources are the only callers.
///
/// Order within each result is the caller's array order (`state.conversations`, loaded
/// `ORDER BY position`), except that pinned conversations are lifted to the front as a stable
/// partition — pinned in their original relative order, then everything else in theirs.
enum SidebarOrdering {
    /// The main list: neither a subagent scratch thread, nor a background job run, nor archived —
    /// `Conversation.isSelectable`, the same predicate the launch/delete/archive selection sites
    /// use, so the sidebar and the selection can never disagree about what exists.
    static func visible(_ all: [Conversation]) -> [Conversation] {
        let shown = all.filter(\.isSelectable)
        return shown.filter(\.isPinned) + shown.filter { !$0.isPinned }
    }

    /// The collapsed "Archived" section (#182), with the same subagent/background exclusions.
    static func archived(_ all: [Conversation]) -> [Conversation] {
        all.filter { $0.isUserFacing && $0.isArchived }
    }

    /// #960: the flat, unpinned, ungrouped part of the main list — what `visible`'s non-pinned
    /// half used to show in full, now narrowed to the conversations that belong to no team.
    static func ungrouped(_ all: [Conversation]) -> [Conversation] {
        visible(all).filter { !$0.isPinned && $0.sidebarGroupId == nil }
    }

    /// #960: one entry per persistent team, lowest `position` first, each with its own members in
    /// `all`'s array order (which `reorderConversations` keeps consistent with the stored
    /// `position` column). An empty group is still returned — a team with no members right now is
    /// not the same as a team that doesn't exist (#960: persists until explicitly deleted).
    static func teams(_ all: [Conversation], groups: [SidebarGroup]) -> [(group: SidebarGroup, members: [Conversation])] {
        let shown = visible(all)
        return groups.sorted { $0.position < $1.position }.map { group in
            (group, shown.filter { $0.sidebarGroupId == group.id })
        }
    }
}
