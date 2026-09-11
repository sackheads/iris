import Testing
import Foundation
@testable import iris

@Suite("Plugin Installer Tests", .serialized)
struct PluginInstallerTests {
    func tempPaths() throws -> IrisPaths {
        let paths = IrisPaths(root: FileManager.default.temporaryDirectory
            .appendingPathComponent("iris-installer-\(UUID().uuidString)"))
        try paths.ensureDirectories()
        return paths
    }

    func sourceDir(manifest: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("iris-src-\(UUID().uuidString)/neat-plug")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try manifest.write(to: dir.appendingPathComponent("plugin.md"), atomically: true, encoding: .utf8)
        try #"{ "s": { "command": "/bin/echo", "args": [] } }"#
            .write(to: dir.appendingPathComponent("mcp.json"), atomically: true, encoding: .utf8)
        return dir
    }

    let manifest = """
    ---
    ipf: "1.0"
    id: neat-plug
    name: Neat Plug
    version: 2.0.0
    components:
      mcp: mcp.json
    secrets:
      - key: API_KEY
        required: true
    ---
    Docs.
    """

    @Test("stage reads a local directory into a draft without installing")
    func stage() throws {
        let paths = try tempPaths()
        let src = try sourceDir(manifest: manifest)
        let draft = try PluginInstaller(paths: paths).stage(directory: src, source: "local")
        #expect(draft.manifest.id == "neat-plug")
        #expect(draft.files.keys.contains("plugin.md"))
        #expect(draft.files.keys.contains("mcp.json"))
        #expect(!FileManager.default.fileExists(atPath: paths.pluginsDir.appendingPathComponent("neat-plug").path))
    }

    @Test("commit installs atomically: directory, keychain, state")
    func commit() throws {
        let paths = try tempPaths()
        let src = try sourceDir(manifest: manifest)
        var draft = try PluginInstaller(paths: paths).stage(directory: src, source: "local")
        draft.secretValues["API_KEY"] = "sk-123"
        try PluginInstaller(paths: paths).commit(draft)

        let installed = paths.pluginsDir.appendingPathComponent("neat-plug")
        #expect(FileManager.default.fileExists(atPath: installed.appendingPathComponent("plugin.md").path))
        #expect(KeychainManager.shared.secrets(service: "iris.plugin.neat-plug")["API_KEY"] == "sk-123")
        let state = PluginStateStore(paths: paths).load()["neat-plug"]
        #expect(state?.source == "local")
        #expect(state?.installedVersion == "2.0.0")
        KeychainManager.shared.deleteSecrets(service: "iris.plugin.neat-plug")
    }

    @Test("uninstall removes directory, keychain service, and state")
    func uninstall() async throws {
        let paths = try tempPaths()
        let src = try sourceDir(manifest: manifest)
        var draft = try PluginInstaller(paths: paths).stage(directory: src, source: "local")
        draft.secretValues["API_KEY"] = "sk-123"
        let installer = PluginInstaller(paths: paths)
        try installer.commit(draft)
        try await installer.uninstall(id: "neat-plug")

        #expect(!FileManager.default.fileExists(atPath: paths.pluginsDir.appendingPathComponent("neat-plug").path))
        #expect(KeychainManager.shared.secrets(service: "iris.plugin.neat-plug").isEmpty)
        #expect(PluginStateStore(paths: paths).load()["neat-plug"] == nil)
    }

    @Test("reinstall over an existing install succeeds and replaces content")
    func reinstall() throws {
        let paths = try tempPaths()
        let installer = PluginInstaller(paths: paths)

        let src1 = try sourceDir(manifest: manifest)
        var draft1 = try installer.stage(directory: src1, source: "local")
        draft1.secretValues["API_KEY"] = "sk-123"
        try installer.commit(draft1)

        let manifestV2 = manifest.replacingOccurrences(of: "version: 2.0.0", with: "version: 3.0.0")
        let src2 = try sourceDir(manifest: manifestV2)
        var draft2 = try installer.stage(directory: src2, source: "local")
        draft2.secretValues["API_KEY"] = "sk-123"
        try installer.commit(draft2)

        let installed = paths.pluginsDir.appendingPathComponent("neat-plug")
        let installedManifest = try String(
            contentsOf: installed.appendingPathComponent("plugin.md"), encoding: .utf8
        )
        #expect(installedManifest.contains("version: 3.0.0"))
        let state = PluginStateStore(paths: paths).load()["neat-plug"]
        #expect(state?.installedVersion == "3.0.0")
        KeychainManager.shared.deleteSecrets(service: "iris.plugin.neat-plug")
    }

    @Test("commit skips empty-string secret values (no empty Keychain entries)")
    func skipsEmptySecrets() throws {
        let paths = try tempPaths()
        let src = try sourceDir(manifest: manifest)
        var draft = try PluginInstaller(paths: paths).stage(directory: src, source: "local")
        draft.secretValues["API_KEY"] = ""   // wizard-seeded placeholder, never filled in
        try PluginInstaller(paths: paths).commit(draft)
        #expect(KeychainManager.shared.secrets(service: "iris.plugin.neat-plug")["API_KEY"] == nil)
        KeychainManager.shared.deleteSecrets(service: "iris.plugin.neat-plug")
    }

    @Test(".DS_Store in the source directory is not staged")
    func skipsHiddenFiles() throws {
        let paths = try tempPaths()
        let src = try sourceDir(manifest: manifest)
        try Data().write(to: src.appendingPathComponent(".DS_Store"))
        let draft = try PluginInstaller(paths: paths).stage(directory: src, source: "local")
        #expect(draft.files[".DS_Store"] == nil)
    }

    @Test("commit of an invalid draft leaves no trace")
    func atomicity() throws {
        let paths = try tempPaths()
        let src = try sourceDir(manifest: manifest)
        var draft = try PluginInstaller(paths: paths).stage(directory: src, source: "local")
        draft.files["plugin.md"] = Data("garbage".utf8)   // corrupt it post-stage
        #expect(throws: (any Error).self) {
            try PluginInstaller(paths: paths).commit(draft)
        }
        #expect(!FileManager.default.fileExists(atPath: paths.pluginsDir.appendingPathComponent("neat-plug").path))
        #expect(PluginStateStore(paths: paths).load()["neat-plug"] == nil)
    }
}
