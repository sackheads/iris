import Foundation
import CoreTransferable

/// #960: a persistent team of sessions, shown as a collapsible group in the sidebar. A group is
/// not a visual folder that empties out on its own — members never auto-archive while they
/// belong to one (`AppState.isIdleSessionCandidate`), and a group itself persists until someone
/// explicitly deletes it (which ungroups its members; it never deletes a conversation). Named and
/// ordered independently of any member, so renaming or reordering needs no member present, and
/// deleting a member never loses the group's own name.
struct SidebarGroup: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var name: String
    /// Sort order among groups, lowest first — the same ordering convention a conversation's own
    /// `position` column uses.
    var position: Int
}

/// #960: a conversation id, wrapped for sidebar drag-and-drop between the ungrouped list and a
/// team's section. A dedicated type rather than making the bare `UUID` `Transferable` so this
/// conformance can't collide with some other feature's own expectations for passing a UUID
/// through a drag session.
struct SidebarDragConversationId: Codable, Transferable, Sendable {
    let id: UUID
    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .json)
    }
}
