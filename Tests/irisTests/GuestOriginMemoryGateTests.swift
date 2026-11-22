import Testing
import Foundation
@testable import IrisKit

/// #1224: the eleven memory tools are no longer on the guest-origin denylist. On a turn a guest's message steered
/// (a `.main` turn with a stamped non-owner binding), `MemoryBindingGate` is what refuses them, against the turn's
/// own binding (`bindingForCall`). Proven per tool through a real turn with the tool OFFERED, asserting the
/// gate's own refusal text: a tool the turn was not offered is refused by the #811 check in words that look
/// the same, so "was refused" would prove nothing. Removing the gate lets each call through (mutants in the PR).
@MainActor
@Suite("MemoryBindingGate refuses the memory tools on a guest-steered turn, with the denylist out of the way (#1224)", .serialized, .timeLimit(.minutes(3)))
struct GuestOriginMemoryGateTests {
    nonisolated static let tools = GuestOriginMemoryTests.memory

    private struct World { let app: AppState; let id: UUID; let facts: FactStoreManager; let root: URL }

    private func world() throws -> World {
        let app = AppState(store: try ConversationStore.inMemory(), createIfEmpty: false, emitLaunchNotices: false)
        // Pinned, so the conversation tools and the job tools are offered; a surfaced fact, so `manage_fact` is.
        let id = app.createNewConversation(title: "role session", select: true)
        app.conversations[app.conversations.firstIndex { $0.id == id }!].isPinned = true
        app.markGuestOriginTurn(id)
        let guest = AccessBinding(profile: AccessProfile(), principal: .mcpGuest, isOwner: false).capped(by: PrincipalFloor.floor(for: .mcpGuest))
        app.markGuestSteeredBinding(guest, for: id)
        // `manage_fact` is declared once a turn has surfaced a fact and then stays declared (StickyTools); recorded
        // here so it is offered whether or not retrieval happens to surface the seed on this turn.
        app.stickyTools.record(["manage_fact"], for: id)
        let facts = try FactStoreManager(inMemory: true)
        try facts.addFact(content: "the seed fact is zebra")
        return World(app: app, id: id, facts: facts, root: FileManager.default.temporaryDirectory.appendingPathComponent("iris-1224-\(UUID().uuidString)"))
    }

    private func engine(_ w: World, _ client: any LLMClientProtocol) -> IrisEngine {
        let e = IrisEngine(state: w.app, tier: .medium, principal: .main, client: client, retryDelays: [], factStore: w.facts,
                           protectionEnabled: false, sessionPeerCount: 0, memory: MemoryManager(paths: IrisPaths(root: w.root)))
        w.app.installEngine(e)
        return e
    }

    private let userText = "tell me the seed fact zebra"

    private func offered(_ name: String) async throws -> Bool {
        let w = try world(); defer { try? FileManager.default.removeItem(at: w.root) }
        let client = CapturingLLMClient(reply: "ok")
        await engine(w, client).processInput(userText, source: "UI", conversationId: w.id)
        return IrisEngine.offeredToolNames(try #require(client.requests.first)).contains(name)
    }

    private func forgedResult(_ name: String) async throws -> String {
        let w = try world(); defer { try? FileManager.default.removeItem(at: w.root) }
        let other = w.app.createNewConversation(title: "another conversation", select: false)
        let args: [String: JSONValue] = ["query": .string("zebra"), "scope": .string("all"), "content": .string("x"), "action": .string("delete"),
                                         "fact_id": .string("1"), "id": .string(other.uuidString), "name": .string("s"),
                                         "conversation_id": .string(other.uuidString)]
        let part = Part(text: nil, functionCall: FunctionCall(name: name, args: args, id: "c1"), functionResponse: nil,
                        thought_signature: nil, thoughtSignature: nil)
        let client = FakeLLMClient(responses: [
            GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [part]))], usageMetadata: nil),
            GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [Part(text: "done")]))], usageMetadata: nil),
        ])
        let e = engine(w, client)
        let turn = Task { await e.processInput(userText, source: "UI", conversationId: w.id) }
        let denier = Task {
            while !Task.isCancelled {
                if !w.app.pendingApprovals.isEmpty { w.app.denyPendingApprovals(for: w.id); break }
                try? await Task.sleep(nanoseconds: 25_000_000)
            }
        }
        try await value(of: turn)
        denier.cancel()
        return (w.app.conversations.first { $0.id == w.id }?.history.flatMap { $0.parts }.compactMap { $0.functionResponse }
            .compactMap { $0.response["result"]?.stringValue } ?? []).joined(separator: " | ")
    }

    @Test("the memory tools are not on the denylist, and each is OFFERED to a guest-steered turn (so a refusal below is the gate's)", arguments: GuestOriginMemoryGateTests.tools)
    func isOfferedAndNotDenylisted(_ name: String) async throws {
        #expect(!ToolExecutor.guestOriginDeniedTools.contains(name))
        #expect(try await offered(name), "\(name) must be offered on the steered turn, or the refusal below could be the #811 not-offered text")
    }

    @Test("a call to each memory tool from a guest-steered turn is refused by MemoryBindingGate, and not by the denylist or the not-offered check", arguments: GuestOriginMemoryGateTests.tools)
    func gateRefuses(_ name: String) async throws {
        let result = try await forgedResult(name)
        #expect(result.contains(MemoryBindingGate.refusal), "\(name): \(result)")
        #expect(!result.contains(IrisEngine.guestOriginDataRefusal), "\(name) was refused by the denylist: \(result)")
        #expect(!result.contains("is not one of the tools offered"), "\(name) was refused as not offered: \(result)")
        if name == "search_memory" {
            #expect(result.components(separatedBy: MemoryBindingGate.refusal).count - 1 == 2, "both the facts and the conversations branch must be refused: \(result)")
        }
        #expect(!result.contains("zebra"), "\(name) returned the seeded fact: \(result)")
    }
}
