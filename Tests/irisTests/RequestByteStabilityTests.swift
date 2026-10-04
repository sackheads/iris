// Tests/irisTests/RequestByteStabilityTests.swift
import Testing
import Foundation
@testable import iris

/// Confirms every client's `makeURLRequest` encodes two *separately built* but logically equal
/// requests to byte-identical bodies (5a §0.1). Two separate dictionaries are built in opposite
/// key-insertion order, each with at least eight keys: `JSONSerialization`/`JSONEncoder` without
/// `.sortedKeys` do not guarantee a stable key order across calls, even for structurally identical
/// content (confirmed independently in `RequestDumpTests`), and insertion order is exactly what
/// perturbs a `Dictionary`'s internal bucket layout. A single value encoded twice can pass by luck
/// even when the encoding is unstable; building two values is what actually exercises it.
@Suite("Request byte stability (5a)")
struct RequestByteStabilityTests {
    enum Order { case forward, reversed }

    /// Eight distinct keys: enough that opposite insertion order reliably produces a different
    /// `Dictionary` bucket layout for the same content.
    private static let keys = ["alpha", "bravo", "charlie", "delta", "echo", "foxtrot", "golf", "hotel"]

    private static func orderedKeys(_ order: Order) -> [String] {
        order == .forward ? keys : Array(keys.reversed())
    }

    private static func schemaProperties(order: Order) -> [String: Schema] {
        var dict: [String: Schema] = [:]
        for k in orderedKeys(order) {
            dict[k] = Schema(type: "STRING", description: "the \(k) field")
        }
        return dict
    }

    /// The value is derived from the key itself, not from its position in `orderedKeys` — the
    /// two builds must hold identical content and differ only in insertion order, or a mismatch
    /// would reflect a real content difference rather than key-order instability.
    private static func argValues(order: Order) -> [String: JSONValue] {
        var dict: [String: JSONValue] = [:]
        for k in orderedKeys(order) {
            dict[k] = .string("value-\(k)")
        }
        return dict
    }

    /// One request with: a tool schema with >= 8 properties, and history containing both a
    /// function call and a function response whose payloads have >= 8 keys each — the three
    /// spots (schema, call args, response payload) that each client re-serialises separately.
    private static func request(order: Order) -> GeminiRequest {
        let system = Content(role: "system", parts: [
            Part(text: "be nice", functionCall: nil, functionResponse: nil, thought_signature: nil, thoughtSignature: nil)
        ])

        let call = FunctionCall(name: "do_thing", args: argValues(order: order), id: "call_1")
        let callContent = Content(role: "model", parts: [
            Part(text: nil, functionCall: call, functionResponse: nil, thought_signature: nil, thoughtSignature: nil)
        ])

        let response = FunctionResponse(name: "do_thing", response: argValues(order: order), id: "call_1")
        let responseContent = Content(role: "user", parts: [
            Part(text: nil, functionCall: nil, functionResponse: response, thought_signature: nil, thoughtSignature: nil)
        ])

        let current = Content(role: "user", parts: [
            Part(text: "go", functionCall: nil, functionResponse: nil, thought_signature: nil, thoughtSignature: nil)
        ])

        let schema = Schema(type: "OBJECT", properties: schemaProperties(order: order))
        let declaration = FunctionDeclaration(name: "do_thing", description: "does the thing", parameters: schema)
        let tool = Tool(functionDeclarations: [declaration])

        return GeminiRequest(contents: [callContent, responseContent, current], systemInstruction: system, tools: [tool])
    }

    @Test("Anthropic: two equal requests built separately encode to identical bytes")
    func anthropicStable() throws {
        let a = try AnthropicClient.makeURLRequest(request: Self.request(order: .forward), model: "m", apiKey: "k", stream: false).httpBody
        let b = try AnthropicClient.makeURLRequest(request: Self.request(order: .reversed), model: "m", apiKey: "k", stream: false).httpBody
        #expect(a == b)
    }

    @Test("OpenAI: two equal requests built separately encode to identical bytes")
    func openAIStable() throws {
        let a = try OpenAIClient.makeURLRequest(request: Self.request(order: .forward), model: "m", apiKey: "k", stream: false).httpBody
        let b = try OpenAIClient.makeURLRequest(request: Self.request(order: .reversed), model: "m", apiKey: "k", stream: false).httpBody
        #expect(a == b)
    }

    /// Gemini's `makeGeminiURLRequest` is an instance method that reads `ConfigManager.shared`
    /// and performs an async ADC handshake before it ever touches the body (AGENTS.md invariant
    /// 7 forbids mutating that shared, process-global config in a test). `LLMClient.encodeGeminiBody`
    /// is the pure, synchronous body builder it and `RequestDump` both call — the wire body is
    /// nothing else, so exercising it directly covers the real encoding without touching config.
    @Test("Gemini: two equal requests built separately encode to identical bytes")
    func geminiStable() throws {
        let a = try LLMClient.encodeGeminiBody(Self.request(order: .forward))
        let b = try LLMClient.encodeGeminiBody(Self.request(order: .reversed))
        #expect(a == b)
    }

    /// 5c: hints change what a body says (a TTL, a cache key), never whether it is stable.
    @Test("with cache hints, every client still encodes two equal requests identically")
    func stableWithHints() throws {
        func hinted(_ order: Order) -> GeminiRequest {
            var r = Self.request(order: order)
            r.cacheHints = CacheHints(ttl: .init(prefix: .oneHour, history: .oneHour), promptCacheKey: "conv")
            return r
        }
        #expect(try AnthropicClient.makeURLRequest(request: hinted(.forward), model: "m", apiKey: "k", stream: false).httpBody
                == AnthropicClient.makeURLRequest(request: hinted(.reversed), model: "m", apiKey: "k", stream: false).httpBody)
        #expect(try OpenAIClient.makeURLRequest(request: hinted(.forward), model: "m", apiKey: "k", stream: false).httpBody
                == OpenAIClient.makeURLRequest(request: hinted(.reversed), model: "m", apiKey: "k", stream: false).httpBody)
        #expect(try LLMClient.encodeGeminiBody(hinted(.forward)) == LLMClient.encodeGeminiBody(hinted(.reversed)))
    }
}
