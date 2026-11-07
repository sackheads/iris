import Testing
import Foundation
@testable import IrisKit

@Suite("Reasoning effort and thinking display (#314 PR 7)")
struct ReasoningEffortTests {
    private static let direct = AnthropicTransport.direct(apiKey: "k", baseURL: "")

    private func body(_ model: String, effort: String?, binding: PrefixMismatchBehavior? = nil) throws -> [String: Any] {
        var r = GeminiRequest(contents: [Content(role: "user", parts: [Part(text: "hi")])], systemInstruction: nil, tools: nil)
        r.reasoningEffort = effort
        r.prefixMismatchBehavior = binding
        let u = try AnthropicClient.makeURLRequest(request: r, model: model, transport: Self.direct, stream: true)
        return try #require(JSONSerialization.jsonObject(with: u.httpBody ?? Data()) as? [String: Any])
    }

    private func store() -> (UserDefaults, () -> Void) {
        let name = "iris-effort-\(UUID().uuidString)"
        let s = UserDefaults(suiteName: name)!
        return (s, {
            s.removePersistentDomain(forName: name)
            IrisDefaults.removeSuiteFile(named: name, in: IrisDefaults.preferencesDirectory)
        })
    }

    // MARK: request

    @Test("an unset effort sends no output_config, for any model", arguments: ["claude-opus-5-5", "claude-fable-5-1", "claude-sonnet-5-5"])
    func unsetSendsNothing(model: String) throws {
        #expect(try body(model, effort: nil)["output_config"] == nil)
    }

    @Test("a listed level goes out as output_config.effort", arguments: AnthropicCapabilities.effortScale)
    func listedLevel(level: String) throws {
        let b = try body("claude-opus-5-5", effort: level)
        #expect((b["output_config"] as? [String: String]) == ["effort": level])
    }

    @Test("a level the model does not list is never sent", arguments: ["none", "minimal", "ultra", ""])
    func unlistedLevel(level: String) throws {
        #expect(try body("claude-opus-5-5", effort: level)["output_config"] == nil)
    }

    @Test("a model the table does not know is sent no effort and no display", arguments: ["claude-made-up-9", "claude-haiku-4-5-20251001", "claude-sonnet-5"])
    func unknownModel(model: String) throws {
        let b = try body(model, effort: "high")
        #expect(b["output_config"] == nil)
        #expect(b["thinking"] == nil)
    }

    @Test("an effort pick asks for summarized thinking, adaptive, without a new beta header", arguments: ["claude-opus-5-5", "claude-fable-5-1", "claude-sonnet-5-5"])
    func displayWithPick(model: String) throws {
        let thinking = try #require(try body(model, effort: "high")["thinking"] as? [String: Any])
        #expect(thinking["type"] as? String == "adaptive")
        #expect(thinking["display"] as? String == "summarized")
        var r = GeminiRequest(contents: [Content(role: "user", parts: [Part(text: "hi")])], systemInstruction: nil, tools: nil)
        r.reasoningEffort = "high"
        let u = try AnthropicClient.makeURLRequest(request: r, model: model, transport: Self.direct, stream: true)
        #expect(u.value(forHTTPHeaderField: "anthropic-beta") == AnthropicCapabilities.bindingBeta)   // the binding beta only
    }

    @Test("with no effort picked the request has no thinking object, as before", arguments: ["claude-opus-5-5", "claude-fable-5-1", "claude-sonnet-5-5"])
    func unchangedUntilPicked(model: String) throws {
        let b = try body(model, effort: nil)
        #expect(b["thinking"] == nil && b["output_config"] == nil)
    }

    @Test("display and the binding share one thinking object")
    func displayWithBinding() throws {
        let thinking = try #require(try body("claude-opus-5-5", effort: "low", binding: .dropBlock)["thinking"] as? [String: Any])
        #expect(thinking["display"] as? String == "summarized")
        #expect((thinking["block_binding"] as? [String: String]) == ["prefix_mismatch_behavior": "drop_block"])
    }

    @Test("a BeforeModel rewrite keeps the effort")
    func hookRewriteKeepsEffort() throws {
        var r = GeminiRequest(contents: [Content(role: "user", parts: [Part(text: "hi")])], systemInstruction: nil, tools: nil)
        r.reasoningEffort = "max"
        let data = try JSONEncoder().encode(r)
        #expect(IrisEngine.applyHookRewrite(data, to: r).reasoningEffort == "max")
    }

    // MARK: setting

    @Test("the settings default to unset and round-trip through the store")
    func settingsRoundTrip() {
        let (s, cleanup) = store(); defer { cleanup() }
        let c = ConfigManager(store: s)
        #expect(c.anthropicEffortEasy == "" && c.anthropicEffortMedium == "" && c.anthropicEffortHard == "")
        c.anthropicEffortMedium = "high"
        c.anthropicEffortHard = "max"
        let again = ConfigManager(store: s)
        #expect(again.anthropicEffortMedium == "high" && again.anthropicEffortHard == "max" && again.anthropicEffortEasy == "")
        #expect(again.anthropicEffort(for: .hard) == "max")
    }

    @Test("a stored word the model does not list reads as none; a listed one is sent")
    func resolution() {
        let (s, cleanup) = store(); defer { cleanup() }
        let c = ConfigManager(store: s)
        c.anthropicEffortMedium = "bogus"
        #expect(c.reasoningEffort(for: .medium, model: "claude-opus-5-5") == nil)
        c.anthropicEffortMedium = "xhigh"
        #expect(c.reasoningEffort(for: .medium, model: "claude-opus-5-5") == "xhigh")
        #expect(c.reasoningEffort(for: .medium, model: "claude-haiku-4-5-20251001") == nil)   // a model with none
        #expect(c.reasoningEffort(for: .easy, model: "claude-opus-5-5") == nil)               // unset tier
    }

    @Test("the table lists the probed five levels, in order, for the three known models and none for others")
    func tableLevels() {
        for model in ["claude-opus-5-5", "claude-fable-5-1@20261001", "claude-sonnet-5-5"] {
            #expect(AnthropicCapabilities.effortLevels(model: model) == ["low", "medium", "high", "xhigh", "max"], Comment(rawValue: model))
        }
        #expect(AnthropicCapabilities.effortLevels(model: "claude-made-up-9").isEmpty)
    }

    // MARK: display

    @MainActor
    @Test("thinking notes keep only the tail, per conversation, and clear")
    func notes() {
        let notes = ThinkingNotes()
        let a = UUID(), b = UUID()
        notes.append(String(repeating: "x", count: 300) + "END", to: a)
        notes.append("other", to: b)
        #expect(notes.note(for: a).text.count == ThinkingNotes.tailLimit)
        #expect(notes.note(for: a).text.hasSuffix("END"))
        #expect(notes.note(for: b).text == "other")
        notes.clear(a)
        #expect(notes.note(for: a).text.isEmpty && notes.note(for: b).text == "other")
    }

    @Test("the assembler drops thinking text: it is not a token and not part of the reply")
    func assemblerIgnores() {
        var a = StreamAssembler()
        a.apply(.thinkingText("pondering"), now: 5)
        #expect(a.firstTokenAt == nil)
        #expect(a.response().candidates?.first?.content?.parts.isEmpty ?? true)
    }

    @Test("an empty thinking delta emits nothing")
    func emptyDelta() throws {
        var mapper = AnthropicStreamMapper()
        _ = try mapper.handle(SSEEvent(event: "content_block_start", data: #"{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}"#))
        let out = try mapper.handle(SSEEvent(event: "content_block_delta", data: #"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":""}}"#))
        #expect(out.isEmpty)
    }
}
