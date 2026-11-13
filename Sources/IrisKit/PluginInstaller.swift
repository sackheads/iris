import Foundation

/// A fully-specified pending install. Secrets ride in memory only; `commit` moves them to
/// the Keychain and never writes them into the plugin directory.
struct PluginDraft: Sendable {
    var manifest: IPFManifest
    var files: [String: Data]
    var secretValues: [String: String] = [:]
    var configValues: [String: String] = [:]
    var source: String
}

/// The one install/uninstall primitive every flow converges on. All writes are staged into a
/// temp directory and validated before anything lands in `~/.iris/plugins/` — cancel or
/// failure at any point leaves no trace.
struct PluginInstaller: Sendable {
    let paths: IrisPaths

    /// Local-directory flow: read every regular file into a draft and validate the manifest.
    func stage(directory: URL, source: String) throws -> PluginDraft {
        let fm = FileManager.default
        let manifestURL = directory.appendingPathComponent("plugin.md")
        let content = try String(contentsOf: manifestURL, encoding: .utf8)
        let manifest = try IPFManifest.parse(markdown: content, directoryName: directory.lastPathComponent)

        var files: [String: Data] = [:]
        let enumerator = fm.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        let dirPath = (directory.path as NSString).standardizingPath
        while let url = enumerator?.nextObject() as? URL {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { continue }
            let filePath = (url.path as NSString).standardizingPath
            guard filePath.hasPrefix(dirPath + "/") else {
                throw IPFError.yamlError("File \(url.path) is outside the plugin directory")
            }
            let relative = String(filePath.dropFirst(dirPath.count + 1))
            files[relative] = try Data(contentsOf: url)
        }
        return PluginDraft(manifest: manifest, files: files, source: source)
    }

    func commit(_ draft: PluginDraft) throws {
        let fm = FileManager.default
        let id = draft.manifest.id

        // Stage into a temp dir and re-validate what will actually land on disk.
        let staging = fm.temporaryDirectory.appendingPathComponent("iris-staging-\(UUID().uuidString)/\(id)")
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging.deletingLastPathComponent()) }

        for (relative, data) in draft.files {
            let target = staging.appendingPathComponent(relative)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: target)
        }
        let written = try String(contentsOf: staging.appendingPathComponent("plugin.md"), encoding: .utf8)
        _ = try IPFManifest.parse(markdown: written, directoryName: id)

        // Move into place (replace an existing install of the same id) using move-aside so a
        // failed final move never leaves the destination missing: an existing install is moved
        // to a backup location first, and restored if the move-in fails.
        let destination = paths.pluginsDir.appendingPathComponent(id)
        let backup = fm.temporaryDirectory.appendingPathComponent("iris-backup-\(UUID().uuidString)")
        var movedAside = false
        if fm.fileExists(atPath: destination.path) {
            try fm.moveItem(at: destination, to: backup)
            movedAside = true
        }
        do {
            try fm.moveItem(at: staging, to: destination)
        } catch {
            if movedAside { try? fm.moveItem(at: backup, to: destination) }
            throw error
        }
        if movedAside { try? fm.removeItem(at: backup) }

        // Only after the directory landed: secrets to Keychain, state to plugins.json.
        // Empty-string values are placeholders the wizard seeded for declared-but-unfilled
        // secrets — skip them so no empty Keychain entries are created.
        let secretsToStore = draft.secretValues.filter { !$0.value.isEmpty }
        if !secretsToStore.isEmpty {
            let service = KeychainManager.pluginService(id)
            KeychainManager.shared.updateSecrets(service: service) { $0.merge(secretsToStore) { _, new in new } }
        }
        let store = PluginStateStore(paths: paths)
        var states = store.load()
        var state = states[id] ?? PluginState()
        state.source = draft.source
        state.installedVersion = draft.manifest.version
        state.configValues.merge(draft.configValues) { _, new in new }
        states[id] = state
        store.save(states)
    }

    /// Stop the plugin's servers, delete its directory, Keychain service, and state entry.
    /// External auth credential stores (e.g. nlm's cookie directory) belong to the tool and
    /// are deliberately left alone.
    func uninstall(id: String) async throws {
        await MCPManager.shared.stopServers(withPrefix: "\(id).")
        let dir = paths.pluginsDir.appendingPathComponent(id)
        if FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.removeItem(at: dir)
        }
        KeychainManager.shared.deleteSecrets(service: KeychainManager.pluginService(id))
        let store = PluginStateStore(paths: paths)
        var states = store.load()
        states[id] = nil
        store.save(states)
    }
}

// MARK: - Wrap-and-lift (snippet / form -> plugin draft)

struct LiftedEnv: Sendable, Equatable {
    var secrets: [String: String] = [:]
    var config: [String: String] = [:]
}

extension PluginInstaller {
    private static let secretMarkers = ["KEY", "TOKEN", "SECRET", "PASSWORD", "PASSWD", "COOKIE", "CREDENTIAL", "AUTH"]

    /// Heuristic pre-classification; the wizard shows the result for user confirmation and
    /// lets them re-tag any field before commit.
    static func isSecretLooking(key: String) -> Bool {
        let upper = key.uppercased()
        return secretMarkers.contains { upper.contains($0) }
    }

    static func classifyEnv(_ env: [String: String]) -> LiftedEnv {
        var lifted = LiftedEnv()
        for (key, value) in env {
            if isSecretLooking(key: key) {
                lifted.secrets[key] = value
            } else {
                lifted.config[key] = value
            }
        }
        return lifted
    }

    static func derivePluginID(from serverName: String) throws -> String {
        let id = serverName.lowercased()
            .replacing(/[^a-z0-9]+/, with: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        guard !id.isEmpty else {
            throw IPFError.invalidJSON("Cannot derive a plugin id from server name '\(serverName)'")
        }
        return id
    }

    static func headerKeyIdentifier(for headerName: String) -> String {
        let cleaned = headerName.uppercased()
            .replacing(/[^A-Z0-9]+/, with: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return cleaned.isEmpty ? "HEADER_SECRET" : cleaned
    }

    /// Produces a safe double-quoted YAML scalar: escapes backslashes and quotes, and turns
    /// newlines/tabs/carriage returns into their YAML double-quoted escapes so untrusted
    /// snippet strings can't break the manifest's structure or inject extra fields.
    private static func yamlQuoted(_ s: String) -> String {
        var out = s
        out = out.replacingOccurrences(of: "\\", with: "\\\\")
        out = out.replacingOccurrences(of: "\"", with: "\\\"")
        out = out.replacingOccurrences(of: "\r", with: "\\r")
        out = out.replacingOccurrences(of: "\n", with: "\\n")
        out = out.replacingOccurrences(of: "\t", with: "\\t")
        return "\"\(out)\""
    }

    /// Builds a single-server plugin draft from a standard `mcpServers` JSON snippet (or a
    /// bare `{name: {...}}` object), supporting both stdio (`command`) and remote HTTP
    /// (`url` / `serverUrl` / `httpUrl`) servers (#1105). Literal secrets are lifted into
    /// Keychain declarations; the generated `mcp.json` carries only `${...}` references.
    static func draft(fromSnippet json: String) throws -> PluginDraft {
        guard let data = json.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw IPFError.invalidJSON("Snippet is not valid JSON")
        }
        let serverDict = (raw["mcpServers"] as? [String: Any]) ?? raw
        if serverDict.count > 1 {
            let names = serverDict.keys.sorted().joined(separator: ", ")
            throw IPFError.invalidJSON(
                "Snippet contains \(serverDict.count) servers (\(names)); paste one server at a time")
        }
        guard let (serverName, serverAny) = serverDict.first,
              let server = serverAny as? [String: Any] else {
            throw IPFError.invalidJSON("Snippet contains no server object")
        }
        let id = try derivePluginID(from: serverName)

        if let command = server["command"] as? String {
            let args = (server["args"] as? [String]) ?? []
            let env = (server["env"] as? [String: String]) ?? [:]
            let lifted = classifyEnv(env)

            let envKeyPattern = /^[A-Za-z0-9_]+$/
            for key in env.keys where (try? envKeyPattern.wholeMatch(in: key)) == nil {
                throw IPFError.invalidJSON("Env key '\(key)' is not a valid identifier (A-Za-z0-9_)")
            }

            return try buildGeneratedDraft(
                id: id, serverName: serverName, command: command, args: args,
                secretValues: lifted.secrets, configValues: lifted.config, source: "snippet")
        }

        // Remote server path (`url` / `serverUrl` / `httpUrl`). Decode via MCPServerConfig to
        // enforce alias uniqueness, SSE refusal, and URL validity.
        let entryData = try JSONSerialization.data(withJSONObject: server, options: [.fragmentsAllowed])
        let decoded: MCPServerConfig
        do {
            decoded = try JSONDecoder().decode(MCPServerConfig.self, from: entryData)
        } catch {
            throw IPFError.invalidJSON(MCPManager.describe(error))
        }
        guard case .remote(let url, let rawHeaders, _) = decoded else {
            throw IPFError.invalidJSON("Snippet has no server with a command or url")
        }
        if let refusal = MCPManager.remoteURLRefusal(url) {
            throw IPFError.invalidJSON(refusal)
        }

        let legacySecrets = KeychainManager.shared.secrets(service: KeychainManager.mcpFileService)
        var headerTemplates: [String: String] = [:]
        var secretValues: [String: String] = [:]
        var configValues: [String: String] = [:]

        for (headerName, rawValue) in rawHeaders {
            let existingKeychainRefs = PluginReferences.keychainKeys(in: rawValue)
            let existingConfigRefs = PluginReferences.configKeys(in: rawValue)
            if !existingKeychainRefs.isEmpty || !existingConfigRefs.isEmpty {
                headerTemplates[headerName] = rawValue
                for key in existingKeychainRefs {
                    secretValues[key] = legacySecrets[key] ?? ""
                }
                for key in existingConfigRefs {
                    configValues[key] = ""
                }
                continue
            }

            let keyID = headerKeyIdentifier(for: headerName)
            let trimmed = rawValue.trimmingCharacters(in: .whitespaces)
            if trimmed.lowercased().hasPrefix("bearer ") {
                let token = String(trimmed.dropFirst(7)).trimmingCharacters(in: .whitespaces)
                headerTemplates[headerName] = "Bearer ${keychain:\(keyID)}"
                secretValues[keyID] = token
            } else if headerName.lowercased() == "authorization" || isSecretLooking(key: headerName) {
                headerTemplates[headerName] = "${keychain:\(keyID)}"
                secretValues[keyID] = rawValue
            } else {
                headerTemplates[headerName] = "${config:\(keyID)}"
                configValues[keyID] = rawValue
            }
        }

        return try buildGeneratedRemoteDraft(
            id: id, serverName: serverName, url: url, headerTemplates: headerTemplates,
            secretValues: secretValues, configValues: configValues, source: "snippet")
    }

    /// Direct form builder for a Remote HTTP MCP server (#1105). Validates the URL policy and
    /// lifts Bearer tokens and secret custom headers into Keychain declarations.
    static func draftForRemoteServer(
        name: String,
        urlString: String,
        bearerToken: String?,
        customHeaders: [(name: String, value: String, isSecret: Bool)] = [],
        source: String = "form"
    ) throws -> PluginDraft {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw IPFError.invalidJSON("Server name is required")
        }
        let id = try derivePluginID(from: trimmedName)
        let trimmedURL = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmedURL), url.scheme != nil, url.host() != nil else {
            throw IPFError.invalidJSON("'\(trimmedURL)' is not a valid URL")
        }
        if let refusal = MCPManager.remoteURLRefusal(url) {
            throw IPFError.invalidJSON(refusal)
        }

        var headerTemplates: [String: String] = [:]
        var secretValues: [String: String] = [:]
        var configValues: [String: String] = [:]

        if let rawToken = bearerToken?.trimmingCharacters(in: .whitespacesAndNewlines), !rawToken.isEmpty {
            let cleanToken = rawToken.lowercased().hasPrefix("bearer ")
                ? String(rawToken.dropFirst(7)).trimmingCharacters(in: .whitespaces)
                : rawToken
            headerTemplates["Authorization"] = "Bearer ${keychain:BEARER_TOKEN}"
            secretValues["BEARER_TOKEN"] = cleanToken
        }

        for item in customHeaders {
            let hName = item.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !hName.isEmpty else { continue }
            let keyID = headerKeyIdentifier(for: hName)
            if item.isSecret {
                headerTemplates[hName] = "${keychain:\(keyID)}"
                secretValues[keyID] = item.value
            } else {
                headerTemplates[hName] = "${config:\(keyID)}"
                configValues[keyID] = item.value
            }
        }

        return try buildGeneratedRemoteDraft(
            id: id, serverName: trimmedName, url: url, headerTemplates: headerTemplates,
            secretValues: secretValues, configValues: configValues, source: source)
    }

    /// Direct form builder for a Local Command (stdio) MCP server (#1105).
    static func draftForStdioServer(
        name: String,
        command: String,
        args: [String],
        env: [(key: String, value: String, isSecret: Bool)] = [],
        source: String = "form"
    ) throws -> PluginDraft {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw IPFError.invalidJSON("Server name is required")
        }
        let trimmedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCommand.isEmpty else {
            throw IPFError.invalidJSON("Command is required")
        }
        let id = try derivePluginID(from: trimmedName)
        let envKeyPattern = /^[A-Za-z0-9_]+$/
        var secretValues: [String: String] = [:]
        var configValues: [String: String] = [:]
        for item in env {
            let k = item.key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !k.isEmpty else { continue }
            guard (try? envKeyPattern.wholeMatch(in: k)) != nil else {
                throw IPFError.invalidJSON("Env key '\(k)' is not a valid identifier (A-Za-z0-9_)")
            }
            if item.isSecret {
                secretValues[k] = item.value
            } else {
                configValues[k] = item.value
            }
        }
        return try buildGeneratedDraft(
            id: id, serverName: trimmedName, command: trimmedCommand, args: args,
            secretValues: secretValues, configValues: configValues, source: source)
    }

    /// Rebuilds a generated draft's `plugin.md` and `mcp.json` from its current
    /// secret/config classification. Called by the wizard after the user re-tags a field
    /// (secret <-> config), so the committed files match what the user confirmed. Drafts
    /// that are not wrap-and-lift generated (anything beyond exactly plugin.md + mcp.json,
    /// e.g. a staged folder) are returned unchanged.
    static func regenerate(_ draft: PluginDraft) throws -> PluginDraft {
        guard Set(draft.files.keys) == ["plugin.md", "mcp.json"],
              let mcpData = draft.files["mcp.json"] else {
            return draft
        }
        guard let servers = try? JSONDecoder().decode([String: MCPServerConfig].self, from: mcpData),
              servers.count == 1, let (serverName, config) = servers.first else {
            throw IPFError.invalidJSON("Draft mcp.json is not a single-server map")
        }
        switch config {
        case .stdio(let command, let args, _):
            var rebuilt = try buildGeneratedDraft(
                id: draft.manifest.id, serverName: serverName,
                command: command, args: args,
                secretValues: draft.secretValues, configValues: draft.configValues,
                source: draft.source)
            rebuilt.source = draft.source
            return rebuilt
        case .remote(let url, let rawHeaders, _):
            var rewritten: [String: String] = [:]
            for (headerName, template) in rawHeaders {
                var updated = template
                for key in PluginReferences.keychainKeys(in: template).union(PluginReferences.configKeys(in: template)) {
                    let target = draft.secretValues[key] != nil ? "${keychain:\(key)}" : "${config:\(key)}"
                    updated = updated
                        .replacingOccurrences(of: "${keychain:\(key)}", with: target)
                        .replacingOccurrences(of: "${config:\(key)}", with: target)
                }
                rewritten[headerName] = updated
            }
            var rebuilt = try buildGeneratedRemoteDraft(
                id: draft.manifest.id, serverName: serverName, url: url,
                headerTemplates: rewritten,
                secretValues: draft.secretValues, configValues: draft.configValues,
                source: draft.source)
            rebuilt.source = draft.source
            return rebuilt
        }
    }

    /// The generator for stdio wrap-and-lift plugin files: emits mcp.json (references only,
    /// never literal values) and a plugin.md manifest declaring the given secret/config keys.
    private static func buildGeneratedDraft(
        id: String, serverName: String, command: String, args: [String],
        secretValues: [String: String], configValues: [String: String], source: String
    ) throws -> PluginDraft {
        var refEnv: [String: String] = [:]
        for key in secretValues.keys { refEnv[key] = "${keychain:\(key)}" }
        for key in configValues.keys { refEnv[key] = "${config:\(key)}" }

        let mcpConfig = [serverName: MCPServerConfig.stdio(command: command, args: args,
                                                           env: refEnv.isEmpty ? nil : refEnv)]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let mcpData = try encoder.encode(mcpConfig)

        let binaryName = (command as NSString).lastPathComponent
        var yaml = """
        ---
        ipf: "1.0"
        id: \(id)
        name: \(yamlQuoted(serverName))
        version: 0.1.0
        description: \(yamlQuoted("Wrapped MCP server \(serverName)."))
        components:
          mcp: mcp.json
        requires:
          binaries:
            - name: \(yamlQuoted(binaryName))
        """
        yaml += manifestFieldsYAML(secretValues: secretValues, configValues: configValues, serverName: serverName)

        var pluginDraft = PluginDraft(
            manifest: try IPFManifest.parse(markdown: yaml, directoryName: id),
            files: ["plugin.md": Data(yaml.utf8), "mcp.json": mcpData],
            source: source)
        pluginDraft.secretValues = secretValues
        pluginDraft.configValues = configValues
        return pluginDraft
    }

    /// The generator for remote HTTP wrap-and-lift plugin files (#1105): emits mcp.json with
    /// `url`, `headers` (`${keychain:KEY}` / `${config:KEY}` templates), and `allowedKeys`,
    /// plus a `plugin.md` manifest with no binary requirement.
    private static func buildGeneratedRemoteDraft(
        id: String, serverName: String, url: URL, headerTemplates: [String: String],
        secretValues: [String: String], configValues: [String: String], source: String
    ) throws -> PluginDraft {
        var allowedKeys: Set<String> = []
        for template in headerTemplates.values {
            allowedKeys.formUnion(PluginReferences.keychainKeys(in: template))
        }
        let mcpConfig = [serverName: MCPServerConfig.remote(
            url: url, headers: headerTemplates, allowedKeys: allowedKeys
        )]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let mcpData = try encoder.encode(mcpConfig)

        var yaml = """
        ---
        ipf: "1.0"
        id: \(id)
        name: \(yamlQuoted(serverName))
        version: 0.1.0
        description: \(yamlQuoted("Remote MCP server \(serverName) (\(url.host() ?? url.absoluteString))."))
        components:
          mcp: mcp.json
        """
        yaml += manifestFieldsYAML(secretValues: secretValues, configValues: configValues, serverName: serverName)

        var pluginDraft = PluginDraft(
            manifest: try IPFManifest.parse(markdown: yaml, directoryName: id),
            files: ["plugin.md": Data(yaml.utf8), "mcp.json": mcpData],
            source: source)
        pluginDraft.secretValues = secretValues
        pluginDraft.configValues = configValues
        return pluginDraft
    }

    private static func manifestFieldsYAML(
        secretValues: [String: String], configValues: [String: String], serverName: String
    ) -> String {
        var yaml = ""
        if !configValues.isEmpty {
            yaml += "\nconfig:"
            for key in configValues.keys.sorted() {
                yaml += "\n  - key: \(key)"
            }
        }
        if !secretValues.isEmpty {
            yaml += "\nsecrets:"
            for key in secretValues.keys.sorted() {
                yaml += "\n  - key: \(key)\n    required: true"
            }
        }
        yaml += "\n---\n\n# \(serverName)\n\nGenerated by Iris.\n"
        return yaml
    }
}
