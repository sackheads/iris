import Foundation

/// #974 Task 7 (C4): the memory tools consult the active `AccessBinding`'s memory axes, at the point
/// the data is read or written. Declaration gating only stops a well-behaved model; a forged or
/// stale call, a guest-steered turn and a subagent all reach the same handlers, so the tier is
/// checked there.
///
/// Reads: shared facts need `memoryRead >= .shared`; other conversations need `>= .conversations`
/// (and the existing pinned-conversation rule still applies on top). Writes: each writer needs its
/// store's tier on `memoryWrite`. An owner binding (`isOwner`, or the `.owner` profile) is never
/// refused; a binding below the tier is refused, never narrowed to "the part it may see" silently.
/// Redirecting a below-tier writer to its own namespace is Task 11's mechanism, not this one.
enum MemoryBindingGate {
    /// Each writer and the `memoryWrite` tier its store needs. Complete over
    /// `ToolExecutor.memoryWriteTools` (a test pins that, so a new writer is decided on purpose).
    static let writerTiers: [String: MemoryTier] = [
        // The owner's identity and durable stores, and executable skills.
        "update_soul": .full, "update_user_profile": .full, "update_memory": .full,
        "create_skill": .full, "update_skill": .full, "delete_skill": .full,
        // The shared fact tier.
        "save_fact": .shared, "manage_fact": .shared,
    ]

    static let factsReadTier: MemoryTier = .shared
    static let conversationsReadTier: MemoryTier = .conversations

    /// What a refused call is told. Fixed text: no store content, no tier names.
    static let refusal = "Refused — this session's access profile does not allow that memory access."

    static func mayReadFacts(_ binding: AccessBinding) -> Bool {
        binding.isOwner || binding.profile.memoryRead >= factsReadTier
    }

    static func mayReadConversations(_ binding: AccessBinding) -> Bool {
        binding.isOwner || binding.profile.memoryRead >= conversationsReadTier
    }

    /// nil when the call may run, `refusal` when it may not. A writer with no table row is refused
    /// for a non-owner binding (fail closed on a name nobody decided); every other tool is not this
    /// gate's business.
    static func writeRefusal(tool: String, binding: AccessBinding) -> String? {
        guard ToolExecutor.memoryWriteTools.contains(tool) else { return nil }
        if binding.isOwner { return nil }
        guard let required = writerTiers[tool], binding.profile.memoryWrite >= required else { return refusal }
        return nil
    }
}
