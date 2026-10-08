import Testing
@testable import iris

@Suite("Keychain service scope")
struct KeychainServiceScopeTests {
    @Test("the suffix is applied inside the manager, so callers keep base names")
    func suffixApplied() {
        let dev = KeychainManager(serviceSuffix: ".dev")
        let release = KeychainManager(serviceSuffix: "")
        dev.saveSecrets(["k": "dev"], service: "iris.mcp")
        #expect(dev.secrets(service: "iris.mcp") == ["k": "dev"])
        #expect(dev.resolvedService("iris.mcp") == "iris.mcp.dev")
        #expect(release.resolvedService("iris.mcp") == "iris.mcp")
    }

    @Test("storedServices lists base names for this suffix only")
    func listing() {
        let m = KeychainManager(serviceSuffix: ".dev")
        m.saveSecrets(["a": "1"], service: KeychainManager.pluginService("one"))
        m.saveSecrets(["b": "2"], service: KeychainManager.pluginService("two"))
        #expect(Set(m.storedServices(withPrefix: "iris.plugin.")) == ["iris.plugin.one", "iris.plugin.two"])
    }

    @Test("shared uses the process identity, dev under test")
    func sharedIsDev() {
        #expect(KeychainManager.shared.resolvedService("com.iris.secrets") == "com.iris.secrets.dev")
    }
}
