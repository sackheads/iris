import Foundation

enum PluginStatus: Sendable, Equatable {
    case ok
    case needsConfig(String)
    case failed(String)
    case disabled
}

struct LoadedPlugin: Sendable {
    let manifest: IPFManifest
    let directory: URL
    var state: PluginState
    var status: PluginStatus
}

/// Registry for installed plugins. Discovers directories under `~/.iris/plugins/`, validates
/// manifests, resolves references, and exposes components to the subsystems that own them
/// (MCPManager, SkillManager, prompt rules). Executes nothing itself. A broken plugin is
/// isolated to a `.failed` status and never blocks other plugins.
actor PluginManager {
    static let shared = PluginManager()

    private let paths: IrisPaths
    private var loaded: [String: LoadedPlugin] = [:]

    init(paths: IrisPaths = .default) {
        self.paths = paths
    }

    func loadAll() async {
        loaded = [:]
        let store = PluginStateStore(paths: paths)
        var states = store.load()
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: paths.pluginsDir.path) else { return }

        for entry in entries.sorted() where !entry.hasPrefix(".") {
            let dir = paths.pluginsDir.appendingPathComponent(entry)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { continue }

            var state = states[entry] ?? PluginState()
            states[entry] = state

            guard let content = try? String(contentsOf: dir.appendingPathComponent("plugin.md"), encoding: .utf8) else {
                loaded[entry] = LoadedPlugin(
                    manifest: placeholderManifest(id: entry), directory: dir, state: state,
                    status: .failed("plugin.md is missing"))
                continue
            }
            let manifest: IPFManifest
            do {
                manifest = try IPFManifest.parse(markdown: content, directoryName: entry)
            } catch {
                loaded[entry] = LoadedPlugin(
                    manifest: placeholderManifest(id: entry), directory: dir, state: state,
                    status: .failed(String(describing: error)))
                continue
            }

            if !state.enabled {
                loaded[entry] = LoadedPlugin(manifest: manifest, directory: dir, state: state, status: .disabled)
                continue
            }
            state.installedVersion = manifest.version
            states[entry] = state
            let status = evaluateReadiness(manifest: manifest, directory: dir, state: state)
            loaded[entry] = LoadedPlugin(manifest: manifest, directory: dir, state: state, status: status)
        }
        store.save(states)
    }

    func plugins() -> [LoadedPlugin] {
        loaded.values.sorted {
            $0.manifest.name.localizedCaseInsensitiveCompare($1.manifest.name) == .orderedAscending
        }
    }

    func setEnabled(_ id: String, enabled: Bool) async {
        let store = PluginStateStore(paths: paths)
        var states = store.load()
        var state = states[id] ?? PluginState()
        state.enabled = enabled
        states[id] = state
        store.save(states)
        await loadAll()
    }

    func setConfigValue(_ id: String, key: String, value: String) async {
        let store = PluginStateStore(paths: paths)
        var states = store.load()
        var state = states[id] ?? PluginState()
        state.configValues[key] = value
        states[id] = state
        store.save(states)
        await loadAll()
    }

    /// Resolved, namespaced MCP configs from all enabled+ready plugins. Secrets are expanded
    /// in memory here and go straight into Process environments — never to disk.
    func mcpConfigs() -> [String: MCPServerConfig] {
        var result: [String: MCPServerConfig] = [:]
        for plugin in loaded.values where plugin.status == .ok {
            guard let mcpRel = plugin.manifest.components?.mcp else { continue }
            let mcpURL = plugin.directory.appendingPathComponent(mcpRel)
            guard let data = try? Data(contentsOf: mcpURL),
                  let servers = try? JSONDecoder().decode([String: MCPServerConfig].self, from: data) else {
                continue
            }
            let config = effectiveConfigValues(plugin)
            let secrets = KeychainManager.shared.secrets(service: KeychainManager.pluginService(plugin.manifest.id))
            for (serverName, server) in servers {
                guard let resolved = resolveServer(server, plugin: plugin, serverName: serverName,
                                                   config: config, secrets: secrets) else { continue }
                result["\(plugin.manifest.id).\(serverName)"] = resolved
            }
        }
        return result
    }

    func skillRoots() -> [URL] {
        loaded.values
            .filter { $0.status == .ok }
            .compactMap { plugin in
                plugin.manifest.components?.skills.map {
                    URL(fileURLWithPath: plugin.directory.appendingPathComponent($0).path)
                }
            }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .sorted { $0.path < $1.path }
    }

    func ruleFiles() -> [URL] {
        var files: [URL] = []
        for plugin in loaded.values where plugin.status == .ok {
            guard let rulesRel = plugin.manifest.components?.rules else { continue }
            let rulesDir = plugin.directory.appendingPathComponent(rulesRel)
            guard let items = try? FileManager.default.contentsOfDirectory(atPath: rulesDir.path) else { continue }
            for item in items.sorted() where item.hasSuffix(".md") && !item.hasPrefix(".") {
                files.append(rulesDir.appendingPathComponent(item))
            }
        }
        return files.sorted { $0.path < $1.path }
    }

    // MARK: - Private

    private func placeholderManifest(id: String) -> IPFManifest {
        IPFManifest(placeholderID: id)
    }

    private func effectiveConfigValues(_ plugin: LoadedPlugin) -> [String: String] {
        var values: [String: String] = [:]
        for field in plugin.manifest.config ?? [] {
            if let def = field.default { values[field.key] = def }
        }
        values.merge(plugin.state.configValues) { _, user in user }
        return values
    }

    /// Ready when: required secrets present, required config present, declared binaries found,
    /// and every ${keychain:} ref in mcp.json is declared. Any gap → .needsConfig with a reason.
    private func evaluateReadiness(manifest: IPFManifest, directory: URL, state: PluginState) -> PluginStatus {
        let secrets = KeychainManager.shared.secrets(service: KeychainManager.pluginService(manifest.id))
        for field in manifest.secrets ?? [] where field.required == true {
            if secrets[field.key] == nil {
                return .needsConfig("Missing secret \(field.key)")
            }
        }
        var config: [String: String] = [:]
        for field in manifest.config ?? [] {
            config[field.key] = state.configValues[field.key] ?? field.default
            if field.required == true && (config[field.key] ?? "").isEmpty {
                return .needsConfig("Missing config \(field.key)")
            }
        }
        for binary in manifest.requires?.binaries ?? [] {
            if BinaryResolver.resolve(command: binary.name) == nil {
                let hint = binary.installHint.map { " — install with: \($0)" } ?? ""
                return .needsConfig("Binary '\(binary.name)' not found\(hint)")
            }
        }
        if let mcpRel = manifest.components?.mcp {
            guard let raw = try? String(contentsOf: directory.appendingPathComponent(mcpRel), encoding: .utf8) else {
                return .needsConfig("mcp.json missing or unreadable at \(mcpRel)")
            }
            let declared = Set((manifest.secrets ?? []).map(\.key))
            for key in PluginReferences.keychainKeys(in: raw) where !declared.contains(key) {
                return .failed(IPFError.undeclaredSecret(key).description)
            }
            for key in PluginReferences.keychainKeys(in: raw) where secrets[key] == nil {
                return .needsConfig("Missing secret \(key)")
            }
            for key in PluginReferences.configKeys(in: raw) where config[key] == nil {
                return .needsConfig("Missing config \(key)")
            }
        }
        if let skillsRel = manifest.components?.skills {
            let skillsDir = directory.appendingPathComponent(skillsRel)
            if let entries = try? FileManager.default.contentsOfDirectory(atPath: skillsDir.path) {
                for entry in entries where !entry.hasPrefix(".") {
                    let violations = AgentSkillValidator.validate(directory: skillsDir.appendingPathComponent(entry))
                    if let first = violations.first {
                        return .failed("Skill '\(entry)': \(first)")
                    }
                }
            }
        }
        return .ok
    }

    private func resolveServer(_ server: MCPServerConfig, plugin: LoadedPlugin, serverName: String,
                               config: [String: String], secrets: [String: String]) -> MCPServerConfig? {
        guard let command = BinaryResolver.resolve(command: server.command) else { return nil }
        var env: [String: String]? = nil
        if let rawEnv = server.env {
            var expanded: [String: String] = [:]
            for (key, value) in rawEnv {
                guard let v = try? PluginReferences.expand(value, config: config, secrets: secrets) else { return nil }
                expanded[key] = v
            }
            env = expanded
        }
        return MCPServerConfig(command: command, args: server.args, env: env)
    }
}
