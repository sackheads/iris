import Testing
import Foundation
@testable import iris

/// The `~/.iris` auto-allow, and what it must never reach (#187).
///
/// `permissions.json` lives under `config/` and `isAllowed` re-reads it on every call, so a write
/// the carve-out granted would grant everything else on the next call — an unattended run could
/// allowlist `run_command` for itself. Two rules close that: the carve-out never covers a write
/// into `config/` for anyone, and for a background run it never covers a write at all.
///
/// Every path here is under a temp `IrisPaths`, so the outcome depends only on what the test
/// wrote — never on what the machine running it happens to have approved before.
@MainActor
@Suite("The ~/.iris permission carve-out")
struct PermissionCarveOutTests {

    private func tempPaths() throws -> IrisPaths {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("iris-perms-\(UUID().uuidString)", isDirectory: true)
        let paths = IrisPaths(root: root)
        try paths.ensureDirectories()
        return paths
    }

    private func write(_ rules: [PermissionRule], to paths: IrisPaths) throws {
        try JSONEncoder().encode(rules).write(to: paths.permissionsJSON)
    }

    @Test("a write into config/ is never auto-allowed, for any caller")
    func configWritesAreNeverAutoAllowed() throws {
        let paths = try tempPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let permissions = PermissionManager(paths: paths)

        for target in [paths.permissionsJSON, paths.pluginsJSON, paths.settingsJSON,
                       paths.configDir.appendingPathComponent("hooks.json")] {
            #expect(permissions.isAllowed(toolName: "write_file", details: target.path, workspace: nil) == false,
                    "the carve-out must not grant a write to \(target.lastPathComponent)")
        }
        // A tilde-free traversal back into config/ is the same write.
        let traversal = paths.memoryDir.appendingPathComponent("../config/permissions.json").path
        #expect(permissions.isAllowed(toolName: "write_file", details: traversal, workspace: nil) == false)
    }

    @Test("reading config/ is still auto-allowed, and so is writing elsewhere under ~/.iris")
    func readsAndNonConfigWritesAreUnaffected() throws {
        let paths = try tempPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let permissions = PermissionManager(paths: paths)

        #expect(permissions.isAllowed(toolName: "read_file", details: paths.permissionsJSON.path, workspace: nil))
        #expect(permissions.isAllowed(toolName: "write_file", details: paths.memoryMd.path, workspace: nil))
    }

    @Test("a background run gets no write carve-out at all, but still reads its own memory")
    func backgroundGetsNoWriteCarveOut() throws {
        let paths = try tempPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let permissions = PermissionManager(paths: paths)

        #expect(permissions.isAllowed(toolName: "write_file", details: paths.memoryMd.path,
                                      workspace: nil, isBackground: true) == false)
        #expect(permissions.isAllowed(toolName: "read_file", details: paths.memoryMd.path,
                                      workspace: nil, isBackground: true))
    }

    @Test("an explicit rule can allow a background write, but never one into config/")
    func explicitRulesForBackgroundWrites() throws {
        let paths = try tempPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        try write([PermissionRule(toolName: "write_file", details: paths.memoryMd.path),
                   PermissionRule(toolName: "write_file", details: paths.permissionsJSON.path)],
                  to: paths)
        let permissions = PermissionManager(paths: paths)

        #expect(permissions.isAllowed(toolName: "write_file", details: paths.memoryMd.path,
                                      workspace: nil, isBackground: true),
                "an explicit rule is a decision a person made; it still holds unattended")
        #expect(permissions.isAllowed(toolName: "write_file", details: paths.permissionsJSON.path,
                                      workspace: nil, isBackground: true) == false,
                "no rule may hand an unattended run the file that grants permissions")
        #expect(permissions.isAllowed(toolName: "write_file", details: paths.permissionsJSON.path,
                                      workspace: nil),
                "a foreground write the user explicitly allowed is unchanged")
    }

    @Test("a background run's write to permissions.json is denied and recorded")
    func backgroundWriteToPermissionsIsDeniedAndRecorded() async throws {
        let paths = try tempPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let app = AppState()
        app.permissions = PermissionManager(paths: paths)
        let cid = app.createNewConversation(isBackground: true, select: false)

        let approved = await app.requestApproval(toolName: "write_file", details: paths.permissionsJSON.path,
                                                 workspace: nil, conversationId: cid)
        #expect(approved == false)
        #expect(app.pendingApprovals.isEmpty)
        let denials = app.takeBackgroundDenials(for: cid)
        #expect(denials.count == 1)
        #expect(denials.first?.toolName == "write_file")
        let notice = String(format: AppState.unattendedDenialNotice, "write_file")
        #expect(app.conversations.first(where: { $0.id == cid })?.messages.last?.content == notice)
    }

    @Test("a background run still reads its own memory without an approval")
    func backgroundReadOfMemoryIsAllowed() async throws {
        let paths = try tempPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let app = AppState()
        app.permissions = PermissionManager(paths: paths)
        let cid = app.createNewConversation(isBackground: true, select: false)

        let approved = await app.requestApproval(toolName: "read_file",
                                                 details: paths.memoryDir.appendingPathComponent("USER.md").path,
                                                 workspace: nil, conversationId: cid)
        #expect(approved)
        #expect(app.takeBackgroundDenials(for: cid).isEmpty)
        #expect(app.conversations.first(where: { $0.id == cid })?.messages.isEmpty == true)
    }
}
