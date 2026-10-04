// Tests/irisTests/CachePolicyTests.swift
import Testing
import Foundation
@testable import iris

/// 5c §0.8/§0.9: the cache hints a request carries, and the policy that picks them.
@Suite struct CachePolicyTests {
    private static func request() -> GeminiRequest {
        GeminiRequest(contents: [Content(role: "user", parts: [Part(text: "hi")])],
                      systemInstruction: nil, tools: nil)
    }

    @Test func historyIsClampedToThePrefix() {
        #expect(CacheTTLPolicy(prefix: .fiveMinutes, history: .oneHour).history == .fiveMinutes)
        #expect(CacheTTLPolicy(prefix: .oneHour, history: .fiveMinutes).history == .fiveMinutes)
        #expect(CacheTTLPolicy(prefix: .oneHour, history: .oneHour).history == .oneHour)
    }

    /// Review focus 5: an encoded hint is an unknown field to Gemini (HTTP 400).
    @Test func geminiBodyIsByteIdenticalWithHints() throws {
        var request = Self.request()
        let plain = try LLMClient.encodeGeminiBody(request)
        request.cacheHints = CacheHints(ttl: .init(prefix: .oneHour, history: .oneHour), promptCacheKey: "k")
        #expect(try LLMClient.encodeGeminiBody(request) == plain)
        #expect(!(String(data: plain, encoding: .utf8) ?? "").contains("cacheHints"))
    }

    /// Review focus 5: the hook payload is the same type's JSON, so it must not grow a key either.
    @Test func hookPayloadCarriesNoHints() throws {
        var request = Self.request()
        let plain = try #require(HookManager.beforeModelPayload(request))
        request.cacheHints = CacheHints(ttl: .init(prefix: .oneHour, history: .oneHour), promptCacheKey: "k")
        let hinted = try #require(HookManager.beforeModelPayload(request))
        // The hook payload isn't key-sorted, so compare the parsed objects, not the bytes.
        let a = try #require(try JSONSerialization.jsonObject(with: plain) as? NSDictionary)
        let b = try #require(try JSONSerialization.jsonObject(with: hinted) as? NSDictionary)
        #expect(a == b)
        #expect(Set((b as? [String: Any])?.keys.map { $0 } ?? []) == ["contents"])
        #expect(!(String(data: hinted, encoding: .utf8) ?? "").contains("cacheHints"))
    }

    /// Review focus 5: a `BeforeModel` rewrite decodes a fresh request with no hints, which would
    /// silently drop Iris back to five minutes. The engine re-applies them through this function.
    /// `HookManager.shared` is the only hook seam the engine has, so this tests the function the
    /// engine calls rather than a hook installed in process-global config (invariant 7).
    @Test func beforeModelRewriteKeepsHints() throws {
        var original = Self.request()
        let hints = CacheHints(ttl: .init(prefix: .oneHour, history: .oneHour), promptCacheKey: "conv")
        original.cacheHints = hints
        let rewritten = #"{"contents":[{"role":"user","parts":[{"text":"rewritten"}]}]}"#.data(using: .utf8)!
        let applied = IrisEngine.applyHookRewrite(rewritten, to: original)
        #expect(applied.contents.first?.parts.first?.text == "rewritten")
        #expect(applied.cacheHints == hints)
    }

    @Test func undecodableRewriteKeepsTheOriginal() {
        var original = Self.request()
        original.cacheHints = CacheHints(promptCacheKey: "conv")
        let applied = IrisEngine.applyHookRewrite(Data("not json".utf8), to: original)
        #expect(applied.contents.first?.parts.first?.text == "hi")
        #expect(applied.cacheHints == original.cacheHints)
    }
}
