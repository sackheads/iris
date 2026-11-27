import Foundation
import Testing
@testable import IrisKit

/// #1437: a loop's history TTL follows its cadence. At 45 minutes or less it's an hour, so each tick reads the last
/// one's history; slower, it stays at five minutes, where marker (d) still serves a tick's own later rounds.
@Suite("A loop's history is cached for an hour at 45 minutes or less, and at five minutes when slower (#1437)")
struct LoopHistoryTTLTests {
    private let hour = CacheTTLPolicy(prefix: .oneHour, history: .oneHour)

    private func resolve(_ cadence: TimeInterval?, pinned: Bool = false, principal: Principal = .main) -> CacheTTLPolicy {
        CacheTTLPolicy.resolve(isPinned: pinned, isUnattended: false, principal: principal, backgroundFiresHourly: false,
                               loopCadence: cadence)
    }

    private static let hourly: [TimeInterval] = [60, 1200, 2700]
    private static let slower: [TimeInterval] = [2701, 3600, 86_400]

    @Test("at 45 minutes or less: an hour", arguments: hourly)
    func hourlyCadence(cadence: TimeInterval) {
        #expect(resolve(cadence) == hour)
    }

    @Test("slower than 45 minutes: today's five minutes", arguments: slower)
    func slowerCadence(cadence: TimeInterval) {
        #expect(resolve(cadence) == .standard)
    }

    @Test("no loop is unchanged; the pinned Iris keeps its hour; a subagent stays at five minutes")
    func others() {
        #expect(resolve(nil) == .standard)
        #expect(resolve(2 * 3600, pinned: true) == hour, "the pinned conversation is already an hour, loop or not")
        #expect(resolve(20 * 60, principal: .subagent) == .standard)
    }

    @Test("a self-paced loop counts at its default; an alarm and a fixed loop at their interval")
    func cadence() {
        #expect(CacheTTLPolicy.cadence(of: ConversationLoop(prompt: "p", intervalSeconds: 60, cap: 5, selfPaced: true))
                == ConversationLoop.selfPacedDefault)
        #expect(CacheTTLPolicy.cadence(of: ConversationLoop(prompt: "p", intervalSeconds: 7200, cap: 1, isAlarm: true)) == 7200)
        #expect(CacheTTLPolicy.cadence(of: ConversationLoop(prompt: "p", intervalSeconds: 1200, cap: 5)) == 1200)
    }

    private func body(_ ttl: CacheTTLPolicy) throws -> [String: Any] {
        var request = GeminiRequest(contents: [Content(role: "user", parts: [Part(text: "tick 1")]),
                                               Content(role: "model", parts: [Part(text: "ack")]),
                                               Content(role: "user", parts: [Part(text: "tick 2")])],
                                    systemInstruction: Content(role: "system", parts: [Part(text: "be brief")]), tools: nil)
        request.cacheHints = CacheHints(ttl: ttl)
        let url = try AnthropicClient.makeURLRequest(request: request, model: "claude-sonnet-5-5",
                                                     transport: .direct(apiKey: "k", baseURL: ""), stream: false)
        return (try JSONSerialization.jsonObject(with: url.httpBody ?? Data()) as? [String: Any]) ?? [:]
    }

    @Test("a slow loop's tick still marks its last message, so its later tool rounds read its first (dev-2's #1445 review)")
    func slowLoopKeepsRoundMarker() throws {
        let messages = try body(resolve(3 * 3600))["messages"] as? [[String: Any]] ?? []
        let last = (messages.last?["content"] as? [[String: Any]])?.last
        #expect(last?["cache_control"] != nil, "marker (d), on the request's last message")
    }

    @Test("an hourly loop marks its history at an hour")
    func hourlyBody() throws {
        let messages = String(decoding: try JSONSerialization.data(withJSONObject: try body(hour)["messages"] ?? []), as: UTF8.self)
        #expect(messages.contains("\"ttl\":\"1h\""))
    }

    @MainActor
    private func requestTTL(loop: ConversationLoop?) async throws -> CacheTTLPolicy? {
        let state = AppState(store: try ConversationStore.inMemory(), tier2Provisioning: .provisioned,
                             tier3Provisioning: .provisioned, createIfEmpty: false, emitLaunchNotices: false)
        let id = state.createNewConversation(isBackground: false, select: true)
        if let idx = state.conversations.firstIndex(where: { $0.id == id }) { state.conversations[idx].loop = loop }
        let reply = GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [Part(text: "ack")]))], usageMetadata: nil)
        let dumped = LockedBox<[GeminiRequest]>([])
        let engine = IrisEngine(state: state, tier: .medium, client: FakeLLMClient(responses: [reply]), retryDelays: [],
                                protectionEnabled: false, sessionPeerCount: 0,
                                requestDumpSink: { request, _, _ in dumped.withLock { $0.append(request) } })
        await engine.processInput("tick", source: "Loop", conversationId: id)
        return dumped.withLock { $0 }.first?.cacheHints?.ttl
    }

    @Test("the engine sends a loop conversation's cadence to the policy")
    @MainActor
    func engineWiring() async throws {
        #expect(try await requestTTL(loop: ConversationLoop(prompt: "p", intervalSeconds: 1200, cap: 5)) == hour)
        #expect(try await requestTTL(loop: ConversationLoop(prompt: "p", intervalSeconds: 3 * 3600, cap: 5)) == .standard)
        #expect(try await requestTTL(loop: nil) == .standard)
    }
}
