import Testing
import Foundation
@testable import IrisKit

/// #1236: the approval ladder's `isOwner:` reads the turn's binding (`bindingForCall`), not the
/// engine's own. A `.main` engine is owner-shaped, so a turn bound to a narrower profile (a
/// guest-steered recipient turn's stamp, a stamped job run) read as the owner there, and Vibecop's
/// APPROVE stood in for the person on its host `read_file` (#600, #974 Task 8 C5).
///
/// Driven through the real call sites with Vibecop on (`AppState.vibecopEnabledOverride`, never
/// global config: invariant 7) and a scoped approver that APPROVEs everything. The stamp is applied
/// with `markGuestSteeredBinding` and the turn is NOT guest-origin, so `!guestOrigin` does not shield
/// it: this is exactly the non-guest, non-owner-bound `.main` turn the issue names.
@MainActor
@Suite("the approval ladder reads the turn's ownership, not the engine's (#1236)", .serialized, .timeLimit(.minutes(2)))
struct TurnOwnershipApprovalTests {
    private final class Approver: AuxiliaryInferenceEngine, @unchecked Sendable {
        func loadModel(config: AuxiliaryModelConfig) async throws {}
        func unloadModel() async {}
        func generate(prompt: String, jsonSchema: String?) async throws -> String {
            #"{"decision":"APPROVE","reason":"routine"}"#
        }
    }

    private struct World {
        let base: URL
        let allowed: URL
        let file: URL
        let state: AppState
        func tearDown() { try? FileManager.default.removeItem(at: base) }
    }

    private func world() throws -> World {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("iris-1236-\(UUID().uuidString)")
        let allowed = base.appendingPathComponent("allowed")
        try FileManager.default.createDirectory(at: allowed, withIntermediateDirectories: true)
        let file = allowed.appendingPathComponent("a.txt")
        try "hello".write(to: file, atomically: true, encoding: .utf8)
        let state = AppState(store: try ConversationStore.inMemory(), tier2Provisioning: .provisioned, tier3Provisioning: .provisioned,
                             createIfEmpty: false, emitLaunchNotices: false)
        state.permissions = PermissionManager(paths: IrisPaths(root: base.appendingPathComponent("iris-home")))
        state.autoApproveTools = false
        state.vibecopEnabledOverride = true
        return World(base: base, allowed: allowed, file: file, state: state)
    }

    /// The conversation's turn is bound to a profile that may read inside `allowed` only, on the
    /// owner-shaped engine; nil is the owner's own turn (the control).
    private func conversation(_ w: World, stamped: Bool) -> UUID {
        let id = w.state.createNewConversation(isBackground: false, select: false)
        w.state.setWorkspace(for: id, path: w.allowed.path)
        if stamped {
            w.state.markGuestSteeredBinding(
                AccessBinding(profile: AccessProfile(fsRoots: [w.allowed.path]), principal: .main, isOwner: false), for: id)
        }
        return id
    }

    private func engine(_ w: World, responses: [GeminiResponse] = []) -> IrisEngine {
        IrisEngine(state: w.state, tier: .medium, client: FakeLLMClient(responses: responses), protectionEnabled: false, sessionPeerCount: 0)
    }

    /// Runs `body` with the approver scoped; if the call reaches the prompt it is denied and `.asked`
    /// is returned, otherwise `.silent`. Bounded: a call doing neither in ~2 s is denied.
    private enum Outcome: Equatable { case asked, silent }
    private func outcome(_ w: World, in id: UUID, _ body: @escaping @MainActor () async -> Void) async throws -> Outcome {
        let done = Locked(false)
        let task = Task { @MainActor in
            await AuxiliaryModelManager.$scopedEngines.withValue(["vibecop": Approver()]) { await body() }
            done.mutate { $0 = true }
        }
        var result = Outcome.silent
        for _ in 0..<400 {
            if w.state.pendingApprovals.contains(where: { $0.conversationId == id }) {
                result = .asked
                w.state.denyPendingApprovals(for: id)
                break
            }
            if done.value { break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        w.state.denyPendingApprovals(for: id)
        try await value(of: task)
        return result
    }

    @Test("attaching a host file: the owner's turn is approved by Vibecop silently; a profile-bound turn on the same engine is asked")
    func attachHostFile() async throws {
        let w = try world(); defer { w.tearDown() }
        let attachments: JSONValue = .array([.object(["path": .string(w.file.path)])])

        let ownerId = conversation(w, stamped: false)
        let owner = try await outcome(w, in: ownerId) {
            _ = await self.engine(w).prepareAttachments(attachments, conversationId: ownerId, workspacePath: w.allowed.path)
        }
        #expect(owner == .silent, "control: the owner's attach read is approved by Vibecop without a prompt")

        let boundId = conversation(w, stamped: true)
        let bound = try await outcome(w, in: boundId) {
            _ = await self.engine(w).prepareAttachments(attachments, conversationId: boundId, workspacePath: w.allowed.path)
        }
        #expect(bound == .asked, "a turn bound to a non-owner profile is asked, never approved as the owner")
    }

    private func readTurn(_ w: World, path: String) -> [GeminiResponse] {
        let call = FunctionCall(name: "read_file", args: ["path": .string(path)], id: "c1")
        return [
            GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [Part(functionCall: call)]))], usageMetadata: nil),
            GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [Part(text: "done")]))], usageMetadata: nil),
        ]
    }

    @Test("a read_file tool call: the owner's turn is approved by Vibecop silently; a profile-bound turn on the same engine is asked")
    func mainToolCall() async throws {
        let w = try world(); defer { w.tearDown() }

        let ownerId = conversation(w, stamped: false)
        let owner = try await outcome(w, in: ownerId) {
            await self.engine(w, responses: self.readTurn(w, path: w.file.path)).processInput("go", source: "UI", conversationId: ownerId)
        }
        #expect(owner == .silent, "control: the owner's read_file is approved by Vibecop without a prompt")

        let boundId = conversation(w, stamped: true)
        let bound = try await outcome(w, in: boundId) {
            await self.engine(w, responses: self.readTurn(w, path: w.file.path)).processInput("go", source: "UI", conversationId: boundId)
        }
        #expect(bound == .asked, "a turn bound to a non-owner profile is asked, never approved as the owner")
    }

    @Test("every isOwner argument into requestApprovalSource in iris.swift reads the turn's ownership")
    func noSiteReadsTheEnginesOwnOwnership() throws {
        let url = PerfPaths.repoRoot().appendingPathComponent("Sources/IrisKit/iris.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        #expect(!source.contains("self.binding.isOwner"), "a site reading self.binding.isOwner would ignore a bound turn")
        let sites = source.components(separatedBy: "isOwner: await callIsOwner(conversationId)").count - 1
        #expect(sites == 5, "the five requestApprovalSource call sites (tainted send, job creation, tool ask, host attach, VM attach), found \(sites)")
    }

    @Test("callIsOwner follows the stamp, and no conversation keeps the engine's own")
    func callIsOwnerFollowsTheStamp() async throws {
        let w = try world(); defer { w.tearDown() }
        let bound = conversation(w, stamped: true), plain = conversation(w, stamped: false)
        let e = engine(w)
        #expect(await e.callIsOwner(bound) == false)
        #expect(await e.callIsOwner(plain) == true)
        #expect(await e.callIsOwner(nil) == true)
    }
}
