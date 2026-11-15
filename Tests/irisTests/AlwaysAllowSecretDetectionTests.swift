import Foundation
import Testing
@testable import IrisKit

@Suite("A credential-shaped command gets no Always Allow button, and is never saved (#1140)")
struct AlwaysAllowSecretDetectionTests {
    @MainActor
    private func rig() throws -> (state: AppState, root: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("iris-1140-\(UUID().uuidString)")
        let paths = IrisPaths(root: root.appendingPathComponent("iris-home"))
        try paths.ensureDirectories()
        let state = AppState(store: try ConversationStore.inMemory(),
                             tier2Provisioning: .provisioned, tier3Provisioning: .provisioned,
                             createIfEmpty: false, emitLaunchNotices: false)
        state.permissions = PermissionManager(paths: paths)
        return (state, root)
    }

    /// Raises the ask, waits for it to land in `pendingApprovals`, and resolves it with `.approve`
    /// so the call completes — mirrors `CommandPatternTests`' ladder helper.
    @MainActor
    private func ask(_ state: AppState, toolName: String = "run_command", details: String, conversationId: UUID)
        async throws -> ToolApprovalRequest {
        let askTask = Task { @MainActor in
            await state.requestApprovalSource(toolName: toolName, details: details, conversationId: conversationId, vibecopEnabled: false)
        }
        for _ in 0..<200 where !state.pendingApprovals.contains(where: { $0.conversationId == conversationId }) {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        let pending = try #require(state.pendingApprovals.first(where: { $0.conversationId == conversationId }))
        state.resolveApproval(id: pending.id, .approve)
        _ = try await value(of: askTask)
        return pending
    }

    @Test("a command with a bearer token offers no Always Allow button and carries the note")
    @MainActor
    func secretCommandSuppressesButton() async throws {
        let (state, root) = try rig()
        defer { try? FileManager.default.removeItem(at: root) }
        let conversationId = state.createNewConversation(isBackground: false, select: false)
        let pending = try await ask(state, details: "curl -H 'Authorization: Bearer ya29.a0AfH6SMBx7example0123456789abcdefghij' https://api.example.com",
                                    conversationId: conversationId)
        #expect(!pending.offersAlwaysAllow)
        #expect(pending.alwaysAllowRules.isEmpty)
        #expect(pending.secretDetectedNote == ToolApprovalRequest.secretDetectedMessage)
    }

    @Test("an ordinary command still offers Always Allow with no note")
    @MainActor
    func ordinaryCommandKeepsButton() async throws {
        let (state, root) = try rig()
        defer { try? FileManager.default.removeItem(at: root) }
        let conversationId = state.createNewConversation(isBackground: false, select: false)
        let pending = try await ask(state, details: "git status", conversationId: conversationId)
        #expect(pending.offersAlwaysAllow)
        #expect(!pending.alwaysAllowRules.isEmpty)
        #expect(pending.secretDetectedNote == nil)
    }

    @Test("approving a secret-shaped command once still runs it, but saves nothing to the allowlist")
    @MainActor
    func secretCommandRunsOnceButSavesNothing() async throws {
        let (state, root) = try rig()
        defer { try? FileManager.default.removeItem(at: root) }
        let conversationId = state.createNewConversation(isBackground: false, select: false)
        let details = "curl -H 'Authorization: Bearer ya29.a0AfH6SMBx7example0123456789abcdefghij' https://api.example.com"
        let askTask = Task { @MainActor in
            await state.requestApprovalSource(toolName: "run_command", details: details, conversationId: conversationId, vibecopEnabled: false)
        }
        for _ in 0..<200 where !state.pendingApprovals.contains(where: { $0.conversationId == conversationId }) {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        let pending = try #require(state.pendingApprovals.first(where: { $0.conversationId == conversationId }))
        state.resolveApproval(id: pending.id, .alwaysAllowGlobal)
        let source = try await value(of: askTask)
        #expect(source == .person, "the current call still ran, approved")
        #expect(state.permissions.match(toolName: "run_command", details: details, workspace: nil) == nil,
                "nothing was saved: a second identical call still prompts")
    }
}
