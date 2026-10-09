import Testing
import Foundation
@testable import IrisKit

@Suite("Plugin State Store Tests")
struct PluginStateTests {
    func tempPaths() throws -> IrisPaths {
        let dir = try tempDirectory(prefix: "iris-pst-test")
        let paths = IrisPaths(root: dir)
        try paths.ensureDirectories()
        return paths
    }

    @Test("pluginsDir and pluginsJSON resolve under root")
    func pathLayout() throws {
        let paths = try tempPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        #expect(paths.pluginsDir.path.hasSuffix("/plugins"))
        #expect(paths.pluginsJSON.path.hasSuffix("/config/plugins.json"))
        #expect(FileManager.default.fileExists(atPath: paths.pluginsDir.path))
    }

    @Test("round-trips state")
    func roundTrip() throws {
        let paths = try tempPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let store = PluginStateStore(paths: paths)
        var state = PluginState(source: "snippet")
        state.enabled = false
        state.installedVersion = "1.2.0"
        state.configValues["NLM_PROFILE"] = "work"
        store.save(["gemini-notebook": state])

        let loaded = store.load()
        #expect(loaded["gemini-notebook"] == state)
    }

    @Test("load returns empty when file absent")
    func emptyLoad() throws {
        let paths = try tempPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        #expect(PluginStateStore(paths: paths).load().isEmpty)
    }
}
