import Foundation

struct SlashCommandItem: Identifiable, Sendable, Equatable {
    let id: String
    let command: String
    let usage: String
    let description: String
    
    static let allCommands: [SlashCommandItem] = [
        SlashCommandItem(id: "goal", command: "/goal", usage: "/goal <description>", description: "Start an autonomous goal-driven loop"),
        SlashCommandItem(id: "stop", command: "/stop", usage: "/stop", description: "Cancel active goal mode or subagent tasks"),
        SlashCommandItem(id: "skills", command: "/skills", usage: "/skills [reload|show <name>|curate]", description: "List, reload, view, or curate registered skills"),
        SlashCommandItem(id: "bundle", command: "/bundle", usage: "/bundle [save <name> s1,s2|<name>]", description: "List, save, or activate skill bundles"),
        SlashCommandItem(id: "journey", command: "/journey", usage: "/journey", description: "View chronological learning journey timeline"),
        SlashCommandItem(id: "rules", command: "/rules", usage: "/rules [reload]", description: "View loaded system rules or force reload"),
        SlashCommandItem(id: "model", command: "/model", usage: "/model [fast|medium|heavy|<name>]", description: "View or switch active model for conversation"),
        SlashCommandItem(id: "mcp", command: "/mcp", usage: "/mcp [reload]", description: "List connected MCP tools or reload transport"),
        SlashCommandItem(id: "facts", command: "/facts", usage: "/facts [all|search <q>|probe <e>]", description: "Inspect or search SQLite FactStore memories"),
        SlashCommandItem(id: "tokens", command: "/tokens", usage: "/tokens", description: "Show token usage breakdown for active conversation"),
        SlashCommandItem(id: "new", command: "/new", usage: "/new", description: "Start a fresh conversation"),
        SlashCommandItem(id: "clear", command: "/clear", usage: "/clear", description: "Clear current conversation messages"),
        SlashCommandItem(id: "reflect", command: "/reflect", usage: "/reflect", description: "Trigger manual memory reflection and grooming"),
        SlashCommandItem(id: "vibecop", command: "/vibecop init", usage: "/vibecop init", description: "Initialize Vibecop Guardian rules for the workspace"),
        SlashCommandItem(id: "rename", command: "/rename", usage: "/rename", description: "Automatically rename current conversation"),
        SlashCommandItem(id: "update", command: "/update", usage: "/update", description: "Check for GitHub release updates"),
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
