/// An external MCP guest's whole tool surface (#1066): `send_to_session` and `list_sessions`, and
/// nothing else. Built positively, as an allowlist, because most `Principal` branches are `== .main`
/// or `!= .main` and a new principal would otherwise land in whichever side it falls on.
///
/// The two declarations are the guest's own, not the main path's: a guest addresses by `role:<name>`
/// only and has no `attachments`, so the schema the guest's model sees offers neither a session id
/// nor a file path to read.
enum GuestToolset {
    static let allowedNames: Set<String> = ["send_to_session", "list_sessions"]

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

    /// The floor, whatever came in: the guest's canonical declarations and nothing else, so a hook
    /// cannot hand a guest a rewritten copy or a tool of its own. Same shape as
    /// `EvaluatorToolset.restrict`.
    static func restrict(_ tools: [FunctionDeclaration]) -> [FunctionDeclaration] {
        IrisEngine.guestToolDeclarations()
    }

    /// What a guest is told when it names a tool outside its floor.
    static func refusal(for name: String) -> String {
        "Refused — this session can only use send_to_session and list_sessions; '\(IrisEngine.flattenToolEcho(name))' is not available."
    }

    /// What a guest is told when its `send_to_session` carries an argument it has no schema for.
    static func argumentRefusal(_ argument: String) -> String {
        "Refused — send_to_session takes only to, message, in_reply_to and expects_reply; '\(IrisEngine.flattenToolEcho(argument))' is not available to this session."
    }
}
