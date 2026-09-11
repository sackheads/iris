import Foundation
import System
import MCP

struct MCPServerConfig: Codable {
    let command: String
    let args: [String]
    let env: [String: String]?
}

actor MCPManager {
    static let shared = MCPManager()
    
    struct ActiveServer {
        let client: Client
        let transport: StdioTransport
        let process: Process
        var availableTools: [MCP.Tool] = []
        var sanitizedDescriptions: [String: String] = [:]
    }
    
    private var servers: [String: ActiveServer] = [:]

    enum ServerStatus: Sendable, Equatable {
        case running(toolCount: Int)
        case failed(String)
    }
    private var pluginConfigs: [String: MCPServerConfig] = [:]
    private var statuses: [String: ServerStatus] = [:]

    func setPluginConfigs(_ configs: [String: MCPServerConfig]) {
        pluginConfigs = configs
    }

    func serverStatuses() -> [String: ServerStatus] { statuses }

    func stopServers(withPrefix prefix: String) {
        for (name, server) in servers where name.hasPrefix(prefix) {
            server.process.terminate()
            servers[name] = nil
            statuses[name] = nil
        }
    }

    /// Stops exactly one server by its full name. Unlike `stopServers(withPrefix:)`, this
    /// never over-matches (e.g. stopping "sqlite" must not also stop "sqlite2").
    func stopServer(named name: String) {
        guard let server = servers[name] else { return }
        server.process.terminate()
        servers[name] = nil
        statuses[name] = nil
    }

    private var configPath: String {
        return IrisPaths.default.mcpServersJSON.path
    }

    init() {}

    func startServers() async {
        var legacy: [String: MCPServerConfig] = [:]
        if let data = try? Data(contentsOf: URL(fileURLWithPath: configPath)),
           let configs = try? JSONDecoder().decode([String: MCPServerConfig].self, from: data) {
            let fileSecrets = KeychainManager.shared.secrets(service: KeychainManager.mcpFileService)
            legacy = configs.mapValues { Self.expandLegacyEnv($0, secrets: fileSecrets) }
        }
        let merged = Self.mergeConfigs(legacy: legacy, plugin: pluginConfigs)

        for (name, config) in merged where servers[name] == nil {
            do {
                try await startServer(name: name, config: config)
            } catch {
                statuses[name] = .failed(String(describing: error))
                print("Failed to start MCP server \(name): \(error)")
            }
        }
    }

    func stopServers() async {
        for (_, server) in servers {
            server.process.terminate()
        }
        servers.removeAll()
        statuses.removeAll()
    }

    /// Full fleet restart from current state. WARNING: this restarts from the plugin configs
    /// last pushed via `setPluginConfigs(_:)` — callers must first re-push fresh configs
    /// (`PluginManager.shared.loadAll()` + `setPluginConfigs(await ...mcpConfigs())`), or
    /// stale state can resurrect servers (with expanded secrets) of uninstalled plugins.
    func reloadServers() async {
        await stopServers()
        await startServers()
    }

    func getServerNames() async -> [String] {
        return Array(servers.keys).sorted()
    }

    /// Removes one server entry from mcp_servers.json. Only called by the explicit
    /// "Convert to plugin" flow — Iris never otherwise edits the hand-edited file.
    func removeLegacyServer(named name: String) {
        let url = URL(fileURLWithPath: configPath)
        guard let data = try? Data(contentsOf: url),
              var configs = try? JSONDecoder().decode([String: MCPServerConfig].self, from: data) else { return }
        configs[name] = nil
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let out = try? encoder.encode(configs) {
            try? out.write(to: url, options: .atomic)
        }
    }
    
    private func startServer(name: String, config: MCPServerConfig) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: (config.command as NSString).expandingTildeInPath)
        process.arguments = config.args
        if let env = config.env {
            var fullEnv = ProcessInfo.processInfo.environment
            for (k, v) in env { fullEnv[k] = v }
            process.environment = fullEnv
        }
        
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        
        try process.run()
        
        let inputFD = FileDescriptor(rawValue: stdoutPipe.fileHandleForReading.fileDescriptor)
        let outputFD = FileDescriptor(rawValue: stdinPipe.fileHandleForWriting.fileDescriptor)
        
        let transport = StdioTransport(input: inputFD, output: outputFD)
        let client = Client(name: "Iris", version: "1.0.0")
        
        try await client.connect(transport: transport)
        let toolsResult = try await client.listTools()
        
        var safeDesc: [String: String] = [:]
        for tool in toolsResult.tools {
            if let desc = tool.description {
                safeDesc[tool.name] = await InjectionGuard.sanitize(desc, contextTag: "mcp_tool_\(tool.name)", maxTier: .tier3_canary)
            }
        }
        
        servers[name] = ActiveServer(
            client: client,
            transport: transport,
            process: process,
            availableTools: toolsResult.tools,
            sanitizedDescriptions: safeDesc
        )
        statuses[name] = .running(toolCount: toolsResult.tools.count)
        print("MCP Server \(name) connected. Found \(toolsResult.tools.count) tools.")
    }
    
    /// Recursively converts an MCP JSONSchema value (`MCP.Value`) into a Gemini `Schema`.
    ///
    /// ARRAY schemas always get `items` (defaulting to STRING when the source omits `items`
    /// or uses a form we don't model), because Gemini rejects arrays without items
    /// (see `Schema.items` doc comment). Nested OBJECT properties are recursed into rather
    /// than flattened, so nested arrays also get their `items` set.
    static func geminiSchema(fromMCP value: MCP.Value) -> Schema {
        guard case .object(let dict) = value else {
            return Schema(type: "STRING")
        }

        var desc: String? = nil
        if let descVal = dict["description"], case .string(let d) = descVal {
            desc = d
        }

        var typeStr: String? = nil
        if let typeVal = dict["type"], case .string(let t) = typeVal {
            typeStr = t
        }

        switch typeStr?.lowercased() {
        case "array":
            var itemsSchema = Schema(type: "STRING")
            if let itemsVal = dict["items"] {
                itemsSchema = geminiSchema(fromMCP: itemsVal)
            }
            return Schema(type: "ARRAY", description: desc, items: itemsSchema)

        case "object":
            var properties: [String: Schema] = [:]
            var required: [String] = []
            if let propsValue = dict["properties"], case .object(let props) = propsValue {
                for (k, v) in props {
                    properties[k] = geminiSchema(fromMCP: v)
                }
            }
            if let reqValue = dict["required"], case .array(let reqArray) = reqValue {
                for reqVal in reqArray {
                    if case .string(let s) = reqVal {
                        required.append(s)
                    }
                }
            }
            return Schema(
                type: "OBJECT",
                properties: properties.isEmpty ? nil : properties,
                required: required.isEmpty ? nil : required,
                description: desc
            )

        case .some(let t):
            // Scalar type (string/number/integer/boolean/etc.) — pass through uppercased.
            return Schema(type: t.uppercased(), description: desc)

        case .none:
            // Missing/unknown type: safe STRING fallback so callers embedding this inside an
            // ARRAY or OBJECT always end up with a schema Gemini will accept.
            return Schema(type: "STRING", description: desc)
        }
    }

    func getGeminiTools() -> [FunctionDeclaration] {
        var declarations: [FunctionDeclaration] = []
        for (serverName, server) in servers {
            for tool in server.availableTools {
                // Prepend server name to tool name to avoid collisions
                let uniqueName = "\(serverName)___\(tool.name)"

                // Convert MCP JSONSchema to Gemini Schema
                var properties: [String: Schema] = [:]
                var required: [String] = []

                if case .object(let schemaDict) = tool.inputSchema,
                   let propsValue = schemaDict["properties"],
                   case .object(let props) = propsValue {
                    for (k, v) in props {
                        // Match prior top-level behavior: properties with no recognizable
                        // `type` are silently dropped (rather than being STRING-fallback'd),
                        // since we don't know they were ever intended as tool parameters.
                        // Inside nested arrays/objects, geminiSchema(fromMCP:) still applies
                        // the safe STRING fallback so `items`/`properties` are never missing.
                        guard case .object(let vDict) = v,
                              let typeVal = vDict["type"],
                              case .string = typeVal else {
                            continue
                        }
                        properties[k] = Self.geminiSchema(fromMCP: v)
                    }
                    if let reqValue = schemaDict["required"], case .array(let reqArray) = reqValue {
                        for reqVal in reqArray {
                            if case .string(let s) = reqVal {
                                required.append(s)
                            }
                        }
                    }
                }

                let geminiSchema = Schema(
                    type: "OBJECT",
                    properties: properties.isEmpty ? nil : properties,
                    required: required.isEmpty ? nil : required,
                    description: nil
                )
                
                let safeDescription = server.sanitizedDescriptions[tool.name] ?? tool.description ?? "MCP Tool from \(serverName)"
                
                declarations.append(FunctionDeclaration(
                    name: uniqueName,
                    description: safeDescription,
                    parameters: geminiSchema
                ))
            }
        }
        return declarations
    }
    
    func callTool(name: String, args: [String: JSONValue]) async -> String {
        let parts = name.components(separatedBy: "___")
        guard parts.count == 2, let serverName = parts.first, let toolName = parts.last else {
            return "Error: Invalid MCP tool name format."
        }
        
        guard let server = servers[serverName] else {
            return "Error: MCP Server \(serverName) not found."
        }
        
        var mcpArgs: [String: Value] = [:]
        for (k, v) in args {
            if let mcpValue = try? Value(v) {
                mcpArgs[k] = mcpValue
            } else {
                mcpArgs[k] = .string(v.stringValue)
            }
        }
        
        do {
            let result = try await server.client.callTool(name: toolName, arguments: mcpArgs)
            if let firstContent = result.content.first {
                switch firstContent {
                case .text(let text, _, _):
                    return text
                default:
                    return "Tool executed successfully but returned non-text content."
                }
            }
            return "Tool executed successfully with no content returned."
        } catch {
            return "Error calling MCP tool: \(error)"
        }
    }

    /// Expands `${keychain:KEY}` refs in a legacy mcp_servers.json entry against the shared
    /// `iris.mcp` Keychain service. Unresolvable refs are left as-is so pre-existing files
    /// that happen to contain `${...}` strings keep working unchanged.
    static func expandLegacyEnv(_ config: MCPServerConfig, secrets: [String: String]) -> MCPServerConfig {
        guard let env = config.env else { return config }
        var expanded: [String: String] = [:]
        for (key, value) in env {
            expanded[key] = (try? PluginReferences.expand(value, config: [:], secrets: secrets)) ?? value
        }
        return MCPServerConfig(command: config.command, args: config.args, env: expanded)
    }

    /// Plugin keys are already namespaced `<plugin-id>.<server>`, so a straight merge cannot
    /// collide with legacy names; legacy wins if a collision is somehow constructed.
    static func mergeConfigs(legacy: [String: MCPServerConfig],
                             plugin: [String: MCPServerConfig]) -> [String: MCPServerConfig] {
        var merged = plugin
        for (k, v) in legacy { merged[k] = v }
        return merged
    }
}
