import Foundation

/// #1425 slice A1 (Brian, 11-27, forks 1-6 and 8 as designed): a loop marked unattended never stops on an approval
/// dialog. Every turn in its conversation that the person didn't type (a tick, an alarm, a peer's message, an event)
/// runs with this mark set (`IrisEngine.processInput`), and the approval ladder then decides without asking anyone
/// (`AppState.requestApprovalSource`): no YOLO, the person's rules with Always-allow prefixes only while the
/// conversation hasn't read outside text, and Vibecop's read-only approve. A call that would need a person isn't run;
/// it's recorded once per call and noted in the transcript, and the model is told not to retry it or route around it.
/// Slice A2 turns that record into an Inbox item whose answer runs the call.
enum UnattendedLoop {
    /// Set for the whole of an unattended loop's non-typed turn, its parallel tool calls included.
    @TaskLocal static var turn = false

    /// What such a turn is never offered, as a job run isn't (`IrisEngine.unattendedNeverDeclared`), but keeping the
    /// session and inbox tools a fleet needs to talk.
    static let strippedTools: Set<String> = IrisEngine.jobCreationTools.union(["set_workspace"]).union(ToolExecutor.githubProxyTools)

    static let turnedOnNotice = "This loop is now unattended: its ticks, and any turn you didn't type here, never stop on an approval dialog. A call that would need you isn't run, and is noted here instead. Your own messages here still ask as usual. `/loop unattended off` turns it back."
    static let turnedOffNotice = "This loop is attended again: its ticks ask you for approvals as usual."

    /// What the model is told for a call it may not make on such a turn.
    static func deniedToolResult(tool: String) -> String {
        "Not run: this loop runs unattended, and `\(tool)` needs the user's approval. They will see this call noted in the conversation. "
            + "Don't retry it, and don't try to reach the same result another way (another tool, a different command). "
            + "Carry on with whatever doesn't need it, then end the tick saying what was left undone."
    }

    /// The transcript line for a call that wasn't run, once per call (`AppState.recordUnattendedLoopDenial`).
    static func notice(tool: String, details: String) -> String {
        let shown = String(details.replacingOccurrences(of: "\n", with: " ").prefix(160))
        return "Not run (unattended loop): `\(tool)` \(shown) needs your approval. Run it yourself, add a rule for it, or `/loop unattended off`."
    }
}
