import Testing
import Foundation
@testable import IrisKit

@Suite("Legacy mcp_servers.json for the Plugins pane (#992)")
struct LegacyServersFileTests {
    private func tempDir() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("iris-legacy-\(UUID().uuidString)")
        return url
    }

    @Test("a missing file, and its directory, are created as an empty server map")
    func createsMissing() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("config/mcp_servers.json")
        #expect(LegacyServersFile.ensureExists(at: url))
        #expect(try HarnessConfigImporter.servers(at: url).isEmpty)
        let decoded = try JSONDecoder().decode([String: MCPServerConfig].self, from: Data(contentsOf: url))
        #expect(decoded.isEmpty)
    }

    @Test("an existing file is never touched")
    func leavesExisting() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("mcp_servers.json")
        let body = Data(#"{"fs":{"command":"npx"}}"#.utf8)
        try body.write(to: url)
        #expect(LegacyServersFile.ensureExists(at: url))
        #expect(try Data(contentsOf: url) == body)
    }

    @Test("where the file cannot be made it reports false instead of claiming it exists")
    func reportsFailure() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let blocker = dir.appendingPathComponent("config")
        try Data("x".utf8).write(to: blocker)   // a file where the directory has to go
        #expect(!LegacyServersFile.ensureExists(at: blocker.appendingPathComponent("mcp_servers.json")))
    }

    @Test("the pane explains what a plugin is and links the docs section that exists")
    func explanationAndDocs() throws {
        #expect(PluginsSettingsView.explanation.contains("plugin"))
        #expect(PluginsSettingsView.docsURL.absoluteString.hasSuffix("docs/features.md#plugins"))
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let features = try String(contentsOf: repo.appendingPathComponent("docs/features.md"), encoding: .utf8)
        #expect(features.contains("\n## Plugins\n"))
    }
}
