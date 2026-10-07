import Testing
import Foundation
@testable import iris

/// #314 decision 1: the reply's blocks ride the history JSON, reach hooks, and never reach Gemini.
@Suite("Content.anthropicBlocks storage (#314)")
struct AnthropicBlocksStorageTests {
    static let blocks = #"[{"type":"thinking","thinking":"","signature":"sig-secret"},{"type":"text","text":"hi"}]"#

    private func request(blocks: String?) -> GeminiRequest {
        GeminiRequest(contents: [Content(role: "user", parts: [Part(text: "q")]),
                                 Content(role: "model", parts: [Part(text: "hi")], anthropicBlocks: blocks)],
                      systemInstruction: nil, tools: nil)
    }

    @Test("a history row written before #314 decodes, with no blocks")
    func oldRowDecodes() throws {
        let row = #"{"role":"model","parts":[{"text":"hi"}]}"#
        let c = try JSONDecoder().decode(Content.self, from: Data(row.utf8))
        #expect(c.anthropicBlocks == nil)
        #expect(c.parts.first?.text == "hi")
    }

    @Test("the blocks survive the history JSON round trip unchanged")
    func roundTrips() throws {
        let c = Content(role: "model", parts: [Part(text: "hi")], anthropicBlocks: Self.blocks)
        let back = try JSONDecoder().decode(Content.self, from: JSONEncoder().encode(c))
        #expect(back.anthropicBlocks == Self.blocks)
    }

    @Test("a Gemini body never carries the field, and matches the body without it byte for byte")
    func geminiStrips() throws {
        let body = try LLMClient.encodeGeminiBody(request(blocks: Self.blocks))
        #expect(!String(decoding: body, as: UTF8.self).contains("anthropicBlocks"))
        #expect(body == (try LLMClient.encodeGeminiBody(request(blocks: nil))))
    }

    @Test("an OpenAI body never carries the blocks")
    func openAIIgnores() throws {
        let r = try OpenAIClient.makeURLRequest(request: request(blocks: Self.blocks), model: "gpt-5.6-terra",
                                                apiKey: "k", stream: false)
        #expect(!String(decoding: r.httpBody ?? Data(), as: UTF8.self).contains("sig-secret"))
    }

    @Test("BeforeModel and PreCompress hooks see the blocks, so a hook that keeps them keeps replay")
    func hookPayloadsCarry() throws {
        let payload = try #require(HookManager.beforeModelPayload(request(blocks: Self.blocks)))
        let back = try JSONDecoder().decode(GeminiRequest.self, from: payload)
        #expect(back.contents.last?.anthropicBlocks == Self.blocks)
    }

    @MainActor
    @Test("history keeps the blocks across a save and reload, and search never indexes them")
    func storeKeepsAndSearchIgnores() throws {
        let store = try ConversationStore.inMemory()
        let app = AppState(store: store, tier2Provisioning: .provisioned, tier3Provisioning: .provisioned)
        app.conversations.removeAll()
        let id = app.createNewConversation(title: "blocks")
        app.appendContentToHistory(for: id, content: Content(role: "user", parts: [Part(text: "q")]))
        app.appendContentToHistory(for: id, content: Content(role: "model", parts: [Part(text: "hi")],
                                                             anthropicBlocks: Self.blocks))
        app.flushSave()
        let loaded = try #require(try store.loadAll().conversations.first { $0.id == id })
        #expect(loaded.history.last?.anthropicBlocks == Self.blocks)
        #expect(try store.searchConversations(query: "sig-secret").isEmpty)
    }
}
