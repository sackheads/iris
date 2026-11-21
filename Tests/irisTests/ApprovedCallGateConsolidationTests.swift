import Testing
import Foundation
@testable import IrisKit

/// #1222: the memory-tier write gate (#974 Task 7, `MemoryBindingGate`) is read fresh off
/// `bindingForCall` at the point a write actually runs, not trusted from whenever the call was
/// first queued — one shared check (`IrisEngine.memoryBindingWriteGate`) consulted by the live
/// dispatch (`executeFunctionCall`), the approved-call replay (`executeApprovedCall`) and the
/// held-write release (`applyHeldWrite`), so a binding that changed in between (the #974 "stamped
/// non-owner `.main` turn" class: `AppState.markGuestSteeredBinding`, one-turn-scoped and cleared
/// when the turn ends) is gated by what it is NOW. Driven through `engine.processInput` for the
/// hold and `AppState.approveContextWrite` for the release — the production call a person's click
/// makes — and read back from history/the hold's own outcome, never a direct `executeFunctionCall`
/// or `applyHeldWrite` unit call (#1217's lesson).
@MainActor
@Suite("A held write's release re-checks the memory-tier gate fresh (#1222)", .timeLimit(.minutes(1)))
struct ApprovedCallGateConsolidationTests {
    private struct Session {
        let app: AppState
        let engine: IrisEngine
        let id: UUID
        let paths: IrisPaths
    }

    private func tempPaths() -> IrisPaths {
        IrisPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent("iris-1222-\(UUID().uuidString)"))
    }

    /// A non-owner binding whose `memoryWrite` tier is `.none` -- below every writer's tier,
    /// `update_user_profile` (`.full`) included. The exact stamp `IrisEngine.deliverPeerMessage`
    /// would leave on a guest-steered `.main` conversation (#974 Task 15).
    private func nonOwnerBinding() -> AccessBinding {
        AccessBinding(profile: AccessProfile(), principal: .main, isOwner: false)
            .capped(by: PrincipalFloor.floor(for: .main))
    }

    private func session(tainted: Bool) -> Session {
        let rewrite = FunctionCall(name: "update_user_profile", args: ["content": .string("1222 planted profile")], id: "c1")
        var script: [[ScriptedStreamClient.Step]] = [[.event(.functionCall(rewrite)), .event(.done(finishReason: "tool_use"))]]
        script.append([.event(.textDelta("done")), .event(.done(finishReason: nil))])
        let paths = tempPaths()
        try? FileManager.default.createDirectory(at: paths.memoryDir, withIntermediateDirectories: true)
        let app = AppState()
        app.autoApproveTools = true
        let id = UUID()
        app.createNewConversation(id: id)
        app.selectedConversationId = id
        if tainted { app.markConversationReadUntrusted(id) }
        let engine = IrisEngine(state: app, tier: .medium, principal: .main, client: ScriptedStreamClient(script),
                                retryDelays: [], streamResponses: true, protectionEnabled: false, sessionPeerCount: 0,
                                memory: MemoryManager(paths: paths))
        app.installEngine(engine)
        return Session(app: app, engine: engine, id: id, paths: paths)
    }

    private func userProfile(_ s: Session) -> String? { try? String(contentsOf: s.paths.userMd, encoding: .utf8) }

    private func run(_ s: Session) async -> Bool {
        s.app.sendMessage("go")
        return await eventually { (s.app.conversations.first { $0.id == s.id }?.history ?? []).contains { $0.role == "model" && $0.parts.contains { $0.text == "done" } } }
    }

    private func eventually(_ timeoutMs: Int = 5000, _ condition: @MainActor @Sendable () -> Bool) async -> Bool {
        for _ in 0..<(timeoutMs / 10) {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }

    /// The owner's own held write still releases normally -- proves the gate is not vacuously
    /// refusing everything, and that the regression below is about the STAMP, not about breaking
    /// the ordinary flow.
    @Test func anOwnerHeldWriteStillReleases() async throws {
        let s = session(tainted: true)
        #expect(await run(s))
        let held = try #require(s.app.pendingContextWrites(shownIn: s.id).first)
        let outcome = await s.app.approveContextWrite(held.id)
        #expect(outcome == .applied("User profile updated."))
        #expect(userProfile(s) == "1222 planted profile")
    }

    /// The headline case: held under the owner's binding (the only way it is held at all --
    /// `MemoryBindingGate` runs before the taint check, so a non-owner's write is refused outright
    /// and never reaches the hold), then the conversation is stamped non-owner before the person's
    /// approval click reaches `applyHeldWrite`. The release must re-read the binding fresh and
    /// refuse, not trust the binding the hold was created under.
    @Test func aHeldWriteStampedNonOwnerBeforeReleaseIsRefused() async throws {
        let s = session(tainted: true)
        #expect(await run(s))
        let held = try #require(s.app.pendingContextWrites(shownIn: s.id).first)
        s.app.markGuestSteeredBinding(nonOwnerBinding(), for: s.id)

        let outcome = await s.app.approveContextWrite(held.id)
        guard case .failed(let reason) = outcome else {
            Issue.record("expected .failed, got \(outcome)")
            return
        }
        #expect(reason == MemoryBindingGate.refusal)
        #expect(userProfile(s) != "1222 planted profile", "the stamped-non-owner release must not have written USER.md")
        let messages = (s.app.conversations.first { $0.id == s.id }?.messages ?? [])
        #expect(messages.contains { $0.content.contains("Held change not applied") })
    }
}
