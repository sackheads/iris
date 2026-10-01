// Tests/irisTests/RequestDumpTests.swift
import Testing
import Foundation
@testable import iris

@Suite("RequestDump (5a)")
struct RequestDumpTests {
    private var request: GeminiRequest {
        let user = Content(role: "user", parts: [Part(text: "hello", functionCall: nil, functionResponse: nil, thought_signature: nil, thoughtSignature: nil)])
        let system = Content(role: "system", parts: [Part(text: "be nice", functionCall: nil, functionResponse: nil, thought_signature: nil, thoughtSignature: nil)])
        return GeminiRequest(contents: [user], systemInstruction: system, tools: nil)
    }

    /// Compares parsed structure (`NSDictionary` equality is order-independent), not raw bytes,
    /// because this predates sorted-key encoding: `JSONSerialization.data(withJSONObject:)` (used
    /// by both `AnthropicClient.makeURLRequest` and `OpenAIClient.makeURLRequest`) did not
    /// guarantee a stable key order across calls, even for structurally identical dictionaries in
    /// the same process — confirmed independently while writing this test, and now fixed (5a:
    /// every request-path `JSONSerialization`/`JSONEncoder` sorts keys; see
    /// `RequestByteStabilityTests` for the byte-identity check this test did not attempt).
    @Test("Anthropic dump matches makeURLRequest's own body structurally")
    func anthropicMatchesProduction() throws {
        let expected = try AnthropicClient.makeURLRequest(request: request, model: "claude-x", apiKey: "real-key-never-used-here", stream: false).httpBody
        let dumped = try RequestDump.body(for: request, provider: LLMProvider.anthropic.rawValue, model: "claude-x", stream: false)
        let expectedObj = try JSONSerialization.jsonObject(with: try #require(expected)) as? NSDictionary
        let dumpedObj = try JSONSerialization.jsonObject(with: dumped) as? NSDictionary
        #expect(expectedObj == dumpedObj)
    }

    @Test("OpenAI dump matches makeURLRequest's own body structurally")
    func openAIMatchesProduction() throws {
        let expected = try OpenAIClient.makeURLRequest(request: request, model: "gpt-x", apiKey: "real-key-never-used-here", stream: false).httpBody
        let dumped = try RequestDump.body(for: request, provider: LLMProvider.openai.rawValue, model: "gpt-x", stream: false)
        let expectedObj = try JSONSerialization.jsonObject(with: try #require(expected)) as? NSDictionary
        let dumpedObj = try JSONSerialization.jsonObject(with: dumped) as? NSDictionary
        #expect(expectedObj == dumpedObj)
    }

    /// Production streams by default (`ConfigManager.streamResponses` defaults to `true`); a dump
    /// built with `stream: false` unconditionally would not match the body a real turn sends
    /// (5a review #11).
    @Test("Anthropic dump honors a true streaming flag, matching makeURLRequest(stream: true)")
    func anthropicHonorsStreamingFlag() throws {
        let expected = try AnthropicClient.makeURLRequest(request: request, model: "claude-x", apiKey: "real-key-never-used-here", stream: true).httpBody
        let dumped = try RequestDump.body(for: request, provider: LLMProvider.anthropic.rawValue, model: "claude-x", stream: true)
        let expectedObj = try JSONSerialization.jsonObject(with: try #require(expected)) as? NSDictionary
        let dumpedObj = try JSONSerialization.jsonObject(with: dumped) as? NSDictionary
        #expect(expectedObj == dumpedObj)
        #expect((dumpedObj?["stream"] as? Bool) == true)
    }

    @Test("OpenAI dump honors a true streaming flag, matching makeURLRequest(stream: true)")
    func openAIHonorsStreamingFlag() throws {
        let expected = try OpenAIClient.makeURLRequest(request: request, model: "gpt-x", apiKey: "real-key-never-used-here", stream: true).httpBody
        let dumped = try RequestDump.body(for: request, provider: LLMProvider.openai.rawValue, model: "gpt-x", stream: true)
        let expectedObj = try JSONSerialization.jsonObject(with: try #require(expected)) as? NSDictionary
        let dumpedObj = try JSONSerialization.jsonObject(with: dumped) as? NSDictionary
        #expect(expectedObj == dumpedObj)
        #expect((dumpedObj?["stream"] as? Bool) == true)
    }

    @Test("Gemini dump is the request's own JSON encoding")
    func geminiIsPlainEncoding() throws {
        let dumped = try RequestDump.body(for: request, provider: LLMProvider.gemini.rawValue, model: "gemini-x", stream: false)
        let decoded = try JSONDecoder().decode(GeminiRequest.self, from: dumped)
        #expect(decoded.contents.first?.parts.first?.text == "hello")
        #expect(decoded.systemInstruction?.parts.first?.text == "be nice")
    }

    @Test("an unrecognized provider name falls back to the Gemini encoding")
    func unknownProviderFallsBackToGemini() throws {
        let dumped = try RequestDump.body(for: request, provider: "SomeFutureProvider", model: "m", stream: false)
        #expect((try? JSONDecoder().decode(GeminiRequest.self, from: dumped)) != nil)
    }
}
