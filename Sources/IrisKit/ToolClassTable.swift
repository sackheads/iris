import Foundation

/// #974 gap A (#1015): what a tool is, for a turn that does not run as the owner. One table, one gate,
/// replacing the hand-maintained #1195/#1199 denylist: `ToolClassTableTests` fails when a declared tool
/// has no row, so a new tool is classified before it can ship.
enum ToolClass: Equatable, Sendable {
    /// Already asks the person on a turn a guest steered (the approval ladder); the table leaves it to that.
    case approvalGated
    /// The owner's data or authority with no approval step: refused on any non-owner binding.
    case ownerOnly
    /// A memory tool: `MemoryBindingGate` decides by the binding's memory tier, which is what lets a
    /// profile-bound session with the tier still read its own facts.
    case tierGated
    /// Pure or local: reads or writes nothing of the owner's, acts as no account.
    case noCred
}

enum ToolClassTable {
    /// Every declared tool (`IrisEngine.allDeclaredToolNames` plus the GitHub proxy tools).
    static let classes: [String: ToolClass] = {
        var table: [String: ToolClass] = [:]
        func put(_ names: some Sequence<String>, _ toolClass: ToolClass) { for name in names { table[name] = toolClass } }
        put(["run_command", "read_file", "write_file"], .approvalGated)
        put(ToolExecutor.googleWorkspaceTools, .ownerOnly)
        put(ToolExecutor.githubProxyTools, .ownerOnly)      // act as Iris's own GitHub account, no approval step
        put(ToolExecutor.ownerJobReadTools, .ownerOnly)
        // The roster, standing jobs, and the one tool that re-points which AGENTS.md reaches the prompt.
        // `set_alarm` schedules a future turn that runs without the guest stamp, carrying the guest's note (#1294's shape, dev-2's review of #1307).
        put(["list_sessions", "describe_session", "schedule_job", "register_directory_watcher", "set_workspace", IrisEngine.setAlarmTool], .ownerOnly)
        put(ToolExecutor.memoryTools, .tierGated)
        put(["search_conversations", "read_conversation", IrisEngine.profileMemoryTool], .tierGated)
        put(["search_web", "rename_conversation", "reflect", "goal_complete", "propose_goal_contract",
             "amend_goal_contract", "reach_checkpoint", "waive_criterion", "invoke_subagent", "delegate_milestone",
             "inbox_item", "submit_evaluation", "set_session_card", "close_request", "send_to_session",
             IrisEngine.scheduleNextTickTool, IrisEngine.currentTimeTool], .noCred)
        return table
    }()

    /// The names refused on a non-owner binding: what `hardStrip` and the dispatcher read.
    static let ownerOnlyNames: Set<String> = Set(classes.filter { $0.value == .ownerOnly }.keys)

    /// A name with no row is a tool this repo does not declare: an MCP server's or a plugin's, which
    /// carry the owner's credentials and have no approval step. Closed by default.
    static func toolClass(of name: String) -> ToolClass { classes[name] ?? .ownerOnly }

    /// Whether `name` is refused on a binding that is not the owner's.
    static func isOwnerOnly(_ name: String) -> Bool { toolClass(of: name) == .ownerOnly }

    /// How a refusal opens. The tool and its class come first: the ledger keeps the first 200 characters of an
    /// outcome, and whoever hits an over-block needs to read which tool and which class closed it (#1309).
    static func refusalLead(tool: String) -> String { "Not run: `\(tool)` is owner-only in the tool class table" }

    /// `profileId` is the conversation's persisted profile id, named only for a session bound to one: a guest-steered
    /// turn's refusal goes back to the guest, so it says "guest-steered" and never a profile id.
    static func refusal(tool: String, binding: AccessBinding, profileId: String? = nil) -> String? {
        guard !binding.isOwner, isOwnerOnly(tool) else { return nil }
        let origin: String
        if binding.principal == .mcpGuest {
            origin = "guest-steered"
        } else if let profileId {
            origin = "bound to profile `\(profileId)`"
        } else {
            origin = "bound to a non-owner profile"
        }
        return refusalLead(tool: tool) + ", and this turn is \(origin), not the owner's. Owner-only tools act as the user "
            + "(their Google and GitHub accounts, jobs, sessions, workspace, added MCP and plugin tools) with no approval step."
    }
}
