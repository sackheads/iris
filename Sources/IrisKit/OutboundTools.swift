import Foundation

/// #812: the tools that send or change something outside the machine (mail, calendar, tasks, and
/// any MCP tool its server didn't mark read-only), and since #825 `search_web`, whose query goes
/// to a search provider. Once a conversation has read untrusted output
/// (`Conversation.hasUntrustedToolOutput`), a call to one asks the person when attended and is
/// refused when unattended, unless the person exempted it: for the conversation from the approval
/// card, or for a job when they approved creating it (or later with `/jobs exempt`).
enum OutboundTools {
    /// The built-in outbound tools. The Google tools that only read are not here.
    static let builtIn: Set<String> = ["gmail_send_email", "google_calendar_create_event", "google_tasks_create_task", searchWeb]

    /// `search_web` is outbound for its query, not for what it changes: it can run in a read-only
    /// job, so such a job may carry its exemption (#825).
    static let searchWeb = "search_web"

    /// What the tool does outside the Mac, as a clause the refusal and the card complete.
    private static func channel(_ name: String) -> String {
        name == searchWeb ? "sends a query you wrote to a search provider" : "sends or changes something outside this Mac"
    }

    /// Whether `name` is outbound. An MCP tool is, unless its server marked it `readOnlyHint: true`:
    /// Iris trusts that marking, since a server that lies about its own tools can already do
    /// anything with its own code, and a tool with no marking counts as outbound.
    static func isOutbound(_ name: String, readOnlyMCPTools: Set<String>) -> Bool {
        if builtIn.contains(name) { return true }
        return JobProfile.isMCPTool(name) && !readOnlyMCPTools.contains(name)
    }

    /// The sentence the job-creation card and `/jobs exempt` show for an exemption, one per kind
    /// of tool, so the person approves it knowing what it lets the job do.
    static func exemptionSentence(_ name: String) -> String {
        let action: String
        switch name {
        case "gmail_send_email": action = "send email to anyone"
        case "google_calendar_create_event": action = "create calendar events"
        case "google_tasks_create_task": action = "create tasks"
        case searchWeb: action = "search the web, with queries it writes"
        default: action = "call `\(shownName(name))`, which can send or change something outside this Mac,"
        }
        return "This job may \(action) without asking, even after reading untrusted content."
    }

    /// A tool name as text the model or the person reads: as is when it is a plain identifier (every
    /// built-in, and an MCP name of the usual shape), else flattened like any echoed name.
    static func shownName(_ name: String) -> String {
        let plain = !name.isEmpty && name.count <= 128 && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "_-.".contains($0)) }
        return plain ? name : IrisEngine.flattenToolEcho(name)
    }

    static func fullText(_ value: JSONValue) -> String {
        if case .string(let s) = value { return s }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? value.stringValue
    }

    /// The job tools' argument that proposes exemptions. A proposal only: it takes effect through
    /// the creation approval card, which always asks when it is given and states each one.
    static let exemptionsArgument = "outbound_exemptions"

    static let exemptionsParameterDescription = "Mutating jobs only. Outbound tools this job's runs may call without asking even after reading untrusted content (gmail_send_email, google_calendar_create_event, google_tasks_create_task, search_web, or an MCP tool by its full name). Give only what the task needs: the user is shown each one, e.g. that the job may send email to anyone, and the job is created only if they approve. Without one, such a call is refused once the run has read untrusted content."

    static let exemptionsShape: ToolMessage = "outbound_exemptions must be a list of tool names, e.g. [\"gmail_send_email\"]."

    /// The proposed exemptions, deduplicated and sorted; empty when none were given.
    static func proposedExemptions(_ args: [String: JSONValue]) -> Result<[String], ToolMessage> {
        switch ScheduleJobArguments.stringList(args[exemptionsArgument], shape: exemptionsShape) {
        case .failure(let message): return .failure(message)
        case .success(let names): return .success(Array(Set(names ?? [])).sorted())
        }
    }

    /// Why these exemptions can't be granted, or nil. A read-only job sends nothing, so an
    /// exemption there is refused rather than stored: it would suggest the job can send. A tool that
    /// isn't outbound is refused too: exempting it would suggest protection that isn't there.
    static func exemptionRefusal(_ names: [String], profile: JobProfile, readOnlyMCPTools: Set<String>) -> ToolMessage? {
        guard !names.isEmpty else { return nil }
        if profile == .readOnly, names.contains(where: { $0 != searchWeb }) {
            return "Not created: a read-only job can't send or change anything outside this Mac, so it can't carry outbound_exemptions. Ask for a mutating job, or leave them out."
        }
        if let bad = names.first(where: { !isOutbound($0, readOnlyMCPTools: readOnlyMCPTools) }) {
            return ToolMessage("Not created: `\(shownName(bad))` isn't an outbound tool, so it can't be exempted. Exemptions are for: \(builtIn.sorted().joined(separator: ", ")), and MCP tools their server didn't mark read-only.")
        }
        return nil
    }

    /// The exemption lines for a job's card or its `/jobs` summary, in a stable order.
    static func exemptionLines(_ names: [String]) -> [String] {
        names.sorted().map(exemptionSentence)
    }

    /// What an unattended run is told when an outbound call is refused (the planner's rule 4): which
    /// tool, why, and where the person can exempt it. Like `unattendedDeniedToolResult`, it forbids
    /// reaching the same target another way.
    static func unattendedRefusal(tool: String) -> String {
        let shown = shownName(tool)
        return "Not run: `\(shown)` \(channel(tool)), and this run has read untrusted content, so it needs a person's approval and nobody is here to give it. The person can exempt this job with `/jobs exempt <job> \(shown)`. Do not ask a question, and do not try to reach the same target another way. Finish the rest of the task if you can, then report what you did and what was refused."
    }

    /// The approval card's text for an outbound ask on a tainted conversation: every argument in
    /// full, since a body cut short or a list shown as "[...]" hides exactly what would leave
    /// (the card scrolls). A string as it is; anything else as JSON.
    static func approvalDetails(tool: String, args: [String: JSONValue]) -> String {
        let argLines = args.keys.sorted().map { key in "\(key): \(fullText(args[key] ?? .null))" }
        return (["This conversation has read untrusted content, and this call \(channel(tool))."] + argLines)
            .joined(separator: "\n")
    }
}
