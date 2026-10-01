import Testing
@testable import iris

@Suite("MCPManager Config Merge Tests")
struct MCPManagerConfigTests {
    @Test("legacy env keychain refs expand; plain values pass through")
    func legacyExpansion() {
        let config = MCPServerConfig(command: "/bin/x", args: [],
                                     env: ["A": "${keychain:PG}", "B": "plain"])
        let out = MCPManager.expandLegacyEnv(config, secrets: ["PG": "s3cret"])
        #expect(out.env?["A"] == "s3cret")
        #expect(out.env?["B"] == "plain")
    }

    @Test("unresolvable legacy ref leaves value untouched (back-compat)")
    func legacyUnresolvable() {
        let config = MCPServerConfig(command: "/bin/x", args: [], env: ["A": "${keychain:NOPE}"])
        let out = MCPManager.expandLegacyEnv(config, secrets: [:])
        #expect(out.env?["A"] == "${keychain:NOPE}")
    }

    @Test("merge: plugin keys are namespaced so they never collide with legacy")
    func merge() {
        let legacy = ["sqlite": MCPServerConfig(command: "/bin/a", args: [], env: nil)]
        let plugin = ["my-plug.echo": MCPServerConfig(command: "/bin/b", args: [], env: nil)]
        let merged = MCPManager.mergeConfigs(legacy: legacy, plugin: plugin)
        #expect(merged.count == 2)
        #expect(merged["sqlite"]?.command == "/bin/a")
        #expect(merged["my-plug.echo"]?.command == "/bin/b")
    }

    @Test("server env prepends login PATH and layers config env on top")
    func serverEnvironment() {
        // #228: MCP servers used to inherit the bare GUI environment unless the config had `env`,
        // so a server binary behind a pyenv/nvm/Homebrew shim would fail to start.
        let config = MCPServerConfig(command: "/bin/x", args: [], env: ["CUSTOM": "1"])
        let env = MCPManager.environment(for: config, base: ["PATH": "/tmp/unique-a", "HOME": "/Users/test"])
        let login = BinaryResolver.defaultSearchDirs()
        let path = env["PATH"]!.components(separatedBy: ":")
        #expect(Array(path.prefix(login.count)) == login)
        #expect(path.last == "/tmp/unique-a")
        #expect(env["CUSTOM"] == "1")
        #expect(env["HOME"] == "/Users/test")
    }

    @Test("server env applies login PATH even with no config env")
    func serverEnvironmentNoConfigEnv() {
        let config = MCPServerConfig(command: "/bin/x", args: [], env: nil)
        let env = MCPManager.environment(for: config, base: ["PATH": "/tmp/unique-a"])
        #expect(env["PATH"]!.hasPrefix(BinaryResolver.defaultSearchDirs().first!))
    }
}
