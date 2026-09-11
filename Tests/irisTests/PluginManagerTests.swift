import Testing
import Foundation
@testable import iris

@Suite("Plugin Manager Tests", .serialized)
struct PluginManagerTests {
    /// Builds a temp ~/.iris with one installed plugin and returns (paths, pluginDir).
    func fixture(manifest: String, id: String, mcpJSON: String? = nil) throws -> (IrisPaths, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("iris-pm-test-\(UUID().uuidString)")
        let paths = IrisPaths(root: root)
        try paths.ensureDirectories()
        let dir = paths.pluginsDir.appendingPathComponent(id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try manifest.write(to: dir.appendingPathComponent("plugin.md"), atomically: true, encoding: .utf8)
        if let mcpJSON {
            try mcpJSON.write(to: dir.appendingPathComponent("mcp.json"), atomically: true, encoding: .utf8)
        }
        return (paths, dir)
    }

    let simpleManifest = """
    ---
    ipf: "1.0"
    id: echo-plug
    name: Echo Plug
    version: 1.0.0
    components:
      mcp: mcp.json
    secrets:
      - key: TOKEN
        required: true
    ---
    """
    // /bin/echo exists everywhere; env value carries a keychain ref
    let mcpJSON = """
    { "echo": { "command": "/bin/echo", "args": ["hi"], "env": { "TOKEN": "${keychain:TOKEN}" } } }
    """

    @Test("loads a valid plugin and resolves references")
    func loadsAndResolves() async throws {
        let (paths, _) = try fixture(manifest: simpleManifest, id: "echo-plug", mcpJSON: mcpJSON)
        KeychainManager.shared.saveSecrets(["TOKEN": "tok123"], service: KeychainManager.pluginService("echo-plug"))
        defer { KeychainManager.shared.deleteSecrets(service: KeychainManager.pluginService("echo-plug")) }

        let pm = PluginManager(paths: paths)
        await pm.loadAll()

        let plugins = await pm.plugins()
        #expect(plugins.count == 1)
        #expect(plugins[0].status == .ok)

        let configs = await pm.mcpConfigs()
        #expect(configs["echo-plug.echo"]?.command == "/bin/echo")
        #expect(configs["echo-plug.echo"]?.env?["TOKEN"] == "tok123")
    }

    @Test("missing required secret means needsConfig, not failure")
    func missingSecret() async throws {
        let (paths, _) = try fixture(manifest: simpleManifest, id: "echo-plug", mcpJSON: mcpJSON)
        let pm = PluginManager(paths: paths)
        await pm.loadAll()

        let plugins = await pm.plugins()
        guard case .needsConfig = plugins[0].status else {
            Issue.record("expected needsConfig, got \(plugins[0].status)")
            return
        }
        #expect(await pm.mcpConfigs().isEmpty)
    }

    @Test("broken manifest isolates to that plugin")
    func brokenIsolated() async throws {
        let (paths, _) = try fixture(manifest: "not a manifest", id: "broken")
        let dir2 = paths.pluginsDir.appendingPathComponent("good-one")
        try FileManager.default.createDirectory(at: dir2, withIntermediateDirectories: true)
        try "---\nipf: \"1.0\"\nid: good-one\nname: Good\nversion: 1.0.0\n---\n"
            .write(to: dir2.appendingPathComponent("plugin.md"), atomically: true, encoding: .utf8)

        let pm = PluginManager(paths: paths)
        await pm.loadAll()
        let plugins = await pm.plugins()
        #expect(plugins.count == 2)
        #expect(plugins.first { $0.directory.lastPathComponent == "good-one" }?.status == .ok)
        guard case .failed = plugins.first(where: { $0.directory.lastPathComponent == "broken" })?.status else {
            Issue.record("expected failed status for broken plugin")
            return
        }
    }

    @Test("disabled plugin contributes nothing")
    func disabled() async throws {
        let (paths, _) = try fixture(manifest: simpleManifest, id: "echo-plug", mcpJSON: mcpJSON)
        KeychainManager.shared.saveSecrets(["TOKEN": "t"], service: KeychainManager.pluginService("echo-plug"))
        defer { KeychainManager.shared.deleteSecrets(service: KeychainManager.pluginService("echo-plug")) }

        let pm = PluginManager(paths: paths)
        await pm.loadAll()
        await pm.setEnabled("echo-plug", enabled: false)
        #expect(await pm.mcpConfigs().isEmpty)
        #expect(await pm.plugins()[0].status == .disabled)
    }

    @Test("skill roots and rule files come from enabled plugins")
    func skillAndRuleRoots() async throws {
        let manifest = """
        ---
        ipf: "1.0"
        id: skills-plug
        name: Skills Plug
        version: 1.0.0
        components:
          skills: skills/
          rules: rules/
        ---
        """
        let (paths, dir) = try fixture(manifest: manifest, id: "skills-plug")
        let skillDir = dir.appendingPathComponent("skills/my-skill")
        try FileManager.default.createDirectory(at: skillDir, withIntermediateDirectories: true)
        try "---\nname: my-skill\ndescription: Does things.\n---\n"
            .write(to: skillDir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        let rulesDir = dir.appendingPathComponent("rules")
        try FileManager.default.createDirectory(at: rulesDir, withIntermediateDirectories: true)
        try "Always be excellent.".write(to: rulesDir.appendingPathComponent("conduct.md"), atomically: true, encoding: .utf8)

        let pm = PluginManager(paths: paths)
        await pm.loadAll()
        #expect(await pm.skillRoots() == [dir.appendingPathComponent("skills")])
        #expect(await pm.ruleFiles().map(\.lastPathComponent) == ["conduct.md"])
    }

    @Test("undeclared keychain ref fails")
    func undeclaredSecretFails() async throws {
        let manifest = """
        ---
        ipf: "1.0"
        id: echo-plug
        name: Echo Plug
        version: 1.0.0
        components:
          mcp: mcp.json
        ---
        """
        let mcpJSON = """
        { "echo": { "command": "/bin/echo", "args": ["hi"], "env": { "TOKEN": "${keychain:NOT_DECLARED}" } } }
        """
        let (paths, _) = try fixture(manifest: manifest, id: "echo-plug", mcpJSON: mcpJSON)
        let pm = PluginManager(paths: paths)
        await pm.loadAll()

        let plugins = await pm.plugins()
        guard case .failed(let message) = plugins[0].status else {
            Issue.record("expected failed, got \(plugins[0].status)")
            return
        }
        #expect(message.contains("NOT_DECLARED"))
    }

    @Test("pathological directory name isolates to failed, no crash")
    func pathologicalDirectoryName() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("iris-pm-test-\(UUID().uuidString)")
        let paths = IrisPaths(root: root)
        try paths.ensureDirectories()

        let badDir = paths.pluginsDir.appendingPathComponent("my: plugin")
        try FileManager.default.createDirectory(at: badDir, withIntermediateDirectories: true)
        try "garbage, not a manifest".write(
            to: badDir.appendingPathComponent("plugin.md"), atomically: true, encoding: .utf8)

        let goodDir = paths.pluginsDir.appendingPathComponent("good-one")
        try FileManager.default.createDirectory(at: goodDir, withIntermediateDirectories: true)
        try "---\nipf: \"1.0\"\nid: good-one\nname: Good\nversion: 1.0.0\n---\n"
            .write(to: goodDir.appendingPathComponent("plugin.md"), atomically: true, encoding: .utf8)

        let pm = PluginManager(paths: paths)
        await pm.loadAll()
        let plugins = await pm.plugins()
        #expect(plugins.count == 2)
        #expect(plugins.first { $0.directory.lastPathComponent == "good-one" }?.status == .ok)
        guard case .failed = plugins.first(where: { $0.directory.lastPathComponent == "my: plugin" })?.status else {
            Issue.record("expected failed status for pathological plugin, got \(String(describing: plugins.map(\.status)))")
            return
        }
    }

    @Test("declared but missing mcp.json is needsConfig")
    func declaredMcpMissingFile() async throws {
        let manifest = """
        ---
        ipf: "1.0"
        id: mcp-missing
        name: MCP Missing
        version: 1.0.0
        components:
          mcp: mcp.json
        ---
        """
        let (paths, _) = try fixture(manifest: manifest, id: "mcp-missing")
        let pm = PluginManager(paths: paths)
        await pm.loadAll()

        let plugins = await pm.plugins()
        guard case .needsConfig(let message) = plugins[0].status else {
            Issue.record("expected needsConfig, got \(plugins[0].status)")
            return
        }
        #expect(message.contains("mcp.json"))
    }
}
