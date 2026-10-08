import Security
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

    @Test("storedServicesOrThrow agrees with storedServices when the listing succeeds")
    func throwingListing() throws {
        let m = KeychainManager(serviceSuffix: ".dev")
        m.saveSecrets(["a": "1"], service: KeychainManager.pluginService("one"))
        #expect(try m.storedServicesOrThrow(withPrefix: "iris.plugin.") == ["iris.plugin.one"])
    }

    /// The listing's status, judged without a live Keychain call: nothing stored is an empty list,
    /// anything else that is not success throws rather than reading as "no plugins".
    @Test("a listing status other than success or not-found throws")
    func listingStatus() throws {
        #expect(try KeychainManager.listedServiceNames(status: errSecItemNotFound, result: nil) == [])
        let items: [[String: Any]] = [[kSecAttrService as String: "iris.plugin.x"]]
        #expect(try KeychainManager.listedServiceNames(status: errSecSuccess, result: items as AnyObject) == ["iris.plugin.x"])
        #expect(throws: KeychainManager.SecretsError.status(errSecInteractionNotAllowed)) {
            try KeychainManager.listedServiceNames(status: errSecInteractionNotAllowed, result: nil)
        }
    }

    @Test("shared uses the process identity, dev under test")
    func sharedIsDev() {
        #expect(KeychainManager.shared.resolvedService("com.iris.secrets") == "com.iris.secrets.dev")
    }
}
