import Testing
@testable import IrisKit

@Suite("Keychain Plugin Secrets Tests", .serialized)
struct KeychainPluginSecretsTests {
    @Test("service-scoped secrets are isolated per service")
    func isolation() {
        let kc = KeychainManager.shared
        #expect(kc.usesInMemoryStore)   // guard: never touch the real Keychain in tests
        kc.replaceSecrets(["API_KEY": "abc"], service: KeychainManager.pluginService("plug-a"))
        kc.replaceSecrets(["API_KEY": "xyz"], service: KeychainManager.pluginService("plug-b"))

        #expect(kc.secrets(service: "iris.plugin.plug-a") == ["API_KEY": "abc"])
        #expect(kc.secrets(service: "iris.plugin.plug-b") == ["API_KEY": "xyz"])

        kc.deleteSecrets(service: "iris.plugin.plug-a")
        #expect(kc.secrets(service: "iris.plugin.plug-a").isEmpty)
        #expect(kc.secrets(service: "iris.plugin.plug-b") == ["API_KEY": "xyz"])
    }

    @Test("legacy loadSecrets/replaceSecrets keep working")
    func legacyAPI() {
        let kc = KeychainManager.shared
        kc.replaceSecrets(["gemini": "key1"])
        #expect(kc.loadSecrets() == ["gemini": "key1"])
        kc.replaceSecrets([:])
    }

    @Test("service name helpers")
    func names() {
        #expect(KeychainManager.pluginService("gemini-notebook") == "iris.plugin.gemini-notebook")
        #expect(KeychainManager.mcpFileService == "iris.mcp")
    }
}
