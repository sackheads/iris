import Testing
import Foundation
@testable import iris

/// #282 §2 — the grant lives on the run's conversation and follows a delegation. In-memory store,
/// injected `RecentWrites`, a fake client: nothing here reaches a singleton or the disk beyond a temp dir.
@MainActor
@Suite("sandboxGrant on the conversation (#282)")
struct SandboxGrantConversationTests {
    private func textResponse(_ text: String) -> GeminiResponse {
        GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [Part(text: text)]))],
                       usageMetadata: nil)
    }

    @Test("setSandboxGrant stamps and clears, and marks the conversation changed")
    func setAndClear() throws {
        let store = try ConversationStore.inMemory()
        let state = AppState(store: store, tier2Provisioning: .provisioned, tier3Provisioning: .provisioned)
        state.conversations.removeAll()
        let id = state.createNewConversation(isBackground: true, select: false)
        let grant = JobGrant(mounts: [ContainerMount(source: "/p")], network: true)
        state.setSandboxGrant(for: id, grant)
        #expect(state.conversations.first { $0.id == id }?.sandboxGrant == grant)
        state.flushSave()
        #expect(try store.loadAll().conversations.first { $0.id == id }?.sandboxGrant == grant)
        state.setSandboxGrant(for: id, nil)
        #expect(state.conversations.first { $0.id == id }?.sandboxGrant == nil)
    }

    @Test("a subagent a granted run delegates into inherits the grant with the workspace and the background flag")
    func subagentInheritsTheGrant() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("iris-grantsub-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try ConversationStore.inMemory()
        let state = AppState(store: store, tier2Provisioning: .provisioned, tier3Provisioning: .provisioned)
        state.conversations.removeAll()
        let parent = state.createNewConversation(isBackground: true, select: false)
        let grant = JobGrant(mounts: [ContainerMount(source: IrisPaths.canonicalPath(dir.path))], network: true)
        state.setWorkspace(for: parent, path: IrisPaths.canonicalPath(dir.path))
        state.setSandboxGrant(for: parent, grant)

        _ = await SubagentManager.shared.runSubagent(role: "helper", task: "say hi", effort: "easy",
                                                     parentConversationId: parent, maxIterations: 5,
                                                     client: FakeLLMClient(responses: [textResponse("hi")]),
                                                     appState: state, recentWrites: RecentWrites())

        let child = try #require(state.conversations.first { $0.isSubagent })
        #expect(child.isBackground)
        #expect(child.workspacePath == IrisPaths.canonicalPath(dir.path))
        #expect(child.sandboxGrant == grant)
    }
}
