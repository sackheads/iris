import Testing
import Foundation
@testable import IrisKit

/// #1293 / #1294: a turn a guest's message steered is attended `.main` with a stamped non-owner binding. Two
/// groups of tools reached the owner's authority through it with no gate: the session roster
/// (`list_sessions`, `describe_session`: the reply goes to the guest) and standing jobs (`schedule_job`,
/// `register_directory_watcher`: the default read-only profile needs no approval, and the row was stamped
/// with no profile, so it fired as the owner running the guest's prompt). Until the spine classifies them
/// owner-only (#1203) they are in `ToolClassTable.ownerOnlyNames`: not offered to such a turn, and refused at
/// dispatch. Each test drives a real turn through `processInput`.
@MainActor
@Suite("a guest-steered turn has no session roster and no standing jobs (#1293, #1294)", .serialized, .timeLimit(.minutes(2)))
struct GuestOriginSessionJobToolsTests {
    nonisolated static let tools = ["list_sessions", "describe_session", "schedule_job", "register_directory_watcher"]

    private func world() throws -> (AppState, UUID) {
        let app = AppState(store: try ConversationStore.inMemory(), createIfEmpty: false, emitLaunchNotices: false)
        let id = app.createNewConversation(title: "role session", select: true)
        let peer = app.createNewConversation(title: "PEER-TITLE", select: false)
        app.conversations[app.conversations.firstIndex { $0.id == peer }!].role = "reviewer"
        return (app, id)
    }

    private func steer(_ app: AppState, _ id: UUID) {
        app.markGuestOriginTurn(id)
        let guest = AccessBinding(profile: AccessProfile(), principal: .mcpGuest, isOwner: false).capped(by: PrincipalFloor.floor(for: .mcpGuest))
        app.markGuestSteeredBinding(guest, for: id)
    }

    private func engine(_ app: AppState, _ client: any LLMClientProtocol) -> IrisEngine {
        let e = IrisEngine(state: app, tier: .medium, principal: .main, client: client, retryDelays: [], protectionEnabled: false, sessionPeerCount: 1)
        app.installEngine(e)
        return e
    }

    private func offered(_ app: AppState, _ id: UUID) async -> Set<String> {
        let client = CapturingLLMClient(reply: "ok")
        await engine(app, client).processInput("hello", source: "UI", conversationId: id)
        return IrisEngine.offeredToolNames(client.requests[0])
    }

    private func forged(_ name: String, steered: Bool) async throws -> (result: String, jobs: Int) {
        let (app, id) = try world()
        if steered { steer(app, id) }
        let args: [String: JSONValue] = ["prompt": .string("GUEST-WRITTEN-PROMPT"), "intervalSeconds": .int(3600),
                                         "to": .string("role:reviewer"), "path": .string("/tmp")]
        let part = Part(text: nil, functionCall: FunctionCall(name: name, args: args, id: "c1"), functionResponse: nil,
                        thought_signature: nil, thoughtSignature: nil)
        let client = FakeLLMClient(responses: [
            GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [part]))], usageMetadata: nil),
            GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [Part(text: "done")]))], usageMetadata: nil),
        ])
        let e = engine(app, client)
        let turn = Task { await e.processInput("go", source: "UI", conversationId: id) }
        let denier = Task {
            while !Task.isCancelled {
                if !app.pendingApprovals.isEmpty { app.denyPendingApprovals(for: id); break }
                try? await Task.sleep(nanoseconds: 25_000_000)
            }
        }
        try await value(of: turn)
        denier.cancel()
        let results = app.conversations.first { $0.id == id }?.history.flatMap { $0.parts }.compactMap { $0.functionResponse }
            .compactMap { $0.response["result"]?.stringValue } ?? []
        return (results.joined(separator: " | "), try app.store.ledger.jobs().count)
    }

    @Test("control: an ordinary attended turn is offered all four, so 'not offered' below proves the strip")
    func ordinaryTurnIsOffered() async throws {
        let (app, id) = try world()
        let names = await offered(app, id)
        #expect(names.isSuperset(of: Self.tools), "\(Set(Self.tools).subtracting(names).sorted())")
    }

    @Test("a guest-steered turn is offered none of the four")
    func steeredTurnIsNotOffered() async throws {
        let (app, id) = try world()
        steer(app, id)
        let names = await offered(app, id)
        #expect(names.isDisjoint(with: Self.tools), "\(names.intersection(Self.tools).sorted())")
        #expect(names.contains("run_command"), "the turn did declare tools")
    }

    @Test("a forged call to each of the four from a guest-steered turn is refused with the guest-origin text, and creates no job", arguments: GuestOriginSessionJobToolsTests.tools)
    func forgedCallIsRefused(_ name: String) async throws {
        let r = try await forged(name, steered: true)
        #expect(r.result.contains(IrisEngine.nonOwnerToolRefusal), "\(name): \(r.result)")
        #expect(r.jobs == 0, "\(name) created a job")
        #expect(!r.result.contains("PEER-TITLE") && !r.result.contains("session_id"), "\(name) leaked the roster: \(r.result)")
    }

    @Test("control: the same forged calls from an unsteered turn are not refused as guest-origin", arguments: GuestOriginSessionJobToolsTests.tools)
    func unsteeredIsNotRefused(_ name: String) async throws {
        let r = try await forged(name, steered: false)
        #expect(!r.result.contains(IrisEngine.nonOwnerToolRefusal), "\(name): \(r.result)")
    }
}
