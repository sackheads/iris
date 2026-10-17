import Testing
import Foundation
@testable import IrisKit

/// #549: a call an unattended turn needed an approval for is answered with a sentence that is true
/// there, not the attended "User denied … ask the user … suggest an alternative", which runs then
/// followed by ending on a question or offering a workaround.
@MainActor
@Suite("Unattended denial text (#549)", .timeLimit(.minutes(1)))
struct UnattendedDenialTextTests {
    private func callResponse(_ name: String, _ args: [String: JSONValue]) -> GeminiResponse {
        GeminiResponse(candidates: [Candidate(content: Content(
            role: "model", parts: [Part(functionCall: FunctionCall(name: name, args: args))]))], usageMetadata: nil)
    }

    private func textResponse(_ text: String) -> GeminiResponse {
        GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [Part(text: text)]))],
                       usageMetadata: nil)
    }

    private func tempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("iris-549-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func state(home: URL) throws -> AppState {
        let state = AppState(store: try ConversationStore.inMemory(),
                             tier2Provisioning: .provisioned, tier3Provisioning: .provisioned,
                             createIfEmpty: false, emitLaunchNotices: false)
        state.permissions = PermissionManager(paths: IrisPaths(root: home))
        return state
    }

    private func toolResults(_ state: AppState, _ id: UUID) -> [String] {
        state.conversations.first { $0.id == id }?.history.flatMap(\.parts)
            .compactMap { $0.functionResponse?.response["result"]?.stringValue } ?? []
    }

    /// One turn in `id` whose model calls `write_file` outside any allowlist once, then stops.
    private func turn(_ state: AppState, _ id: UUID, principal: Principal = .main, source: String,
                      target: URL) async -> IrisEngine {
        let engine = IrisEngine(state: state, tier: .medium, principal: principal,
                                client: FakeLLMClient(responses: [
                                    callResponse("write_file", ["path": .string(target.path), "content": .string("x")]),
                                    textResponse("done.")]),
                                retryDelays: [], protectionEnabled: false, sessionPeerCount: 0)
        await engine.processInput("go", source: source, conversationId: id)
        return engine
    }

    @Test("a job run refused a call for want of an approver is told so, and not to ask or route around it")
    func jobRun() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let state = try state(home: dir.appendingPathComponent("home"))
        let id = state.createNewConversation(isBackground: true, select: false)
        state.setWorkspace(for: id, path: dir.path)
        _ = await turn(state, id, source: "job:writer", target: dir.appendingPathComponent("out.txt"))

        let results = toolResults(state, id)
        #expect(results.contains(IrisEngine.unattendedDeniedToolResult(tool: "write_file")), "\(results)")
        #expect(!results.contains(IrisEngine.deniedToolResult))
        #expect(state.takeBackgroundDenials(for: id).count == 1, "still recorded as before")
        let text = IrisEngine.unattendedDeniedToolResult(tool: "write_file")
        #expect(!text.contains("User denied") && !text.contains("ask the user"))
        #expect(text.contains("Finish the rest of the task"), "only routing around the refusal is ruled out")
    }

    @Test("a subagent working for a run gets the same text")
    func runDelegate() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let state = try state(home: dir.appendingPathComponent("home"))
        let run = state.createNewConversation(isBackground: true, select: false)
        let sub = state.createNewConversation(isSubagent: true, isBackground: true, select: false)
        state.linkBackgroundDescendant(sub, of: run)
        state.setWorkspace(for: sub, path: dir.path)
        _ = await turn(state, sub, principal: .subagent, source: "subagent", target: dir.appendingPathComponent("out.txt"))

        #expect(toolResults(state, sub).contains(IrisEngine.unattendedDeniedToolResult(tool: "write_file")),
                "\(toolResults(state, sub))")
        #expect(state.takeBackgroundDenials(for: run).count == 1, "recorded against the run, as before")
    }

    @Test("an evaluator grading a run's work gets the same text")
    func runEvaluator() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let state = try state(home: dir.appendingPathComponent("home"))
        let run = state.createNewConversation(isBackground: true, select: false)
        let eval = state.createNewConversation(isSubagent: true, isBackground: true, select: false)
        state.linkBackgroundDescendant(eval, of: run)
        state.setWorkspace(for: eval, path: dir.path)
        let engine = IrisEngine(state: state, tier: .medium, principal: .evaluator,
                                client: FakeLLMClient(responses: [
                                    callResponse("run_command", ["command": .string("echo graded")]),
                                    callResponse("read_file", ["path": .string("/etc/hosts")]),
                                    textResponse("done.")]),
                                retryDelays: [], protectionEnabled: false, sessionPeerCount: 0)
        await engine.processInput("grade", source: "evaluator", conversationId: eval)
        #expect(toolResults(state, eval).contains { $0.hasPrefix("Not run: nobody is here to approve") })
        #expect(!toolResults(state, eval).contains(IrisEngine.deniedToolResult))
    }

    @Test("an attended conversation a person denied keeps the attended text")
    func attendedUnchanged() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let state = try state(home: dir.appendingPathComponent("home"))
        let id = state.createNewConversation(select: false)
        state.setWorkspace(for: id, path: dir.path)
        let turnTask = Task { @MainActor in
            await self.turn(state, id, source: "UI", target: dir.appendingPathComponent("out.txt"))
        }
        for _ in 0..<1000 {
            if let request = state.pendingApprovals.first(where: { $0.conversationId == id }) {
                state.resolveApproval(id: request.id, .deny)
                break
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        _ = try await value(of: turnTask)
        let results = toolResults(state, id)
        #expect(results.contains(IrisEngine.deniedToolResult), "\(results)")
        #expect(!results.contains(IrisEngine.unattendedDeniedToolResult(tool: "write_file")))
    }
}
