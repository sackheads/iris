import Foundation

/// Which visible conversations are waiting on the person, and on what (#466): the sidebar's
/// "needs you" mark. Pure, so the rules are testable without an app, and computed from the same
/// inputs as `SurfaceAttention` (the status item), so the two never count differently.
///
/// What counts (planner ruling on #466): a pending tool approval, a goal contract to review, a
/// checkpoint review, a goal judgement, and a job run blocked on approval that nobody has
/// acknowledged. Not a failed run (news, not a request), not a peer's request (agent to agent),
/// not a question at the end of a turn (nothing structured marks one yet: #592).
enum NeedsHuman {
    struct Ask: Equatable {
        /// The visible conversation the ask is charged to (`delegationRoot`), nil when unattributed.
        let root: UUID?
        let toolName: String
    }

    /// The phrase for a goal contract's wait on the person, or nil. Shared with `sessionStatus`.
    static func goalWait(_ contract: GoalContract?) -> String? {
        guard let contract else { return nil }
        if contract.state == .draft { return "goal contract to review" }
        if contract.checkpointStatus == .pausedForReview { return "checkpoint review" }
        if contract.awaitingHumanJudgement { return "goal judgement" }
        return nil
    }

    /// Each visible conversation that needs the person, with the reason its mark names. Earlier
    /// kinds win a conversation's reason: an approval, then a goal wait, then a blocked run.
    ///
    /// A blocked run is shown on its card's conversation: the job's destination if that is still
    /// a live, unarchived conversation, else the pinned Iris conversation, `pinnedId`. With
    /// neither, it shows in the status menu only, and no row is marked.
    static func derive(asks: [Ask], conversations: [Conversation], blocked: [LedgerAttention.Blocked],
                       pinnedId: UUID?) -> [UUID: String] {
        var out: [UUID: String] = [:]
        let visible = Dictionary(conversations.filter { $0.isUserFacing && !$0.isArchived }.map { ($0.id, $0) },
                                 uniquingKeysWith: { first, _ in first })
        for ask in asks {
            guard let root = ask.root, visible[root] != nil, out[root] == nil else { continue }
            out[root] = "approval: " + IrisEngine.flattenCardField(ask.toolName, cap: IrisEngine.cardNameCap)
        }
        for (id, conversation) in visible where out[id] == nil {
            if let wait = goalWait(conversation.goalContract) { out[id] = wait }
        }
        for run in blocked {
            let home = run.destinationConversationId.flatMap { visible[$0] != nil ? $0 : nil } ?? pinnedId
            guard let home, visible[home] != nil, out[home] == nil else { continue }
            let job = IrisEngine.flattenCardField(run.jobName, cap: IrisEngine.cardNameCap)
            out[home] = run.refusedByProfile ? "refused by profile: \(job)" : "blocked run: \(job)"
        }
        return out
    }
}
