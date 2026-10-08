import Testing
import Foundation
import GRDB
@testable import iris

@MainActor
@Suite("drop_block persists per conversation (#314)", .timeLimit(.minutes(1)))
struct PrefixMismatchPersistenceTests {
    @Test("a conversation JSON written before #314 decodes, unset")
    func oldConversationDecodes() throws {
        let c = try JSONDecoder().decode(Conversation.self, from: Data(#"{"title":"t"}"#.utf8))
        #expect(c.prefixMismatchBehavior == nil)
    }

    @Test("a conversation JSON with a value this build does not know decodes, unset")
    func unknownJSONValueDecodesUnset() throws {
        let c = try JSONDecoder().decode(Conversation.self, from: Data(#"{"title":"t","prefixMismatchBehavior":"later_value"}"#.utf8))
        #expect(c.title == "t")
        #expect(c.prefixMismatchBehavior == nil)
        let known = try JSONDecoder().decode(Conversation.self, from: Data(#"{"title":"t","prefixMismatchBehavior":"drop_block"}"#.utf8))
        #expect(known.prefixMismatchBehavior == .dropBlock)
    }

    @Test("v18 adds the column and keeps a v17 conversation, unset")
    func v18KeepsRows() throws {
        let root = try ThinkingFixtures.tempDirectory("v18")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("conversations.sqlite")
        let id = UUID()
        do {
            let queue = try DatabaseQueue(path: url.path)
            try ConversationStore.migrator.migrate(queue, upTo: "v17_job_run_delegated_reads")
            try queue.write { db in
                try db.execute(sql: """
                    INSERT INTO conversations (id, position, title, createdAt, updatedAt, tokenUsage)
                    VALUES (?, 1, 'old', datetime('now'), datetime('now'), '{}')
                    """, arguments: [id.uuidString])
            }
            try queue.close()
        }
        let store = try ConversationStore.onDisk(at: url)
        let loaded = try #require(try store.loadAll().conversations.first { $0.id == id })
        #expect(loaded.title == "old")
        #expect(loaded.prefixMismatchBehavior == nil)
    }

    @Test("the setting survives a reload through INSERT and through UPDATE")
    func survivesReload() throws {
        let store = try ConversationStore.inMemory()
        let app = AppState(store: store, tier2Provisioning: .provisioned, tier3Provisioning: .provisioned)
        app.conversations.removeAll()
        let inserted = app.createNewConversation(title: "insert")
        app.recordPrefixMismatchFallback(inserted)
        let updated = app.createNewConversation(title: "update")
        app.flushSave()
        #expect(try store.loadAll().conversations.first { $0.id == updated }?.prefixMismatchBehavior == nil)
        app.recordPrefixMismatchFallback(updated)
        app.flushSave()
        let all = try store.loadAll().conversations
        #expect(all.first { $0.id == inserted }?.prefixMismatchBehavior == .dropBlock)
        #expect(all.first { $0.id == updated }?.prefixMismatchBehavior == .dropBlock)
    }

    @Test("a value this build does not know reads as unset, and the conversation is kept")
    func unknownValueReadsUnset() throws {
        let store = try ConversationStore.inMemory()
        let app = AppState(store: store, tier2Provisioning: .provisioned, tier3Provisioning: .provisioned)
        app.conversations.removeAll()
        let id = app.createNewConversation(title: "garbled")
        app.flushSave()
        try store.rawWrite("UPDATE conversations SET prefixMismatchBehavior = 'later_value' WHERE id = ?", arguments: [id.uuidString])
        let loaded = try #require(try store.loadAll().conversations.first { $0.id == id })
        #expect(loaded.prefixMismatchBehavior == nil)
    }

    @Test("a fallback reply persists drop_block, every later request carries it, and its earlier blocks stay out")
    func fallbackPersistsAndIsSent() async throws {
        let dir = try ThinkingFixtures.tempDirectory("fallback")
        defer { try? FileManager.default.removeItem(at: dir) }
        var script = ThinkingFixtures.fourRounds()
        script[2].anthropicBindingFallback = true
        let store = try ConversationStore.inMemory()
        let h = try ThinkingHarness.make(script, hooks: try ThinkingFixtures.hooks(in: dir), store: store)
        await h.run()
        try #require(h.client.requests.count == 4)
        #expect(h.client.requests.map(\.prefixMismatchBehavior) == [nil, nil, nil, .dropBlock])
        #expect(try h.sentSignatures()[3].isEmpty, "the retry dropped blocks; everything up to its reply stays out (plan note 6)")
        #expect(try ThinkingFixtures.bodyText(h.client.requests[3]).contains("drop_block"))
        h.app.flushSave()

        let app2 = AppState(store: store, tier2Provisioning: .provisioned, tier3Provisioning: .provisioned)
        let client2 = RecordingClient([ThinkingFixtures.reply(5, toolCall: false)])
        let engine2 = IrisEngine(state: app2, tier: .medium, principal: .main, client: client2, retryDelays: [],
                                 streamResponses: false, factStore: try FactStoreManager(inMemory: true),
                                 protectionEnabled: false, sessionPeerCount: 0, hooks: try ThinkingFixtures.hooks(in: dir),
                                 provider: LLMProvider.anthropic.rawValue, replayThinking: true)
        await engine2.processInput("again", source: "UI", conversationId: h.id)
        #expect(client2.requests.first?.prefixMismatchBehavior == .dropBlock, "after a restart, the first request sends it")
    }

    @Test("the persisted value follows the model and route: nothing reaches one that cannot take it (Review Focus 4)")
    func persistedValueFollowsTheModel() async throws {
        let dir = try ThinkingFixtures.tempDirectory("follows")
        defer { try? FileManager.default.removeItem(at: dir) }
        var script = [ThinkingFixtures.reply(1, toolCall: true), ThinkingFixtures.reply(2, toolCall: false)]
        script[0].anthropicBindingFallback = true
        let h = try ThinkingHarness.make(script, hooks: try ThinkingFixtures.hooks(in: dir))
        await h.run()
        let last = try #require(h.client.requests.last)
        #expect(last.prefixMismatchBehavior == .dropBlock)
        #expect(try ThinkingFixtures.bodyText(last).contains("block_binding"), "precondition: opus-5-5 takes it")
        for model in ["claude-haiku-4-5-20251001", "claude-sonnet-5"] {
            let u = try ThinkingFixtures.urlRequest(last, model: model)
            #expect(!String(decoding: u.httpBody ?? Data(), as: UTF8.self).contains("block_binding"), Comment(rawValue: model))
            #expect(u.value(forHTTPHeaderField: "anthropic-beta") == nil, Comment(rawValue: model))
        }
        let custom = try AnthropicClient.makeURLRequest(request: last, model: "claude-opus-5-5",
                                                        transport: .direct(apiKey: "k", baseURL: "https://gateway.example/v1"),
                                                        stream: true)
        #expect(!String(decoding: custom.httpBody ?? Data(), as: UTF8.self).contains("block_binding"), "custom base URL")
        #expect(custom.value(forHTTPHeaderField: "anthropic-beta") == nil, "custom base URL")
        #expect(!String(decoding: try LLMClient.encodeGeminiBody(last), as: UTF8.self).contains("drop_block"))
    }

    /// The real Anthropic stream behind the engine, answered by a scoped mock session.
    private final class MockedAnthropicClient: LLMClientProtocol, @unchecked Sendable {
        let session: URLSession
        init(session: URLSession) { self.session = session }
        var supportsStreaming: Bool { true }
        func generateContent(request: GeminiRequest, tier: ModelTier) async throws -> GeminiResponse {
            try await AnthropicClient.generateContent(request: request, model: "claude-opus-5-5",
                                                      transport: .direct(apiKey: "k", baseURL: ""), session: session)
        }
        func streamContent(request: GeminiRequest, tier: ModelTier) -> AsyncThrowingStream<LLMStreamEvent, Error> {
            AnthropicClient.streamContent(request: request, model: "claude-opus-5-5", session: session,
                                          transport: { .direct(apiKey: "k", baseURL: "") })
        }
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func next() -> Int { lock.withLock { n += 1; return n } }
        var value: Int { lock.withLock { n } }
    }

    /// Nonisolated: URLSession calls the handler off the main actor, and a closure formed in this
    /// `@MainActor` suite would inherit its isolation and trap.
    nonisolated private static func mockSession(rejections: Int, counter: Counter) -> (session: URLSession, remove: () -> Void) {
        MockURLProtocol.scopedSession { request in
            if counter.next() <= rejections {
                return (HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!,
                        Data(AnthropicBindingRetryTests.bindingRejection.utf8))
            }
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(AnthropicBindingRetryTests.sse.utf8))
        }
    }

    private func runOverMock(rejections: Int) async throws -> (persisted: PrefixMismatchBehavior?, stored: PrefixMismatchBehavior?, calls: Int) {
        let dir = try ThinkingFixtures.tempDirectory("mock-\(rejections)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let counter = Counter()
        let (session, remove) = Self.mockSession(rejections: rejections, counter: counter)
        defer { remove() }
        let store = try ConversationStore.inMemory()
        let app = AppState(store: store, tier2Provisioning: .provisioned, tier3Provisioning: .provisioned)
        app.conversations.removeAll()
        let id = app.createNewConversation(title: "mock")
        let engine = IrisEngine(state: app, tier: .medium, principal: .main, client: MockedAnthropicClient(session: session),
                                retryDelays: [], streamResponses: true, factStore: try FactStoreManager(inMemory: true),
                                protectionEnabled: false, sessionPeerCount: 0, hooks: try ThinkingFixtures.hooks(in: dir),
                                provider: LLMProvider.anthropic.rawValue, replayThinking: true)
        await engine.processInput("hi", source: "UI", conversationId: id)
        app.flushSave()
        let persisted = app.conversations.first { $0.id == id }?.prefixMismatchBehavior
        let stored = try store.loadAll().conversations.first { $0.id == id }?.prefixMismatchBehavior
        return (persisted, stored, counter.value)
    }

    @Test("over the real stream: a retry that succeeds persists drop_block (ruling 1)")
    func successfulRetryPersists() async throws {
        let r = try await runOverMock(rejections: 1)
        #expect(r.calls == 2, "precondition: one rejection, one retry")
        #expect(r.persisted == .dropBlock)
        #expect(r.stored == .dropBlock)
    }

    @Test("over the real stream: a retry that fails again persists nothing (ruling 1)")
    func failedRetryPersistsNothing() async throws {
        let r = try await runOverMock(rejections: 2)
        #expect(r.calls == 2, "precondition: the retry ran and failed, and nothing retried it again")
        #expect(r.persisted == nil)
        #expect(r.stored == nil)
    }
}
