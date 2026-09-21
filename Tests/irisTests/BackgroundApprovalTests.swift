import Testing
import Foundation
@testable import iris

@MainActor
@Suite("Background conversation approvals fail closed")
struct BackgroundApprovalTests {
    @Test("a background conversation is denied without enqueuing, and the denial is recorded")
    func backgroundConversationDeniedAndRecorded() async {
        let app = AppState()
        let cid = app.createNewConversation(isBackground: true, select: false)

        let approved = await app.requestApproval(toolName: "run_command", details: "rm -rf x",
                                                 workspace: nil, conversationId: cid)
        #expect(approved == false)
        #expect(app.pendingApprovals.isEmpty)

        let denials = app.takeBackgroundDenials(for: cid)
        #expect(denials.count == 1)
        #expect(denials.first?.toolName == "run_command")
        #expect(denials.first?.details == "rm -rf x")
        #expect(app.takeBackgroundDenials(for: cid).isEmpty, "takeBackgroundDenials must clear on read")

        let notice = String(format: AppState.unattendedDenialNotice, "run_command")
        #expect(app.conversations.first(where: { $0.id == cid })?.messages.last?.role == .system)
        #expect(app.conversations.first(where: { $0.id == cid })?.messages.last?.content == notice)
    }

    @Test("a non-background conversation with autoApproveTools still auto-approves (unchanged path)")
    func nonBackgroundAutoApproveUnchanged() async {
        let app = AppState()
        app.autoApproveTools = true
        let cid = app.createNewConversation(isBackground: false, select: false)

        let approved = await app.requestApproval(toolName: "run_command", details: "echo hi",
                                                 workspace: nil, conversationId: cid)
        #expect(approved == true)
        #expect(app.pendingApprovals.isEmpty)
        #expect(app.takeBackgroundDenials(for: cid).isEmpty)
    }

    @Test("a background conversation is still denied even with autoApproveTools set (fail closed beats auto-approve)")
    func backgroundBeatsAutoApprove() async {
        let app = AppState()
        app.autoApproveTools = true
        let cid = app.createNewConversation(isBackground: true, select: false)

        let approved = await app.requestApproval(toolName: "run_command", details: "rm -rf x",
                                                 workspace: nil, conversationId: cid)
        #expect(approved == false)
        #expect(app.pendingApprovals.isEmpty)
        #expect(app.takeBackgroundDenials(for: cid).count == 1)
    }

    /// A throwaway workspace with its own `.iris/permissions.json`, which is the project half of
    /// the deterministic allowlist. Used instead of a path under the real `~/.iris`: the outcome
    /// then depends only on the rule this test wrote, not on what the machine running it happens
    /// to have approved before.
    private func workspace(allowing rules: [PermissionRule]) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("iris-bg-approval-\(UUID().uuidString)", isDirectory: true)
        let dir = root.appendingPathComponent(".iris", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONEncoder().encode(rules).write(to: dir.appendingPathComponent("permissions.json"))
        return root
    }

    @Test("a background conversation still runs a call the deterministic allowlist already permits")
    func backgroundAllowlistedCallRuns() async throws {
        let app = AppState()
        let cid = app.createNewConversation(isBackground: true, select: false)
        let notes = FileManager.default.temporaryDirectory
            .appendingPathComponent("iris-notes-\(UUID().uuidString).txt").path
        let root = try workspace(allowing: [PermissionRule(toolName: "read_file", details: notes)])
        defer { try? FileManager.default.removeItem(at: root) }

        let approved = await app.requestApproval(toolName: "read_file", details: notes,
                                                 workspace: root.path, conversationId: cid)
        #expect(approved == true)
        #expect(app.pendingApprovals.isEmpty)
        #expect(app.takeBackgroundDenials(for: cid).isEmpty, "an allowlisted call must not be recorded as a denial")
        #expect(app.conversations.first(where: { $0.id == cid })?.messages.isEmpty == true,
                "an allowlisted call must not append a system notice")
    }

    @Test("the same call, not allowlisted, is still denied and recorded")
    func backgroundNonAllowlistedCallDenied() async throws {
        let app = AppState()
        let cid = app.createNewConversation(isBackground: true, select: false)
        // Same shape of path, same workspace, one rule short: the only difference from the test
        // above is that nothing permits this file.
        let outsidePath = FileManager.default.temporaryDirectory
            .appendingPathComponent("iris-secret-\(UUID().uuidString).txt").path
        let root = try workspace(allowing: [])
        defer { try? FileManager.default.removeItem(at: root) }

        let approved = await app.requestApproval(toolName: "read_file", details: outsidePath,
                                                 workspace: root.path, conversationId: cid)
        #expect(approved == false)
        #expect(app.pendingApprovals.isEmpty)
        #expect(app.takeBackgroundDenials(for: cid).count == 1)
    }
}
