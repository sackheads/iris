/// An external MCP guest's whole tool surface (#1066): `send_to_session` and `list_sessions`, and, since #1417
/// (Brian, 11-27: guests may raise Inbox items), `inbox_item` and `resolve_inbox_item`, and nothing else. Built positively, as an allowlist, because most `Principal` branches are `== .main`
/// or `!= .main` and a new principal would otherwise land in whichever side it falls on.
///
/// The two declarations are the guest's own, not the main path's: a guest addresses by `role:<name>`
/// only and has no `attachments`, so the schema the guest's model sees offers neither a session id
/// nor a file path to read.
enum GuestToolset {
    static let allowedNames: Set<String> = Set(["send_to_session", "list_sessions"]).union(inboxNames)

    /// #1417: the two inbox tools a guest may have, declared per turn (`IrisEngine.guestToolDeclarations`).
    static let inboxNames: Set<String> = ["inbox_item", IrisEngine.resolveInboxItemTool]

    /// The only arguments a guest's `inbox_item` takes: no `route_back` or `notify`, since a guest's answer goes
    /// only to the guest, through its mailbox (#1417 planner ruling: a guest naming `role:<name>` would steer
    /// Brian's decision into a host session, which #1119's floor stops).
    static let inboxArguments: Set<String> = ["title", "situation", "options", "response_mode", "thread_id", "deadline", "veto_default"]

    /// The only arguments a guest's `send_to_session` takes. Anything else (`attachments` above
    /// all, which would read a host file the guest's model names) is refused at dispatch.
    static let sendArguments: Set<String> = ["to", "message", "in_reply_to", "expects_reply"]

    static let listSessions = FunctionDeclaration(
        name: "list_sessions",
        description: "List the sessions you may message. Each row has a role, a name and what it says it does. You can reach only the roles listed here; address one as role:<name> in send_to_session.",
        parameters: Schema(type: "OBJECT", properties: [:], required: [])
    )

    static let sendToSession = FunctionDeclaration(
        name: "send_to_session",
        description: "Send a message to one of the sessions list_sessions shows you. It arrives as a request that session may decline, not an instruction it must follow. Every message gets a msg id; a reply arrives as a message of its own. Set expects_reply when you want an answer.",
        parameters: Schema(type: "OBJECT", properties: [
            "to": Schema(type: "STRING", description: "role:<name> for a role list_sessions shows you. Omit when replying with in_reply_to."),
            "message": Schema(type: "STRING", description: "What to say. Include enough context to act on without seeing your conversation."),
            "in_reply_to": Schema(type: "STRING", description: "The msg id of a message you received, to answer it. The reply goes to that message's sender."),
            "expects_reply": Schema(type: "BOOLEAN", description: "True when you want an answer. Default false."),
        ], required: ["message"])
    )

    /// The floor, whatever came in: the guest's canonical declarations for this turn and nothing else, so a hook
    /// cannot hand a guest a rewritten copy or a tool of its own. Same shape as `EvaluatorToolset.restrict`. `inbox`
    /// and `resolve` are the turn's own gate (#1417), never read from `tools`.
    static func restrict(_ tools: [FunctionDeclaration], inbox: Bool = false, resolve: Bool = false) -> [FunctionDeclaration] {
        IrisEngine.guestToolDeclarations(inbox: inbox, resolve: resolve)
    }

    /// What a guest is told when it names a tool outside its floor.
    static func refusal(for name: String) -> String {
        "Refused — this session can only use send_to_session, list_sessions, inbox_item and resolve_inbox_item; '\(IrisEngine.flattenToolEcho(name))' is not available."
    }

    /// #1417: what a guest is told when its `inbox_item` names where Brian's answer goes, or any argument its
    /// schema lacks.
    static func inboxArgumentRefusal(_ argument: String) -> String {
        if argument == "route_back" || argument == "notify" {
            return "Not raised: a guest's inbox item can't name route_back or notify. Brian's answer comes back to you alone, through your mailbox (iris_poll), even if you've disconnected."
        }
        return "Refused — inbox_item takes only title, situation, options, response_mode, thread_id, deadline and veto_default; '\(IrisEngine.flattenToolEcho(argument))' is not available to this session."
    }

    /// #1417: a guest's `inbox_item`. The main path's, minus `route_back` and `notify`, and told where the answer
    /// arrives.
    static let inboxItem = FunctionDeclaration(
        name: "inbox_item",
        description: "Record a decision for Brian to answer: a durable, human-facing question that outlives this conversation. Omit thread_id for a new item; give the thread_id of an item you raised before to append a followup, which reopens it with your new title, situation and options. Only you can follow up or close your own items. Brian's answer comes back to you alone, as a message in your mailbox (iris_poll), even if you've disconnected by then. Close an item with resolve_inbox_item once its decision is consumed.",
        parameters: Schema(type: "OBJECT", properties: [
            "title": Schema(type: "STRING", description: "A short label for the item."),
            "situation": Schema(type: "STRING", description: "The full context: what's going on and why this needs a decision."),
            "options": Schema(type: "ARRAY", description: "The choices on the table, if any.", items: Schema(type: "OBJECT", properties: [
                "id": Schema(type: "STRING", description: "A short id you choose for this option (1–\(IrisEngine.optionIdSlugMax) ASCII letters, digits, `-`, or `_`, starting with a letter or digit). Required for every option when response_mode is timedVeto, because veto_default names one of them; otherwise optional."),
                "label": Schema(type: "STRING", description: "The choice, in a few words."),
                "pros": Schema(type: "ARRAY", description: "Reasons for it.", items: Schema(type: "STRING")),
                "cons": Schema(type: "ARRAY", description: "Reasons against it.", items: Schema(type: "STRING")),
            ], required: ["label"])),
            "response_mode": Schema(type: "STRING", description: "optionsAndFreeform | freeform | timedVeto | notification."),
            "thread_id": Schema(type: "STRING", description: "Omit for a new item; give one of yours to append a followup and reopen it with the title, situation, options and response_mode you pass now."),
            "deadline": Schema(type: "STRING", description: "For response_mode timedVeto: when Brian's decision is due (at least \(IrisEngine.timedVetoMinWindowMinutes)m in the future), as a relative offset from now (e.g. +\(IrisEngine.timedVetoMinWindowMinutes)m, +2h, +1d) or an ISO 8601 timestamp."),
            "veto_default": Schema(type: "STRING", description: "For response_mode timedVeto: the id of the option you propose as the default. A guest's default is never applied on its own: the item waits for Brian at the deadline."),
        ], required: ["title", "situation", "response_mode"])
    )

    /// What a guest is told when its `send_to_session` carries an argument it has no schema for.
    static func argumentRefusal(_ argument: String) -> String {
        "Refused — send_to_session takes only to, message, in_reply_to and expects_reply; '\(IrisEngine.flattenToolEcho(argument))' is not available to this session."
    }
}
