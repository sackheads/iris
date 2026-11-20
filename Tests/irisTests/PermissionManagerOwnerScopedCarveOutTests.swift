import Foundation
import Testing
@testable import IrisKit

/// #974 Task 9, R3: `PermissionManager.match`'s `~/.iris` carve-out used to allow a read for
/// anyone not guest-origin -- including a non-owner, non-guest-origin binding (#1216's class: a
/// scoped subagent/profile). It is owner-only now. This drives a real engine turn (`autoApproveTools`
/// off, so the call actually reaches `AppState.requestApprovalSource`'s fast path), not just a
/// direct `PermissionManager.match` call -- #1217's lesson is that a direct-call test can pass
/// while production serves the decision through a route the test never drove.
@MainActor
@Suite("The ~/.iris read carve-out is owner-only through a real engine turn (#974 Task 9, R3)", .timeLimit(.minutes(1)))
struct PermissionManagerOwnerScopedCarveOutTests {
    private struct World {
        var state: AppState
        var paths: IrisPaths
        var root: URL
    }

    private func world() throws -> World {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("iris-974-task9-\(UUID().uuidString)")
        let paths = IrisPaths(root: root.appendingPathComponent("iris-home"))
        try paths.ensureDirectories()
        try "owner's own memory".write(to: paths.memoryMd, atomically: true, encoding: .utf8)
        let state = AppState(store: try ConversationStore.inMemory(), tier2Provisioning: .provisioned,
                             tier3Provisioning: .provisioned, createIfEmpty: false, emitLaunchNotices: false)
        state.permissions = PermissionManager(paths: paths)
        state.hostLookupOverride = {
            ReadOnlyCommand.HostLookup(path: "/bin:/usr/bin", cwd: "/tmp", home: root.path,
                                       isExecutable: { FileManager.default.isExecutableFile(atPath: $0) })
        }
        return World(state: state, paths: paths, root: root)
    }

    private func session(_ state: AppState, binding: AccessBinding) -> (UUID, String) {
        let callId = "c1"
        let call = FunctionCall(name: "read_file", args: ["path": .string(state.permissions.paths.memoryMd.path)], id: callId)
        let script: [[ScriptedStreamClient.Step]] = [
            [.event(.functionCall(call)), .event(.done(finishReason: "tool_use"))],
            [.event(.textDelta("done")), .event(.done(finishReason: nil))],
        ]
        let id = UUID()
        state.createNewConversation(id: id)
        state.selectedConversationId = id
        let engine = IrisEngine(state: state, tier: .medium, principal: .main, client: ScriptedStreamClient(script),
                                retryDelays: [], streamResponses: true, protectionEnabled: false, sessionPeerCount: 0,
                                binding: binding)
        state.installEngine(engine)
        return (id, callId)
    }

    private func finished(_ state: AppState, _ id: UUID) -> Bool {
        (state.conversations.first { $0.id == id }?.history ?? []).contains { $0.role == "model" && $0.parts.contains { $0.text == "done" } }
    }

    private func toolResultText(_ state: AppState, _ id: UUID, callId: String) -> String? {
        for content in state.conversations.first(where: { $0.id == id })?.history ?? [] {
            for part in content.parts {
                if part.functionResponse?.id == callId { return part.functionResponse?.response["result"]?.stringValue }
            }
        }
        return nil
    }

    /// Resolves the one pending approval this turn produces, if the carve-out does not auto-approve
    /// it (the non-owner case) -- denying it, so the test can distinguish "auto-approved by the
    /// carve-out" (no prompt, content comes back) from "the carve-out no longer applies, a human
    /// would have to say yes" (prompted, denied, no content).
    private func runAndResolve(_ state: AppState, _ id: UUID, approve: Bool) async -> Bool {
        state.sendMessage("go")
        var prompted = false
        for _ in 0..<2_000 {
            if let request = state.pendingApprovals.first(where: { $0.conversationId == id }) {
                prompted = true
                state.resolveApproval(id: request.id, approve ? .approve : .deny)
                break
            }
            if finished(state, id) { break }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        for _ in 0..<2_000 where !finished(state, id) {
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        return prompted
    }

    @Test("a non-owner binding's read of ~/.iris is not auto-approved by the carve-out -- it reaches a human")
    func nonOwnerReachesAHuman() async throws {
        let w = try world()
        defer { try? FileManager.default.removeItem(at: w.root) }
        let binding = AccessBinding(profile: AccessProfile(fsRoots: []), principal: .main, isOwner: false)
        let (id, callId) = session(w.state, binding: binding)
        let prompted = await runAndResolve(w.state, id, approve: false)
        #expect(prompted, "a non-owner's ~/.iris read must not be waved through by the carve-out")
        let result = try #require(toolResultText(w.state, id, callId: callId))
        #expect(!result.contains("owner's own memory"), Comment(rawValue: result))
    }

    @Test("an owner binding's read of ~/.iris is still auto-approved by the carve-out, no prompt")
    func ownerStillAutoApproved() async throws {
        let w = try world()
        defer { try? FileManager.default.removeItem(at: w.root) }
        let binding = AccessBinding(profile: .owner, principal: .main, isOwner: true)
        let (id, callId) = session(w.state, binding: binding)
        let prompted = await runAndResolve(w.state, id, approve: true)
        #expect(!prompted, "the owner's own ~/.iris read must still be waved through, unchanged")
        let result = try #require(toolResultText(w.state, id, callId: callId))
        #expect(result.contains("owner's own memory"), Comment(rawValue: result))
    }
}
