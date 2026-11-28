import Foundation
import Testing
@testable import IrisKit

/// #1452: a request to one provider never carries another provider's reasoning metadata from history.
@Suite("History sends each provider only its own reasoning metadata (#1452)")
struct HistoryProvenanceTests {
    private func reply(_ text: String, signature: String?, by producer: String?, blocks: String? = nil) -> Content {
        var c = Content(role: "model", parts: [
            Part(text: text, thought_signature: signature, thoughtSignature: signature),
            Part(functionCall: FunctionCall(name: "read_file", args: ["path": .string("/a")], thought_signature: signature,
                                            thoughtSignature: signature)),
        ])
        c.anthropicBlocks = blocks
        c.producedBy = producer
        return c
    }

    private func request(_ entry: Content) -> GeminiRequest {
        GeminiRequest(contents: [Content(role: "user", parts: [Part(text: "hi")]), entry,
                                 Content(role: "user", parts: [Part(text: "go on")])],
                      systemInstruction: nil, tools: nil)
    }

    private func openAIBody(_ request: GeminiRequest) throws -> String {
        let url = try OpenAIClient.makeURLRequest(request: request, model: "deepseek-v4-pro", apiKey: "k", stream: false)
        return String(decoding: url.httpBody ?? Data(), as: UTF8.self)
    }

    private func geminiBody(_ request: GeminiRequest) throws -> String {
        String(decoding: try LLMClient.encodeGeminiBody(request), as: UTF8.self)
    }

    @Test("a Gemini signature never reaches OpenAI or DeepSeek as reasoning_content; DeepSeek's own reasoning does")
    func openAISide() throws {
        let gemini = request(reply("answer", signature: "GEMINI-SIG", by: "gemini"))
        #expect(try openAIBody(gemini).contains("GEMINI-SIG"), "the bug: unfiltered, it's sent as reasoning")
        #expect(!(try openAIBody(HistoryProvenance.filtered(gemini, for: "deepseek"))).contains("GEMINI-SIG"))
        let own = request(reply("answer", signature: "DS-REASON", by: "deepseek"))
        #expect(try openAIBody(HistoryProvenance.filtered(own, for: "deepseek")).contains("DS-REASON"), "its own stays")
    }

    @Test("DeepSeek's reasoning never reaches Gemini as a thought signature; Gemini's own signature does")
    func geminiSide() throws {
        let deepseek = request(reply("answer", signature: "DS-REASON", by: "deepseek"))
        #expect(try geminiBody(deepseek).contains("DS-REASON"), "the bug: unfiltered, it's sent as a signature")
        #expect(!(try geminiBody(HistoryProvenance.filtered(deepseek, for: "gemini"))).contains("DS-REASON"))
        let own = request(reply("answer", signature: "GEMINI-SIG", by: "gemini"))
        #expect(try geminiBody(HistoryProvenance.filtered(own, for: "gemini")).contains("GEMINI-SIG"), "its own stays")
    }

    @Test("Anthropic's echoed blocks go only to Anthropic; text, tool calls and order always stay")
    func anthropicBlocksAndContent() {
        let entry = reply("answer", signature: nil, by: "anthropic", blocks: "[{\"type\":\"thinking\"}]")
        #expect(entry.forProvider("anthropic").anthropicBlocks != nil)
        let stripped = entry.forProvider("gemini")
        #expect(stripped.anthropicBlocks == nil)
        #expect(stripped.parts.first?.text == "answer")
        #expect(stripped.parts.last?.functionCall?.name == "read_file" && stripped.parts.last?.functionCall?.args == ["path": .string("/a")])
        #expect(stripped.producedBy == "anthropic", "the entry still says who wrote it")
    }

    @Test("an untagged entry, written before #1452, keeps what its own provider reads, byte for byte")
    func legacyOwnKind() throws {
        let gemini = request(reply("answer", signature: "Q2lnbmF0dXJlLWJ5dGVzLWZvci1hLXJlYWwtdHVybi1vZi1HZW1pbmk_x+/==", by: nil))
        #expect(try geminiBody(HistoryProvenance.filtered(gemini, for: "gemini")) == (try geminiBody(gemini)))
        let deepseek = request(reply("answer", signature: "The user wants the file, so read it first.", by: nil))
        #expect(try openAIBody(HistoryProvenance.filtered(deepseek, for: "deepseek")) == (try openAIBody(deepseek)))
        #expect(try openAIBody(HistoryProvenance.filtered(deepseek, for: "openai")) == (try openAIBody(deepseek)))
    }

    /// dev-2's #1455 probe: every conversation from before #1452 is untagged, and a switch must still not cross them.
    @Test("an untagged entry never sends a Gemini signature to an OpenAI-compatible provider, or reasoning to Gemini")
    func legacyOtherKind() throws {
        let signature = "Q2lnbmF0dXJlLWJ5dGVzLWZvci1hLXJlYWwtdHVybi1vZi1HZW1pbmk_x+/=="
        let gemini = request(reply("answer", signature: signature, by: nil))
        #expect(try openAIBody(gemini).contains(signature))
        #expect(!(try openAIBody(HistoryProvenance.filtered(gemini, for: "deepseek"))).contains(signature))
        let reasoning = "The user wants the file, so read it first."
        let deepseek = request(reply("answer", signature: reasoning, by: nil))
        #expect(try geminiBody(deepseek).contains(reasoning))
        let toGemini = HistoryProvenance.filtered(deepseek, for: "gemini")
        #expect(!(try geminiBody(toGemini)).contains(reasoning))
        #expect(toGemini.contents[0].parts[1].functionCall?.thoughtSignature == nil)
        #expect(toGemini.contents[0].parts[0].text == "answer")
        // A one-word answer is reasoning too, never taken for a signature (dev-2's #1455 re-review).
        let short = request(reply("answer", signature: "Reading", by: nil))
        #expect(!(try geminiBody(HistoryProvenance.filtered(short, for: "gemini"))).contains("Reading"))
        #expect(try openAIBody(HistoryProvenance.filtered(short, for: "deepseek")) == (try openAIBody(short)))
        // Anthropic's client sends neither kind, so its requests are as before.
        #expect(try geminiBody(HistoryProvenance.filtered(deepseek, for: "anthropic")) == (try geminiBody(deepseek)))
    }

    @Test("producedBy is never sent to Gemini, and it round-trips through history's JSON (an old row decodes as nil)")
    func wireAndStorage() throws {
        let entry = reply("answer", signature: nil, by: "gemini")
        #expect(!(try geminiBody(request(entry))).contains("producedBy"))
        let decoded = try JSONDecoder().decode(Content.self, from: try JSONEncoder().encode(entry))
        #expect(decoded.producedBy == "gemini")
        let old = try JSONDecoder().decode(Content.self, from: Data(#"{"role":"model","parts":[{"text":"x"}]}"#.utf8))
        #expect(old.producedBy == nil)
    }

    @Test("a client's producer id: a route's provider, else the primary family's slug")
    func producerId() {
        let route = ProviderRoute(providerId: "deepseek", target: .endpoint(baseURL: "https://api.deepseek.com/v1", apiKey: "k"),
                                  model: "deepseek-v4-pro")
        #expect(LLMClient.producerId(route: route, primary: "Anthropic") == "deepseek")
        #expect(LLMClient.producerId(route: nil, primary: LLMProvider.anthropic.rawValue) == "anthropic")
        #expect(LLMClient.producerId(route: nil, primary: LLMProvider.gemini.rawValue) == "gemini")
    }

    /// Both of `LLMClient`'s entry points filter before any client sees the request. They can't be driven without a
    /// network, so the wiring is pinned by its text, as `InboxRoutingTests` pins the inbox label's sites.
    @Test("LLMClient filters at both of its entry points, the stream and the one-shot call")
    func filteredAtBothEntryPoints() throws {
        let url = PerfPaths.repoRoot().appendingPathComponent("Sources/IrisKit/LLMClient.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        #expect(source.components(separatedBy: "let request = HistoryProvenance.filtered(request, for: producerId)").count - 1 == 2)
    }

    /// A client that says which provider it is, so the engine's tagging is visible.
    private final class NamedClient: LLMClientProtocol, @unchecked Sendable {
        let producerId: String?
        init(_ id: String) { producerId = id }
        func generateContent(request: GeminiRequest, tier: ModelTier) async throws -> GeminiResponse {
            GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [Part(text: "ok")]))], usageMetadata: nil)
        }
    }

    @Test("the engine tags each model reply with its client's provider")
    @MainActor
    func engineTags() async throws {
        let state = AppState(store: try ConversationStore.inMemory(), tier2Provisioning: .provisioned,
                             tier3Provisioning: .provisioned, createIfEmpty: false, emitLaunchNotices: false)
        let id = state.createNewConversation(isBackground: false, select: true)
        let engine = IrisEngine(state: state, tier: .medium, client: NamedClient("gemini"), retryDelays: [],
                                protectionEnabled: false, sessionPeerCount: 0)
        await engine.processInput("hello", source: "UI", conversationId: id)
        let history = state.conversations.first { $0.id == id }?.history ?? []
        #expect(history.contains { $0.role == "model" && $0.producedBy == "gemini" })
        #expect(history.filter { $0.role == "user" }.allSatisfy { $0.producedBy == nil })
    }
}
