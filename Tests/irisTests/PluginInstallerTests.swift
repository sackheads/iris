import Testing
import Foundation
@testable import IrisKit

@Suite("Plugin Installer Tests", .serialized)
struct PluginInstallerTests {
    func tempPaths() throws -> IrisPaths {
        let paths = IrisPaths(root: try tempDirectory(prefix: "iris-installer"))
        try paths.ensureDirectories()
        return paths
    }

    func sourceDir(manifest: String) throws -> URL {
        let root = try tempDirectory(prefix: "iris-src")
        let dir = root.appendingPathComponent("neat-plug")
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
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let src = try sourceDir(manifest: manifest)
        defer { try? FileManager.default.removeItem(at: src.deletingLastPathComponent()) }
        let draft = try PluginInstaller(paths: paths).stage(directory: src, source: "local")
        #expect(draft.manifest.id == "neat-plug")
        #expect(draft.files.keys.contains("plugin.md"))
        #expect(draft.files.keys.contains("mcp.json"))
        #expect(!FileManager.default.fileExists(atPath: paths.pluginsDir.appendingPathComponent("neat-plug").path))
    }

    @Test("commit installs atomically: directory, keychain, state")
    func commit() throws {
        let paths = try tempPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let src = try sourceDir(manifest: manifest)
        defer { try? FileManager.default.removeItem(at: src.deletingLastPathComponent()) }
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
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let src = try sourceDir(manifest: manifest)
        defer { try? FileManager.default.removeItem(at: src.deletingLastPathComponent()) }
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
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let installer = PluginInstaller(paths: paths)

        let src1 = try sourceDir(manifest: manifest)
        defer { try? FileManager.default.removeItem(at: src1.deletingLastPathComponent()) }
        var draft1 = try installer.stage(directory: src1, source: "local")
        draft1.secretValues["API_KEY"] = "sk-123"
        try installer.commit(draft1)

        let manifestV2 = manifest.replacingOccurrences(of: "version: 2.0.0", with: "version: 3.0.0")
        let src2 = try sourceDir(manifest: manifestV2)
        defer { try? FileManager.default.removeItem(at: src2.deletingLastPathComponent()) }
        var draft2 = try installer.stage(directory: src2, source: "local")
        draft2.secretValues["API_KEY"] = "sk-123"
        try installer.commit(draft2, confirmedReplace: true)

        let installed = paths.pluginsDir.appendingPathComponent("neat-plug")
        let installedManifest = try String(
            contentsOf: installed.appendingPathComponent("plugin.md"), encoding: .utf8
        )
        #expect(installedManifest.contains("version: 3.0.0"))
        let state = PluginStateStore(paths: paths).load()["neat-plug"]
        #expect(state?.installedVersion == "3.0.0")
        KeychainManager.shared.deleteSecrets(service: "iris.plugin.neat-plug")
    }

    @Test("#1120: commit over an existing install refuses without confirmedReplace")
    func replaceWithoutConfirmationRefuses() throws {
        let paths = try tempPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let installer = PluginInstaller(paths: paths)
        defer { KeychainManager.shared.deleteSecrets(service: "iris.plugin.neat-plug") }

        let src1 = try sourceDir(manifest: manifest)
        defer { try? FileManager.default.removeItem(at: src1.deletingLastPathComponent()) }
        var draft1 = try installer.stage(directory: src1, source: "local")
        draft1.secretValues["API_KEY"] = "sk-123"
        try installer.commit(draft1)

        let src2 = try sourceDir(manifest: manifest)
        defer { try? FileManager.default.removeItem(at: src2.deletingLastPathComponent()) }
        let draft2 = try installer.stage(directory: src2, source: "local")
        #expect(throws: IPFError.alreadyInstalled("neat-plug")) {
            try installer.commit(draft2)
        }
        // Original install is untouched by the refused attempt.
        #expect(KeychainManager.shared.secrets(service: "iris.plugin.neat-plug")["API_KEY"] == "sk-123")
    }

    @Test("#1120: a confirmed replace clears a Keychain key the new manifest doesn't redeclare")
    func replaceClearsOrphanedSecret() throws {
        let paths = try tempPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let installer = PluginInstaller(paths: paths)
        defer { KeychainManager.shared.deleteSecrets(service: "iris.plugin.neat-plug") }

        let src1 = try sourceDir(manifest: manifest)
        defer { try? FileManager.default.removeItem(at: src1.deletingLastPathComponent()) }
        var draft1 = try installer.stage(directory: src1, source: "local")
        draft1.secretValues["API_KEY"] = "sk-old-secret"
        try installer.commit(draft1)

        // The new manifest for this same id declares no secrets at all -- simulating an
        // unrelated plugin that happens to collide on id (#1107's auto-derived ids).
        let manifestNoSecrets = """
        ---
        ipf: "1.0"
        id: neat-plug
        name: Neat Plug
        version: 2.0.0
        components:
          mcp: mcp.json
        ---
        Docs.
        """
        let src2 = try sourceDir(manifest: manifestNoSecrets)
        defer { try? FileManager.default.removeItem(at: src2.deletingLastPathComponent()) }
        let draft2 = try installer.stage(directory: src2, source: "local")
        try installer.commit(draft2, confirmedReplace: true)

        #expect(KeychainManager.shared.secrets(service: "iris.plugin.neat-plug")["API_KEY"] == nil)
        #expect(KeychainManager.shared.secrets(service: "iris.plugin.neat-plug").isEmpty)
    }

    @Test("#1120: a fresh (not-moved-aside) commit clears a stale pre-existing Keychain item")
    func freshInstallClearsStaleKeychainItem() throws {
        let paths = try tempPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let installer = PluginInstaller(paths: paths)
        defer { KeychainManager.shared.deleteSecrets(service: "iris.plugin.neat-plug") }

        // Simulate a stale item left behind by, e.g., an uninstall whose deleteSecrets failed,
        // or a plugin directory removed by hand outside Iris: the Keychain item exists even
        // though the plugin directory does not, so `commit` sees a fresh install (nothing to
        // move aside) but must still not let the old secret survive under this id.
        KeychainManager.shared.replaceSecrets(["API_KEY": "sk-stale"], service: "iris.plugin.neat-plug")

        let src = try sourceDir(manifest: manifest)
        defer { try? FileManager.default.removeItem(at: src.deletingLastPathComponent()) }
        let draft = try installer.stage(directory: src, source: "local")   // declares no secrets
        try installer.commit(draft)

        #expect(KeychainManager.shared.secrets(service: "iris.plugin.neat-plug")["API_KEY"] == nil)
        #expect(KeychainManager.shared.secrets(service: "iris.plugin.neat-plug").isEmpty)
    }

    @Test("commit skips empty-string secret values (no empty Keychain entries)")
    func skipsEmptySecrets() throws {
        let paths = try tempPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let src = try sourceDir(manifest: manifest)
        defer { try? FileManager.default.removeItem(at: src.deletingLastPathComponent()) }
        var draft = try PluginInstaller(paths: paths).stage(directory: src, source: "local")
        draft.secretValues["API_KEY"] = ""   // wizard-seeded placeholder, never filled in
        try PluginInstaller(paths: paths).commit(draft)
        #expect(KeychainManager.shared.secrets(service: "iris.plugin.neat-plug")["API_KEY"] == nil)
        KeychainManager.shared.deleteSecrets(service: "iris.plugin.neat-plug")
    }

    @Test(".DS_Store in the source directory is not staged")
    func skipsHiddenFiles() throws {
        let paths = try tempPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let src = try sourceDir(manifest: manifest)
        defer { try? FileManager.default.removeItem(at: src.deletingLastPathComponent()) }
        try Data().write(to: src.appendingPathComponent(".DS_Store"))
        let draft = try PluginInstaller(paths: paths).stage(directory: src, source: "local")
        #expect(draft.files[".DS_Store"] == nil)
    }

    @Test("commit of an invalid draft leaves no trace")
    func atomicity() throws {
        let paths = try tempPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let src = try sourceDir(manifest: manifest)
        defer { try? FileManager.default.removeItem(at: src.deletingLastPathComponent()) }
        var draft = try PluginInstaller(paths: paths).stage(directory: src, source: "local")
        draft.files["plugin.md"] = Data("garbage".utf8)   // corrupt it post-stage
        #expect(throws: (any Error).self) {
            try PluginInstaller(paths: paths).commit(draft)
        }
        #expect(!FileManager.default.fileExists(atPath: paths.pluginsDir.appendingPathComponent("neat-plug").path))
        #expect(PluginStateStore(paths: paths).load()["neat-plug"] == nil)
    }
}

/// #1120 (dev-2 review): a source scan pinning that every `PluginInstaller.commit` call site in
/// production code either handles a same-id collision itself or sits in a file that also handles
/// `IPFError.alreadyInstalled` (PluginsSettingsView's inline convert falls back to the install
/// wizard's own handling in a different file, so it is checked for the fallback, not the catch).
/// A future caller added without either is a silent replace reintroduced (#642: own suite, not
/// `@MainActor`, so the scan never holds the main thread a parallel run's other suites wait on).
@Suite("Plugin Installer commit call sites (#1120): source scan")
struct PluginInstallerCommitCallSiteScanTests {
    @Test("every production commit(...) call site handles .alreadyInstalled, or falls back to one that does")
    func everyCallerHandlesCollision() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/IrisKit")
        var callers: Set<String> = [], handlers: Set<String> = []
        for file in try FileManager.default.contentsOfDirectory(atPath: sources.path) where file.hasSuffix(".swift") {
            let text = try String(contentsOf: sources.appendingPathComponent(file), encoding: .utf8)
            for line in text.split(separator: "\n") {
                if line.contains(".commit(") && !line.contains("func commit") && !line.contains("CATransaction") {
                    callers.insert(file)
                }
                if line.contains("catch IPFError.alreadyInstalled") { handlers.insert(file) }
            }
        }
        #expect(callers == ["PluginsSettingsView.swift", "PluginInstallWizardView.swift"], "\(callers)")
        // PluginsSettingsView.swift calls commit from both commitAndStart (handles it directly)
        // and convertLegacyInline (falls back to the install wizard's dialog in the other file);
        // PluginInstallWizardView.swift is the file that actually shows that dialog.
        #expect(handlers == ["PluginsSettingsView.swift", "PluginInstallWizardView.swift"], "\(handlers)")
    }
}
