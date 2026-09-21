import Foundation

/// #187 — which conversations the sidebar shows, and in what order. Pure and free of SwiftUI so
/// the rule is testable without a view: the sidebar's two `ForEach` sources are the only callers.
///
/// Order within each result is the caller's array order (`state.conversations`, loaded
/// `ORDER BY position`), except that pinned conversations are lifted to the front as a stable
/// partition — pinned in their original relative order, then everything else in theirs.
enum SidebarOrdering {
    /// The main list: neither a subagent scratch thread, nor a background job run, nor archived.
    static func visible(_ all: [Conversation]) -> [Conversation] {
        let shown = all.filter { !$0.isSubagent && !$0.isBackground && !$0.isArchived }
        return shown.filter(\.isPinned) + shown.filter { !$0.isPinned }
    }

    /// The collapsed "Archived" section (#182), with the same subagent/background exclusions.
    static func archived(_ all: [Conversation]) -> [Conversation] {
        all.filter { !$0.isSubagent && !$0.isBackground && $0.isArchived }
    }
}
