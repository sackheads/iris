import Testing
import Foundation
@testable import iris

@Suite("PermissionManager Tests")
struct PermissionManagerTests {

    @Test("isAllowed auto-approves read_file and write_file under ~/.iris, except writes into config/")
    func testAutoApproveIrisDir() {
        let memoryPath = IrisPaths.default.memoryDir.appendingPathComponent("SOUL.md").path
        let configPath = IrisPaths.default.configDir.appendingPathComponent("settings.json").path
        let outsidePath = "/Users/bnaylor/other_secret.txt"

        #expect(PermissionManager.shared.isAllowed(toolName: "read_file", details: memoryPath, workspace: nil))
        #expect(PermissionManager.shared.isAllowed(toolName: "write_file", details: memoryPath, workspace: nil))
        #expect(PermissionManager.shared.isAllowed(toolName: "read_file", details: configPath, workspace: nil))
        // config/ holds the file that grants permissions; see PermissionCarveOutTests.
        #expect(!PermissionManager.shared.isAllowed(toolName: "write_file", details: configPath, workspace: nil))
        #expect(!PermissionManager.shared.isAllowed(toolName: "read_file", details: outsidePath, workspace: nil))
        #expect(!PermissionManager.shared.isAllowed(toolName: "write_file", details: outsidePath, workspace: nil))
    }
}
