import Testing
import Foundation
@testable import iris

@Suite("AnthropicCapabilities and the binding beta (#314)")
struct AnthropicCapabilitiesTests {
    static let vertex = AnthropicTransport.vertex(project: "iris-test-project", location: "global", accessToken: "t")
    static let direct = AnthropicTransport.direct(apiKey: "k", baseURL: "")

    private func header(_ model: String, _ transport: AnthropicTransport) throws -> String? {
        let r = GeminiRequest(contents: [Content(role: "user", parts: [Part(text: "hi")])], systemInstruction: nil, tools: nil)
        return try AnthropicClient.makeURLRequest(request: r, model: model, transport: transport, stream: true)
            .value(forHTTPHeaderField: "anthropic-beta")
    }

    @Test("the binding beta is known for exactly three models, under any date spelling",
          arguments: ["claude-opus-5-5", "claude-fable-5-1", "claude-sonnet-5-5",
                      "claude-opus-5-5-20261001", "claude-opus-5-5@20261001"])
    func checkModels(model: String) {
        #expect(AnthropicCapabilities.takesBindingBeta(model: model, transport: Self.direct))
    }

    @Test("everything else is not known to take the beta",
          arguments: ["claude-sonnet-5", "claude-fable-5", "claude-opus-5", "claude-mythos-5-1",
                      "claude-haiku-4-5-20251001", "claude-made-up-9", ""])
    func nonCheckModels(model: String) {
        #expect(!AnthropicCapabilities.takesBindingBeta(model: model, transport: Self.direct))
    }

    @Test("Opus 5.5 and Fable 5.1 get the header on both routes")
    func headerWhereProbed() throws {
        for model in ["claude-opus-5-5", "claude-fable-5-1"] {
            #expect(try header(model, Self.direct) == "thinking-binding-controls-2026-08-01", Comment(rawValue: model))
            #expect(try header(model, Self.vertex) == AnthropicCapabilities.bindingBeta, Comment(rawValue: model))
        }
    }

    @Test("Sonnet 5.5 gets the header on both routes (Vertex probe; the API follows it)")
    func sonnet55Header() throws {
        #expect(try header("claude-sonnet-5-5", Self.direct) == AnthropicCapabilities.bindingBeta)
        #expect(try header("claude-sonnet-5-5", Self.vertex) == AnthropicCapabilities.bindingBeta)
    }

    @Test("no beta header reaches an unknown id or a model without the check")
    func noHeaderElsewhere() throws {
        for model in ["claude-made-up-9", "claude-sonnet-5", "claude-haiku-4-5-20251001"] {
            #expect(try header(model, Self.direct) == nil, Comment(rawValue: model))
            #expect(try header(model, Self.vertex) == nil, Comment(rawValue: model))
        }
    }

    @Test("a custom base URL gets no binding beta, even for a probed model: a gateway may 400 on it")
    func noHeaderOnCustomBaseURL() throws {
        let custom = AnthropicTransport.direct(apiKey: "k", baseURL: "https://proxy.example")
        for model in ["claude-opus-5-5", "claude-fable-5-1", "claude-sonnet-5-5"] {
            #expect(try header(model, custom) == nil, Comment(rawValue: model))
            #expect(!AnthropicCapabilities.takesBindingBeta(model: model, transport: custom), Comment(rawValue: model))
        }
    }

    @Test("the default direct route and Vertex are unaffected by the custom-base-URL check")
    func headerStillSentOnDefaultRoutes() throws {
        #expect(try header("claude-opus-5-5", Self.direct) == AnthropicCapabilities.bindingBeta)
        #expect(try header("claude-opus-5-5", Self.vertex) == AnthropicCapabilities.bindingBeta)
    }

    @Test("the header adds nothing to the body: no thinking object, no block_binding")
    func bodyUnchanged() throws {
        let r = GeminiRequest(contents: [Content(role: "user", parts: [Part(text: "hi")])], systemInstruction: nil, tools: nil)
        let body = String(decoding: try AnthropicClient.makeURLRequest(request: r, model: "claude-opus-5-5",
                                                                       transport: Self.direct, stream: true).httpBody ?? Data(),
                          as: UTF8.self)
        #expect(!body.contains("thinking"))
        #expect(!body.contains("block_binding"))
    }

    @Test("an existing anthropic-beta header is merged into, not replaced")
    func mergesExistingBetaHeader() throws {
        let r = GeminiRequest(contents: [Content(role: "user", parts: [Part(text: "hi")])], systemInstruction: nil, tools: nil)
        var req = try AnthropicClient.makeURLRequest(request: r, model: "claude-sonnet-5", transport: Self.direct, stream: true)
        req.addValue("other-beta-2026-01-01", forHTTPHeaderField: "anthropic-beta")
        req.addValue(AnthropicCapabilities.bindingBeta, forHTTPHeaderField: "anthropic-beta")
        #expect(req.value(forHTTPHeaderField: "anthropic-beta") == "other-beta-2026-01-01,\(AnthropicCapabilities.bindingBeta)")
    }
}
