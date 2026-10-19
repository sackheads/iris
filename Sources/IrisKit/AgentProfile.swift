import CryptoKit
import Foundation

/// An agent profile (#465): a named starting point for a conversation, read from
/// `config/agent-profiles/<name>.md`. The Markdown body is a system-prompt addition; the
/// frontmatter names a role, a tier, skills and tools. A profile only ever narrows or adds
/// prompt text: it approves, allowlists and grants nothing.
struct AgentProfile: Equatable, Sendable {
    var name: String
    var role: String?
    var tier: ModelTier?
    /// nil means the usual skills or tools; a list narrows to those names.
    var skills: [String]?
    var tools: [String]?
    /// The body: the system-prompt addition.
    var prompt: String
    /// SHA-256 of the file's bytes, so an edit made within the same second still counts.
    var contentHash: String

    /// Tools a profile never narrows (#465, Fork B): each is already offered only on its own
    /// trigger or in its own state (Invariant 6), so narrowing it would break `/goal` or `/rename`
    /// in a profiled chat and save no tokens. `send_to_session` is not one of them.
    static let flowTools: Set<String> = [
        "goal_complete", "propose_goal_contract", "rename_conversation", "reach_checkpoint",
        "amend_goal_contract", "waive_criterion", "delegate_milestone",
    ]

    /// Whether this profile offers `tool`. No `tools:` list offers everything; a list offers its
    /// names, every tool of a server it names as `mcp:<server>`, and the flow tools.
    func allowsTool(_ tool: String) -> Bool {
        guard let tools else { return true }
        if Self.flowTools.contains(tool) || tools.contains(tool) { return true }
        guard JobProfile.isMCPTool(tool),
              let server = tool.components(separatedBy: JobProfile.mcpNameSeparator).first else { return false }
        return tools.contains("mcp:" + server)
    }

    var snapshot: AgentProfileSnapshot {
        AgentProfileSnapshot(name: name, role: role, tier: tier?.rawValue, skills: skills, tools: tools,
                             prompt: prompt, contentHash: contentHash)
    }
}

/// The last version of a conversation's profile that read cleanly, kept on the conversation as
/// the fallback while its file is missing or broken (#465): a narrowed chat never widens silently.
/// The file wins whenever it reads.
struct AgentProfileSnapshot: Codable, Equatable, Sendable {
    var name: String
    var role: String?
    var tier: String?
    var skills: [String]?
    var tools: [String]?
    var prompt: String
    var contentHash: String

    init(name: String, role: String?, tier: String?, skills: [String]?, tools: [String]?,
         prompt: String, contentHash: String) {
        self.name = name; self.role = role; self.tier = tier; self.skills = skills
        self.tools = tools; self.prompt = prompt; self.contentHash = contentHash
    }

    // Invariant 1: every field past the name and prompt may be absent in a later format.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        role = try c.decodeIfPresent(String.self, forKey: .role)
        tier = try c.decodeIfPresent(String.self, forKey: .tier)
        skills = try c.decodeIfPresent([String].self, forKey: .skills)
        tools = try c.decodeIfPresent([String].self, forKey: .tools)
        prompt = try c.decode(String.self, forKey: .prompt)
        contentHash = try c.decodeIfPresent(String.self, forKey: .contentHash) ?? ""
    }

    var profile: AgentProfile {
        AgentProfile(name: name, role: role, tier: tier.flatMap(ModelTier.init(rawValue:)), skills: skills,
                     tools: tools, prompt: prompt, contentHash: contentHash)
    }
}

/// Reads agent profiles from `config/agent-profiles/`, a protected directory: the agent's
/// `write_file` there always asks the person, and no background run can write it.
struct AgentProfileStore: Sendable {
    let paths: IrisPaths

    init(paths: IrisPaths = .default) { self.paths = paths }

    var directory: URL { paths.configDir.appendingPathComponent("agent-profiles") }

    enum Load: Equatable {
        case loaded(AgentProfile)
        case missing
        /// The file is there but does not parse: why, for the notice.
        case unreadable(String)
    }

    /// A name a profile file may have: what session roles allow, so a profile's name can be its role.
    static func isValidName(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 32 && name.unicodeScalars.allSatisfy {
            ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-"
        }
    }

    func load(_ name: String) -> Load {
        guard Self.isValidName(name) else { return .unreadable("\(name) is not a profile name") }
        let url = directory.appendingPathComponent(name + ".md")
        guard let data = FileManager.default.contents(atPath: url.path) else {
            return FileManager.default.fileExists(atPath: url.path) ? .unreadable("the file cannot be read") : .missing
        }
        switch Self.parse(name: name, data: data) {
        case .success(let profile): return .loaded(profile)
        case .failure(let error): return .unreadable(error.message)
        }
    }

    /// Every `.md` in the directory by name, each parsed or with why it is not usable.
    func list() -> [(name: String, load: Load)] {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { $0.hasSuffix(".md") }.map { String($0.dropLast(3)) }.sorted()
        return names.map { ($0, load($0)) }
    }

    struct ParseError: Error, Equatable { let message: String }

    static func parse(name: String, data: Data) -> Result<AgentProfile, ParseError> {
        guard let text = String(data: data, encoding: .utf8) else { return .failure(.init(message: "the file is not UTF-8 text")) }
        let (fields, body) = SkillFrontmatter.parse(text)
        if let named = SkillFrontmatter.value(fields, key: "name"), named != name {
            return .failure(.init(message: "its name is \(named) but the file is \(name).md"))
        }
        var tier: ModelTier?
        if let raw = SkillFrontmatter.value(fields, key: "tier") {
            guard let t = ModelTier(rawValue: raw.lowercased()) else {
                return .failure(.init(message: "tier must be easy, medium or hard, not \(raw)"))
            }
            tier = t
        }
        let role = SkillFrontmatter.value(fields, key: "role")
        if let role, SessionRoles.normalizedName(role) != role {
            return .failure(.init(message: "role must be lowercase letters, digits and dashes, at most 32 characters"))
        }
        var lists: [String: [String]] = [:]
        for key in ["skills", "tools"] {
            guard let field = fields.first(where: { $0.key == key }) else { continue }
            guard let items = Self.list(field) else { return .failure(.init(message: "\(key) must be a list of names")) }
            lists[key] = items
        }
        guard !body.isEmpty else { return .failure(.init(message: "the profile has no text below its frontmatter")) }
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return .success(AgentProfile(name: name, role: role, tier: tier, skills: lists["skills"], tools: lists["tools"],
                                     prompt: body, contentHash: hash))
    }

    /// `key: [a, b]` or the YAML block form (`- a` lines). nil when it is neither.
    static func list(_ field: SkillFrontmatterField) -> [String]? {
        let first = field.rawLines.first ?? ""
        let inline = first.firstIndex(of: ":").map { first[first.index(after: $0)...].trimmingCharacters(in: .whitespaces) } ?? ""
        func clean(_ s: Substring) -> String {
            s.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }
        if inline.hasPrefix("[") {
            guard inline.hasSuffix("]") else { return nil }
            return inline.dropFirst().dropLast().split(separator: ",").map(clean).filter { !$0.isEmpty }
        }
        guard inline.isEmpty else { return nil }
        var items: [String] = []
        for line in field.rawLines.dropFirst() {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { continue }
            guard t.hasPrefix("- ") else { return nil }
            items.append(clean(t.dropFirst(2)))
        }
        return items
    }

    /// Writes the example profiles once, the first time the directory does not exist. A person
    /// who deletes one keeps it deleted.
    static func seedExamplesIfNeeded(_ paths: IrisPaths) {
        let store = AgentProfileStore(paths: paths)
        guard !FileManager.default.fileExists(atPath: store.directory.path) else { return }
        try? FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        for (name, text) in examples {
            try? Data(text.utf8).write(to: store.directory.appendingPathComponent(name + ".md"), options: .atomic)
        }
    }

    static let examples: [(String, String)] = [
        ("reviewer", """
        ---
        role: reviewer
        tier: hard
        ---
        You review changes. Read the whole diff before commenting, run the tests it touches, and \
        lead with what is wrong or risky. Quote file and line for every finding, separate blocking \
        findings from suggestions, and say plainly when there is nothing to fix.
        """),
        ("researcher", """
        ---
        role: researcher
        ---
        You research questions. Search before answering, prefer primary sources, and say how sure \
        you are. Keep notes short, cite where each fact came from, and flag anything you could \
        not verify.
        """),
        ("writer", """
        ---
        role: writer
        tier: easy
        ---
        You help write and edit prose. Keep the author's voice, cut filler, prefer short plain \
        sentences, and explain any change that alters meaning.
        """),
    ]
}

/// What a profile's `tools:` list leaves a turn (#465 part 2): set at the start of each turn of a
/// profiled conversation, and of each turn of a subagent working for one, then read by the tool
/// list and by dispatch. Narrowing is for focus and token cost, not security.
struct AgentToolScope: Equatable, Sendable {
    let profile: AgentProfile
    /// A memory-reflection turn (`AppState.runReflection`): the tools its prompt names stay
    /// offered, because reflection is Iris's upkeep, not the profile's work.
    let reflecting: Bool

    func allows(_ tool: String) -> Bool {
        profile.allowsTool(tool) || (reflecting && AppState.reflectionTools.contains(tool))
    }

    /// Only ever removes: a tool a strip or gate already took out stays out, whatever this allows.
    func narrow(_ tools: [FunctionDeclaration]) -> [FunctionDeclaration] {
        tools.filter { allows($0.name) }
    }
}

/// The names a profile's `tools:` and `skills:` may use, as this launch knows them (#465):
/// every tool Iris can declare, the MCP servers and their tools, and the installed skills.
struct KnownCapabilities: Equatable, Sendable {
    var tools: Set<String>
    /// Configured MCP servers, connected or not.
    var mcpServers: Set<String>
    /// The ones connected now, whose tools are in `tools`: a tool name on one of these is judged
    /// against its real list; on a configured server not yet connected, it's taken as known.
    var connectedServers: Set<String> = []
    /// Skill names and folder names, lowercased: `discoverSkills` matches either.
    var skills: Set<String>

    /// The names in `profile`'s lists that match nothing here. They are ignored, as the spec
    /// says, and listed so a typo doesn't silently narrow a conversation to nothing.
    func unknown(in profile: AgentProfile) -> (tools: [String], skills: [String]) {
        let unknownTools = (profile.tools ?? []).filter { name in
            if name.hasPrefix("mcp:") { return !mcpServers.contains(String(name.dropFirst(4))) }
            if tools.contains(name) { return false }
            // A configured server's tool can't be listed until it connects, so until then its name
            // is given the benefit of the doubt; once connected, `tools` holds its real list.
            if JobProfile.isMCPTool(name), let server = name.components(separatedBy: JobProfile.mcpNameSeparator).first {
                return !mcpServers.contains(server) || connectedServers.contains(server)
            }
            return true
        }
        let unknownSkills = (profile.skills ?? []).filter { !skills.contains($0.lowercased()) }
        return (unknownTools, unknownSkills)
    }

    /// One line for the picker and the start notice, or nil when every name is known.
    func unknownLine(for profile: AgentProfile) -> String? {
        let (tools, skills) = unknown(in: profile)
        var parts: [String] = []
        if !tools.isEmpty { parts.append("tools Iris doesn't have: " + tools.joined(separator: ", ")) }
        if !skills.isEmpty { parts.append("skills it can't find: " + skills.joined(separator: ", ")) }
        return parts.isEmpty ? nil : "Names " + parts.joined(separator: "; ") + ". They are ignored."
    }
}
