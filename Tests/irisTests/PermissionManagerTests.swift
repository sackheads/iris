import Testing
import Foundation
@testable import IrisKit

@Suite("PermissionManager Tests")
struct PermissionManagerTests {

    /// Over its own temp home rather than `.shared`: the "outside path is not allowed" lines used
    /// to pass only because the developer's real `permissions.json` had no such rule (#304).
    @Test("isAllowed auto-approves read_file and write_file under ~/.iris, except writes into config/")
    func testAutoApproveIrisDir() throws {
        let paths = IrisPaths(root: FileManager.default.temporaryDirectory
            .appendingPathComponent("iris-perm-\(UUID().uuidString)", isDirectory: true))
        try paths.ensureDirectories()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let manager = PermissionManager(paths: paths)
        let memoryPath = paths.memoryDir.appendingPathComponent("SOUL.md").path
        let configPath = paths.configDir.appendingPathComponent("settings.json").path
        let outsidePath = "/Users/someone/other_secret.txt"

        #expect(manager.isAllowed(toolName: "read_file", details: memoryPath, workspace: nil))
        #expect(manager.isAllowed(toolName: "write_file", details: memoryPath, workspace: nil))
        #expect(manager.isAllowed(toolName: "read_file", details: configPath, workspace: nil))
        // config/ holds the file that grants permissions; see PermissionCarveOutTests.
        #expect(!manager.isAllowed(toolName: "write_file", details: configPath, workspace: nil))
        #expect(!manager.isAllowed(toolName: "read_file", details: outsidePath, workspace: nil))
        #expect(!manager.isAllowed(toolName: "write_file", details: outsidePath, workspace: nil))
    }
}
