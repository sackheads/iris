import Foundation
import System
import MCP

/// One `mcp_servers.json` (or plugin `mcp.json`) entry: a local stdio process, or a remote
/// Streamable HTTP endpoint (#1096). See docs/specs/2026-11-12-remote-mcp-http-transport.md.
enum MCPServerConfig: Codable, Equatable, Sendable {
    case stdio(command: String, args: [String], env: [String: String]?)
    case remote(url: URL, headers: [String: String], allowedKeys: Set<String>)

    struct DecodeError: Error, CustomStringConvertible {
        let description: String
    }

    private enum Key: String, CodingKey {
        case command, args, env, url, serverUrl, httpUrl, headers, allowedKeys, type
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        let urlKeys = [Key.url, .serverUrl, .httpUrl].filter { c.contains($0) }
        let hasCommand = c.contains(.command)
        let type = try c.decodeIfPresent(String.self, forKey: .type)?.lowercased()

        if type == "sse" {
            throw DecodeError(description: "the legacy HTTP+SSE transport is not supported; use the server's Streamable HTTP endpoint")
        }
        if urlKeys.count > 1 {
            throw DecodeError(description: "more than one URL key (\(urlKeys.map(\.rawValue).joined(separator: ", "))); use only `url`")
        }
        if hasCommand && !urlKeys.isEmpty {
            throw DecodeError(description: "has both `command` and `\(urlKeys[0].rawValue)`; an entry is stdio or remote, not both")
        }

        if let urlKey = urlKeys.first {
            if let type, type != "http", type != "streamable-http" {
                throw DecodeError(description: "`type: \(type)` does not match a remote entry")
            }
            for stdioOnly in [Key.env, .args] where c.contains(stdioOnly) {
                throw DecodeError(description: "`\(stdioOnly.rawValue)` is for stdio servers; a remote entry takes `headers`")
            }
            let raw = try c.decode(String.self, forKey: urlKey)
            guard let url = URL(string: raw), url.scheme != nil, url.host() != nil else {
                throw DecodeError(description: "`\(urlKey.rawValue)` is not an absolute URL")
            }
            self = .remote(url: url,
                           headers: try c.decodeIfPresent([String: String].self, forKey: .headers) ?? [:],
                           allowedKeys: Set(try c.decodeIfPresent([String].self, forKey: .allowedKeys) ?? []))
        } else if hasCommand {
            if let type, type != "stdio" {
                throw DecodeError(description: "`type: \(type)` does not match a stdio entry")
            }
            for remoteOnly in [Key.headers, .allowedKeys] where c.contains(remoteOnly) {
                throw DecodeError(description: "`\(remoteOnly.rawValue)` is for remote servers; a stdio entry takes `env`")
            }
            self = .stdio(command: try c.decode(String.self, forKey: .command),
                          args: try c.decodeIfPresent([String].self, forKey: .args) ?? [],
                          env: try c.decodeIfPresent([String: String].self, forKey: .env))
        } else {
            throw DecodeError(description: "needs `command` (stdio) or `url` (remote)")
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        switch self {
        case .stdio(let command, let args, let env):
            try c.encode(command, forKey: .command)
            try c.encode(args, forKey: .args)
            try c.encodeIfPresent(env, forKey: .env)
        case .remote(let url, let headers, let allowedKeys):
            try c.encode(url.absoluteString, forKey: .url)
            if !headers.isEmpty { try c.encode(headers, forKey: .headers) }
            if !allowedKeys.isEmpty { try c.encode(allowedKeys.sorted(), forKey: .allowedKeys) }
        }
    }
}

actor MCPManager {
    static let shared = MCPManager()
    
    struct ActiveServer {
        let client: Client
        /// Stdio: terminate the process. Remote: disconnect the client (no process to kill).
        let stop: @Sendable () async -> Void
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

    func stopServers(withPrefix prefix: String) async {
        for (name, server) in servers where name.hasPrefix(prefix) {
            servers[name] = nil
            statuses[name] = nil
            await server.stop()
        }
    }

    /// Stops exactly one server by its full name. Unlike `stopServers(withPrefix:)`, this
    /// never over-matches (e.g. stopping "sqlite" must not also stop "sqlite2").
    func stopServer(named name: String) async {
        guard let server = servers[name] else { return }
        servers[name] = nil
        statuses[name] = nil
        await server.stop()
    }

    private let configPathOverride: String?
    private var configPath: String {
        configPathOverride ?? IrisPaths.default.mcpServersJSON.path
    }
    /// The `iris.mcp` Keychain blob, read lazily: only when an entry actually references a key.
    private let fileSecrets: @Sendable () -> [String: String]
    /// Bounds a remote server's connect + tools/list (spec: Lifecycle step 3).
    private let remoteConnectTimeout: Double

    init(configPath: String? = nil,
         fileSecrets: @escaping @Sendable () -> [String: String] = {
             KeychainManager.shared.secrets(service: KeychainManager.mcpFileService)
         },
         remoteConnectTimeout: Double = 30) {
        self.configPathOverride = configPath
        self.fileSecrets = fileSecrets
        self.remoteConnectTimeout = remoteConnectTimeout
    }

    func startServers() async {
        var legacy: [String: MCPServerConfig] = [:]
        let parsed = loadLegacyFile()
        for (name, reason) in parsed.failures where servers[name] == nil {
            statuses[name] = .failed(reason)
            print("MCP server \(name) not started: \(reason)")
        }
        if !parsed.configs.isEmpty {
            // Stdio env keeps its lenient expansion; only read the Keychain if something asks.
            let needsSecrets = parsed.configs.values.contains {
                if case .stdio(_, _, let env?) = $0 { return env.values.contains { !PluginReferences.keychainKeys(in: $0).isEmpty } }
                return false
            }
            let secrets = needsSecrets ? fileSecrets() : [:]
            legacy = parsed.configs.mapValues { Self.expandLegacyEnv($0, secrets: secrets) }
        }
        let merged = Self.mergeConfigs(legacy: legacy, plugin: pluginConfigs)

        for (name, config) in merged.sorted(by: { $0.key < $1.key }) where servers[name] == nil {
            do {
                try await startServer(name: name, config: config)
            } catch {
                statuses[name] = .failed(Self.describe(error))
                print("Failed to start MCP server \(name): \(error)")
            }
        }
    }

    func stopServers() async {
        let running = servers
        servers.removeAll()
        statuses.removeAll()
        for (_, server) in running {
            await server.stop()
        }
    }

    /// Full fleet restart from current state. WARNING: this restarts from the plugin configs
    /// last pushed via `setPluginConfigs(_:)` — callers must first re-push fresh configs
    /// (`PluginManager.shared.loadAll()` + `setPluginConfigs(await ...mcpConfigs())`), or
    /// stale state can resurrect servers (with expanded secrets) of uninstalled plugins.
    func reloadServers() async {
        await stopServers()
        await startServers()
    }

    /// Every configured server's name, connected or not (#465): the legacy file's entries and the
    /// plugins'. A profile's `mcp:<name>` is judged against this, so a server still starting at
    /// launch isn't called unknown.
    func configuredServerNames() -> Set<String> {
        Set(pluginConfigs.keys).union(loadLegacyFile().names)
    }

    func getServerNames() async -> [String] {
        return Array(servers.keys).sorted()
    }

    /// Removes one server entry from mcp_servers.json. Only called by the explicit
    /// "Convert to plugin" flow — Iris never otherwise edits the hand-edited file.
    func removeLegacyServer(named name: String) {
        let url = URL(fileURLWithPath: configPath)
        guard let data = try? Data(contentsOf: url),
              let out = Self.removingLegacyEntry(named: name, from: data) else { return }
        try? out.write(to: url, options: .atomic)
    }

    /// The file with one entry removed, edited as raw JSON so the `mcpServers` wrapper and any
    /// entry this build cannot model survive (#1096). Nil when the file is not a JSON object.
    static func removingLegacyEntry(named name: String, from data: Data) -> Data? {
        guard var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        if var wrapped = root["mcpServers"] as? [String: Any] {
            wrapped[name] = nil
            root["mcpServers"] = wrapped
        } else {
            root[name] = nil
        }
        return try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    }

    // MARK: - Legacy file parsing (#1096)

    /// Status name for a file that is unreadable as a whole. No dot, so the Plugins pane lists
    /// it among the hand-configured servers (`PluginsSettingsView.legacyServerNames`).
    static let legacyFileStatusName = "(config file)"

    struct LegacyFile: Equatable {
        var configs: [String: MCPServerConfig] = [:]
        var failures: [String: String] = [:]
        /// Every entry name in the file, valid or not; a profile's `mcp:<name>` is judged against these.
        var names: Set<String> = []
    }

    private func loadLegacyFile() -> LegacyFile {
        guard let data = FileManager.default.contents(atPath: configPath) else { return LegacyFile() }
        return Self.parseLegacyFile(data)
    }

    /// Each entry is decoded on its own, so one bad entry fails alone instead of hiding the file.
    static func parseLegacyFile(_ data: Data) -> LegacyFile {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return LegacyFile(failures: [legacyFileStatusName: "mcp_servers.json is not a JSON object"])
        }
        let entries = (root["mcpServers"] as? [String: Any]) ?? root
        var file = LegacyFile(names: Set(entries.keys))
        for (name, value) in entries {
            do {
                let entryData = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
                file.configs[name] = try JSONDecoder().decode(MCPServerConfig.self, from: entryData)
            } catch {
                file.failures[name] = "invalid entry: \(describe(error))"
            }
        }
        return file
    }

    /// A readable reason for a status line: our own messages verbatim, Decoding errors without
    /// their coding-path noise.
    static func describe(_ error: Error) -> String {
        if let e = error as? MCPServerConfig.DecodeError { return e.description }
        if let e = error as? RemoteStartError { return e.description }
        if error is TimeoutError { return "timed out connecting" }
        if let e = error as? DecodingError {
            switch e {
            case .typeMismatch(_, let ctx), .valueNotFound(_, let ctx), .keyNotFound(_, let ctx), .dataCorrupted(let ctx):
                return ctx.debugDescription
            @unknown default: return String(describing: e)
            }
        }
        return String(describing: error)
    }

    // MARK: - Remote servers (#1096)

    struct RemoteStartError: Error, CustomStringConvertible {
        let description: String
    }

    /// Nil when `url` may be used: https anywhere, or plain http to a loopback address only, since
    /// a bearer token over plaintext goes to whoever is on the path.
    static func remoteURLRefusal(_ url: URL) -> String? {
        switch url.scheme?.lowercased() {
        case "https": return nil
        case "http": return isLoopbackHost(url.host(percentEncoded: false) ?? "") ? nil
            : "plain http is only allowed to localhost; use https for \(url.host(percentEncoded: false) ?? "this host")"
        default: return "unsupported URL scheme `\(url.scheme ?? "")`; remote MCP servers need https"
        }
    }

    static func isLoopbackHost(_ host: String) -> Bool {
        let h = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if h == "localhost" || h == "::1" { return true }
        let octets = h.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4, octets.allSatisfy({ $0.allSatisfy(\.isNumber) }) else { return false }
        let values = octets.compactMap { UInt8($0) }
        return values.count == 4 && values[0] == 127
    }

    /// Expands `${keychain:KEY}` in header values. Every referenced key must be in `allowedKeys`,
    /// checked before the Keychain is read; only the allowed subset reaches the expander, so a
    /// refused key's value is never touched. Unlike stdio `env`, an unresolved reference fails.
    static func resolveHeaders(_ headers: [String: String], allowedKeys: Set<String>,
                               secrets: () -> [String: String]) throws -> [String: String] {
        var referenced: Set<String> = []
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) {
            let keys = PluginReferences.keychainKeys(in: value)
            if let refused = keys.subtracting(allowedKeys).sorted().first {
                throw RemoteStartError(description:
                    "header \(name) references \(refused), which is not in this server's allowedKeys")
            }
            if !PluginReferences.configKeys(in: value).isEmpty {
                throw RemoteStartError(description: "header \(name) uses ${config:…}, which only plugins support")
            }
            referenced.formUnion(keys)
        }
        guard !referenced.isEmpty else { return headers }
        let granted = secrets().filter { referenced.contains($0.key) }
        var out: [String: String] = [:]
        for (name, value) in headers {
            if let missing = PluginReferences.keychainKeys(in: value).sorted().first(where: { granted[$0] == nil }) {
                throw RemoteStartError(description:
                    "header \(name) references \(missing), which is not in the Keychain (iris.mcp)")
            }
            out[name] = try PluginReferences.expand(value, config: [:], secrets: granted)
        }
        return out
    }

    private func startServer(name: String, config: MCPServerConfig) async throws {
        switch config {
        case .stdio(let command, let args, let env):
            try await startStdioServer(name: name, command: command, args: args, env: env)
        case .remote(let url, let headers, let allowedKeys):
            if let refusal = Self.remoteURLRefusal(url) { throw RemoteStartError(description: refusal) }
            let resolved = try Self.resolveHeaders(headers, allowedKeys: allowedKeys, secrets: fileSecrets)
            try await startRemoteServer(name: name, url: url, headers: resolved)
        }
    }

    private func startRemoteServer(name: String, url: URL, headers: [String: String]) async throws {
        let transport = HTTPClientTransport(endpoint: url, streaming: true, requestModifier: { request in
            var request = request
            for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }
            return request
        })
        let client = Client(name: "Iris", version: "1.0.0")
        let tools: [MCP.Tool]
        do {
            tools = try await withTimeout(seconds: remoteConnectTimeout) {
                _ = try await client.connect(transport: transport)
                return try await client.listTools().tools
            }
        } catch {
            await client.disconnect()
            throw error
        }
        try await register(name: name, client: client, tools: tools, stop: { await client.disconnect() })
    }

    private func startStdioServer(name: String, command: String, args: [String], env: [String: String]?) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: (command as NSString).expandingTildeInPath)
        process.arguments = args
        process.environment = Self.environment(forEnv: env)
        
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
        try await register(name: name, client: client, tools: toolsResult.tools,
                           stop: { [process] in process.terminate() })
    }

    private func register(name: String, client: Client, tools: [MCP.Tool],
                          stop: @escaping @Sendable () async -> Void) async throws {
        var safeDesc: [String: String] = [:]
        for tool in tools {
            if let desc = tool.description {
                safeDesc[tool.name] = await InjectionGuard.sanitize(desc, contextTag: "mcp_tool_\(tool.name)", maxTier: .tier3_canary)
            }
        }
        
        servers[name] = ActiveServer(
            client: client,
            stop: stop,
            availableTools: tools,
            sanitizedDescriptions: safeDesc
        )
        statuses[name] = .running(toolCount: tools.count)
        print("MCP Server \(name) connected. Found \(tools.count) tools.")
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
        Self.declarations(for: servers.map { name, server in
            (name, server.availableTools, server.sanitizedDescriptions)
        })
    }

    /// The declarations for what the servers reported, so the order is testable without a live
    /// server. Servers go in name order: `servers` is a dictionary whose order changes between
    /// launches, and a reordered tool list misses the whole prompt cache (5a §0.6).
    static func declarations(for servers: [(name: String, tools: [MCP.Tool], sanitizedDescriptions: [String: String])]) -> [FunctionDeclaration] {
        var declarations: [FunctionDeclaration] = []
        for (serverName, availableTools, sanitizedDescriptions) in servers.sorted(by: { $0.name < $1.name }) {
            for tool in availableTools {
                // Prepend server name to tool name to avoid collisions
                let uniqueName = Self.qualifiedName(server: serverName, tool: tool.name)

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
                
                let safeDescription = sanitizedDescriptions[tool.name] ?? tool.description ?? "MCP Tool from \(serverName)"
                
                declarations.append(FunctionDeclaration(
                    name: uniqueName,
                    description: safeDescription,
                    parameters: geminiSchema
                ))
            }
        }
        return declarations
    }

    /// How a tool is named once it leaves its server: `<server>___<tool>`, so two servers offering
    /// `search` do not collide. One spelling, used by the declarations, the call router and the
    /// read-only set alike — they were three literals, and a set joined differently from the names
    /// it is matched against fails silently.
    static func qualifiedName(server: String, tool: String) -> String {
        "\(server)\(JobProfile.mcpNameSeparator)\(tool)"
    }

    /// The prefixed names of the MCP tools whose server annotated them `readOnlyHint: true` — the
    /// only MCP tools a `readOnly` job run may call (#187 §0.2). A server that says nothing about
    /// a tool is not making a claim this harness can act on, so that tool is denied rather than
    /// assumed harmless; see `JobProfile.readOnlyDenies`.
    func readOnlyToolNames() -> Set<String> {
        Self.readOnlyToolNames(in: servers.flatMap { serverName, server in
            server.availableTools.map { (serverName, $0.name, $0.annotations.readOnlyHint) }
        })
    }

    /// The rule above, over what the servers reported, so it is testable without a live server.
    static func readOnlyToolNames(in tools: [(server: String, tool: String, readOnly: Bool?)]) -> Set<String> {
        Set(tools.filter { $0.readOnly == true }.map { qualifiedName(server: $0.server, tool: $0.tool) })
    }

    func callTool(name: String, args: [String: JSONValue]) async -> String {
        let parts = name.components(separatedBy: JobProfile.mcpNameSeparator)
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
    /// Remote entries are returned unchanged: their headers are expanded at start, against
    /// the entry's own `allowedKeys` (`resolveHeaders`).
    static func expandLegacyEnv(_ config: MCPServerConfig, secrets: [String: String]) -> MCPServerConfig {
        guard case .stdio(let command, let args, let env?) = config else { return config }
        var expanded: [String: String] = [:]
        for (key, value) in env {
            expanded[key] = (try? PluginReferences.expand(value, config: [:], secrets: secrets)) ?? value
        }
        return .stdio(command: command, args: args, env: expanded)
    }

    /// Plugin keys are already namespaced `<plugin-id>.<server>`, so a straight merge cannot
    /// collide with legacy names; legacy wins if a collision is somehow constructed.
    static func mergeConfigs(legacy: [String: MCPServerConfig],
                             plugin: [String: MCPServerConfig]) -> [String: MCPServerConfig] {
        var merged = plugin
        for (k, v) in legacy { merged[k] = v }
        return merged
    }

    /// The environment an MCP server process is spawned with: the login-shell PATH applied over
    /// the process environment (#228), then the server's own `env` overrides on top. Static and
    /// separate from `startServer` so a test can assert the PATH without a real MCP handshake.
    static func environment(for config: MCPServerConfig,
                            base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        guard case .stdio(_, _, let env) = config else { return BinaryResolver.commandEnvironment(base: base) }
        return environment(forEnv: env, base: base)
    }

    static func environment(forEnv env: [String: String]?,
                            base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var fullEnv = BinaryResolver.commandEnvironment(base: base)
        if let env {
            for (k, v) in env { fullEnv[k] = v }
        }
        return fullEnv
    }
}
