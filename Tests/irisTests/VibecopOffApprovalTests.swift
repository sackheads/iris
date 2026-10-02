import Testing
import Foundation
@testable import iris

/// #334: a disabled Vibecop is no pre-screen, never an approval. With it off, which is the
/// default, an attended gated call that the allowlist does not already permit reaches the user
/// prompt exactly as an ESCALATE would.
///
/// Every test passes `vibecopEnabled:` explicitly and injects its own `PermissionManager`, so
/// nothing here reads or writes `ConfigManager.shared` or the real allowlist (invariant 7).
@MainActor
@Suite("Vibecop off asks the user (#334)")
struct VibecopOffApprovalTests {

    private func app() throws -> (AppState, URL) {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("iris-vibecop-off-\(UUID().uuidString)", isDirectory: true)
        let state = AppState(store: try ConversationStore.inMemory(),
                             tier2Provisioning: .provisioned, tier3Provisioning: .provisioned,
                             createIfEmpty: false, emitLaunchNotices: false)
        state.permissions = PermissionManager(paths: IrisPaths(root: home))
        return (state, home)
    }

    /// Bounded: waits up to ~2s for the call to reach the queue, then answers it. If it never
    /// queued, anything that arrives late is denied before the task is awaited, so a regression
    /// fails the test rather than hanging it.
    private func ask(_ state: AppState, tool: String, details: String, in cid: UUID,
                     answer: AppState.ApprovalResolution) async -> (queued: Bool, approved: Bool) {
        let call = Task { @MainActor in
            await state.requestApproval(toolName: tool, details: details, workspace: nil,
                                        conversationId: cid, vibecopEnabled: false)
        }
        var queued = false
        for _ in 0..<400 {
            if state.pendingApprovals.contains(where: { $0.conversationId == cid }) { queued = true; break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        if queued {
            #expect(state.pendingApprovals.first?.toolName == tool)
            #expect(state.pendingApprovals.first?.details == details)
            state.resolveApproval(answer)
        } else {
            state.denyPendingApprovals(for: cid)
        }
        return (queued, await call.value)
    }

    @Test("with Vibecop off, each gated tool reaches the prompt; approve and deny both resolve",
          arguments: ["run_command", "write_file", "read_file"])
    func gatedToolAsks(tool: String) async throws {
        let (state, home) = try app()
        defer { try? FileManager.default.removeItem(at: home) }
        let cid = state.createNewConversation(isBackground: false, select: false)
        let details = tool == "run_command"
            ? "true --never-run-\(UUID().uuidString)"
            : FileManager.default.temporaryDirectory.appendingPathComponent("iris-334-\(UUID().uuidString)").path

        let approved = await ask(state, tool: tool, details: details, in: cid, answer: .approve)
        #expect(approved.queued, "\(tool) must reach the user prompt, not be approved by a disabled Vibecop")
        #expect(approved.approved == true)

        let denied = await ask(state, tool: tool, details: details, in: cid, answer: .deny)
        #expect(denied.queued)
        #expect(denied.approved == false)
        #expect(state.pendingApprovals.isEmpty)
    }

    @Test("the allowlist still approves without a prompt")
    func allowlistStillApproves() async throws {
        let (state, home) = try app()
        defer { try? FileManager.default.removeItem(at: home) }
        let cid = state.createNewConversation(isBackground: false, select: false)
        let command = "true --allowed-\(UUID().uuidString)"
        state.permissions.allowGlobally(toolName: "run_command", details: command)

        let approved = await state.requestApproval(toolName: "run_command", details: command, workspace: nil,
                                                   conversationId: cid, vibecopEnabled: false)
        #expect(approved)
        #expect(state.pendingApprovals.isEmpty)
    }

    @Test("autoApproveTools still approves without a prompt")
    func autoApproveStillApproves() async throws {
        let (state, home) = try app()
        defer { try? FileManager.default.removeItem(at: home) }
        state.autoApproveTools = true
        let cid = state.createNewConversation(isBackground: false, select: false)

        let approved = await state.requestApproval(toolName: "run_command", details: "true --x", workspace: nil,
                                                   conversationId: cid, vibecopEnabled: false)
        #expect(approved)
        #expect(state.pendingApprovals.isEmpty)
    }

    @Test("a background conversation still fails closed, whatever Vibecop's setting",
          arguments: [false, true])
    func backgroundStillFailsClosed(vibecopEnabled: Bool) async throws {
        let (state, home) = try app()
        defer { try? FileManager.default.removeItem(at: home) }
        let cid = state.createNewConversation(isBackground: true, select: false)

        let approved = await state.requestApproval(toolName: "run_command", details: "rm -rf x",
                                                   args: ["command": .string("rm -rf x")], workspace: nil,
                                                   conversationId: cid, vibecopEnabled: vibecopEnabled)
        #expect(approved == false)
        #expect(state.pendingApprovals.isEmpty)
        #expect(state.takeBackgroundDenials(for: cid).count == 1)
    }

    @Test("the event card's verdict is nil with Vibecop off")
    func cardVerdictIsNil() async throws {
        let (state, home) = try app()
        defer { try? FileManager.default.removeItem(at: home) }
        let verdict = await state.vibecopVerdict(
            for: BlockedCall(toolName: "run_command", args: ["command": .string("rm -rf x")]),
            inSandbox: true, vibecopEnabled: false)
        #expect(verdict == nil, "off is no verdict, not an APPROVE shown beside \"Approve and run\"")
    }

    @Test("a gate script reviewed with Vibecop off goes to the dialog")
    func gateScriptAsks() async throws {
        let (state, home) = try app()
        defer { try? FileManager.default.removeItem(at: home) }
        let cid = state.createNewConversation(isBackground: false, select: false)
        let review = IrisEngine.gateScriptReview(state: state, conversationId: cid, vibecopEnabled: false)

        let outcome = Task { @MainActor in
            await review.review(script: "test -f /in/ready", mounts: [], timeoutSeconds: 30)
        }
        var queued = false
        for _ in 0..<400 {
            if state.pendingApprovals.contains(where: { $0.origin == "Gate script" }) { queued = true; break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        if queued { state.resolveApproval(.deny) } else { state.denyPendingApprovals(for: cid) }
        let result = await outcome.value
        #expect(queued, "the review must ask the person, not take a disabled Vibecop's APPROVE")
        if case .failure(let message) = result {
            #expect(message.text == GateScriptReview.declined)
        } else {
            Issue.record("a declined dialog must refuse the gate script")
        }
    }

    /// The Stop button cancels the turn's task, and a grader's prompt waits inside that task's
    /// tree. A bare `withCheckedContinuation` ignores cancellation, so the turn stayed blocked on
    /// the dialog after Stop. Bounded: a regression is unstuck by hand and fails, never hangs.
    @Test("cancelling the task waiting on a prompt denies it and takes it off the queue",
          arguments: [VibecopCallerRole.evaluator, .agent])
    func cancellationDeniesThePrompt(role: VibecopCallerRole) async throws {
        let (state, home) = try app()
        defer { try? FileManager.default.removeItem(at: home) }
        let cid = state.createNewConversation(isBackground: false, select: false)
        let other = state.createNewConversation(isBackground: false, select: false)
        let finished = Locked(false)
        let waiting = Task { @MainActor in
            defer { finished.mutate { $0 = true } }
            return await state.requestApproval(toolName: "run_command", details: "true --x", workspace: nil,
                                               conversationId: cid, callerRole: role, vibecopEnabled: false)
        }
        // A prompt from another conversation, which the cancellation must leave alone.
        let bystander = Task { @MainActor in
            await state.enqueueUserApproval(toolName: "run_command", details: "true --y", workspace: nil,
                                            conversationId: other, origin: "Main agent")
        }
        for _ in 0..<400 where state.pendingApprovals.count < 2 {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        #expect(state.pendingApprovals.count == 2)

        waiting.cancel()
        for _ in 0..<400 where !finished.value { try? await Task.sleep(nanoseconds: 5_000_000) }
        let resolvedByCancel = finished.value
        if !resolvedByCancel { state.denyPendingApprovals(for: cid) }   // unstick a regression
        let approved = await waiting.value
        #expect(resolvedByCancel, "cancellation must resume the waiting approval")
        #expect(approved == false)
        #expect(!state.pendingApprovals.contains { $0.conversationId == cid })
        #expect(state.pendingApprovals.map(\.conversationId) == [other])

        state.denyPendingApprovals(for: other)
        #expect(await bystander.value == false)
    }
}
