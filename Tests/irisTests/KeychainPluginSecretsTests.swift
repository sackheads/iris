import Testing
@testable import iris

@Suite("Keychain Plugin Secrets Tests", .serialized)
struct KeychainPluginSecretsTests {
    @Test("service-scoped secrets are isolated per service")
    func isolation() {
        let kc = KeychainManager.shared
        #expect(kc.usesInMemoryStore)   // guard: never touch the real Keychain in tests
        kc.saveSecrets(["API_KEY": "abc"], service: KeychainManager.pluginService("plug-a"))
        kc.saveSecrets(["API_KEY": "xyz"], service: KeychainManager.pluginService("plug-b"))

        #expect(kc.secrets(service: "iris.plugin.plug-a") == ["API_KEY": "abc"])
        #expect(kc.secrets(service: "iris.plugin.plug-b") == ["API_KEY": "xyz"])

        kc.deleteSecrets(service: "iris.plugin.plug-a")
        #expect(kc.secrets(service: "iris.plugin.plug-a").isEmpty)
        #expect(kc.secrets(service: "iris.plugin.plug-b") == ["API_KEY": "xyz"])
    }

    @Test("legacy loadSecrets/saveSecrets keep working")
    func legacyAPI() {
        let kc = KeychainManager.shared
        kc.saveSecrets(["gemini": "key1"])
        #expect(kc.loadSecrets() == ["gemini": "key1"])
        kc.saveSecrets([:])
    }

    @Test("service name helpers")
    func names() {
        #expect(KeychainManager.pluginService("gemini-notebook") == "iris.plugin.gemini-notebook")
        #expect(KeychainManager.mcpFileService == "iris.mcp")
    }
}
