import Testing
@testable import iris

@Suite("Plugin Reference Expansion Tests")
struct PluginReferencesTests {
    @Test("expands keychain and config refs")
    func expands() throws {
        let out = try PluginReferences.expand(
            "pg://u:${keychain:DB_PASS}@host/${config:DB_NAME}",
            config: ["DB_NAME": "iris"],
            secrets: ["DB_PASS": "s3cret"]
        )
        #expect(out == "pg://u:s3cret@host/iris")
    }

    @Test("passes through strings with no refs")
    func passthrough() throws {
        #expect(try PluginReferences.expand("plain $HOME ${notaref}", config: [:], secrets: [:])
                == "plain $HOME ${notaref}")
    }

    @Test("throws on unresolvable reference")
    func unresolvable() {
        #expect(throws: IPFError.unknownReference("${keychain:MISSING}")) {
            _ = try PluginReferences.expand("${keychain:MISSING}", config: [:], secrets: [:])
        }
    }

    @Test("extracts referenced keys")
    func extraction() {
        let s = "${keychain:A} ${config:B} ${keychain:C}"
        #expect(PluginReferences.keychainKeys(in: s) == ["A", "C"])
        #expect(PluginReferences.configKeys(in: s) == ["B"])
    }
}
