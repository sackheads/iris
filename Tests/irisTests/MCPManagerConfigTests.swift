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
}
