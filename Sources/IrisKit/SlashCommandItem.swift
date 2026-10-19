import Foundation

struct SlashCommandItem: Identifiable, Sendable, Equatable {
    let id: String
    let command: String
    let usage: String
    let description: String
    
    static let allCommands: [SlashCommandItem] = [
        SlashCommandItem(id: "goal", command: "/goal", usage: "/goal <description>", description: "Start an autonomous goal-driven loop"),
        SlashCommandItem(id: "loop", command: "/loop", usage: "/loop <interval> <prompt>", description: "Re-run a prompt in this conversation every interval (stop, pause, resume)"),
        SlashCommandItem(id: "stop", command: "/stop", usage: "/stop", description: "Cancel active goal mode or subagent tasks"),
        SlashCommandItem(id: "skills", command: "/skills", usage: "/skills [reload|show <name>|curate]", description: "List, reload, view, or curate registered skills"),
        SlashCommandItem(id: "bundle", command: "/bundle", usage: "/bundle [save <name> s1,s2|<name>]", description: "List, save, or activate skill bundles"),
        SlashCommandItem(id: "jobs", command: "/jobs", usage: "/jobs [ack <run id>|pause|resume|enable|disable|run|delete <name>|reschedule <name> <cron> [timezone]|url <name> [on|off]]", description: "List background jobs, acknowledge a failed run, pause, resume, enable, disable, run, reschedule, or delete a job, or turn a job's link on or off"),
        SlashCommandItem(id: "journey", command: "/journey", usage: "/journey", description: "View chronological learning journey timeline"),
        SlashCommandItem(id: "rules", command: "/rules", usage: "/rules [reload]", description: "View loaded system rules or force reload"),
        SlashCommandItem(id: "model", command: "/model", usage: "/model [easy|medium|hard|default]", description: "Show or set this conversation's model tier"),
        SlashCommandItem(id: "mcp", command: "/mcp", usage: "/mcp [reload]", description: "List connected MCP tools or reload transport"),
        SlashCommandItem(id: "facts", command: "/facts", usage: "/facts [all|search <q>|probe <e>]", description: "Inspect or search SQLite FactStore memories"),
        SlashCommandItem(id: "search", command: "/search", usage: "/search <query>", description: "Full-text search across saved conversations"),
        SlashCommandItem(id: "tokens", command: "/tokens", usage: "/tokens", description: "Show token usage breakdown for active conversation"),
        SlashCommandItem(id: "new", command: "/new", usage: "/new", description: "Start a fresh conversation; in Iris, summarize and archive it"),
        SlashCommandItem(id: "clear", command: "/clear", usage: "/clear", description: "Clear current conversation messages"),
        SlashCommandItem(id: "archive", command: "/archive", usage: "/archive", description: "Move this conversation to the archive"),
        SlashCommandItem(id: "unarchive", command: "/unarchive", usage: "/unarchive", description: "Return this conversation to the active list"),
        SlashCommandItem(id: "role", command: "/role", usage: "/role [<name>|clear]", description: "Show, assign or release this session's role"),
        SlashCommandItem(id: "reflect", command: "/reflect", usage: "/reflect", description: "Trigger manual memory reflection and grooming"),
        SlashCommandItem(id: "vibecop", command: "/vibecop init", usage: "/vibecop init", description: "Initialize Vibecop Guardian rules for the workspace"),
        SlashCommandItem(id: "rename", command: "/rename", usage: "/rename", description: "Automatically rename current conversation"),
        SlashCommandItem(id: "update", command: "/update", usage: "/update", description: "Check for a new version of Iris"),
        SlashCommandItem(id: "sandbox", command: "/sandbox", usage: "/sandbox", description: "Check or configure subagent VM container runtime")
    ]
    
    /// Returns matching slash commands for `input`.
    static func matches(for input: String) -> [SlashCommandItem] {
        guard let slashIndex = input.firstIndex(of: "/"), input[..<slashIndex].allSatisfy(\.isWhitespace) else {
            return []
        }
        let commandPart = String(input[slashIndex...])
        guard !commandPart.contains(" ") else { return [] }
        if commandPart == "/" {
            return allCommands
        }
        let query = commandPart.lowercased()
        return allCommands.filter { $0.command.lowercased().hasPrefix(query) }
    }
}
