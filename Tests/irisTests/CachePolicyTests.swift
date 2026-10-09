// Tests/irisTests/CachePolicyTests.swift
import Testing
import Foundation
@testable import IrisKit

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

/// 5c §0.8: which conversation gets which TTL, and which jobs keep the background prefix warm.
@Suite struct CachePolicyResolveTests {
    @Test func policyByConversation() {
        #expect(CacheTTLPolicy.resolve(isPinned: true, isUnattended: false, principal: .main, backgroundFiresHourly: false)
                == .init(prefix: .oneHour, history: .oneHour))
        #expect(CacheTTLPolicy.resolve(isPinned: false, isUnattended: true, principal: .main, backgroundFiresHourly: true)
                == .init(prefix: .oneHour, history: .fiveMinutes))
        #expect(CacheTTLPolicy.resolve(isPinned: false, isUnattended: true, principal: .main, backgroundFiresHourly: false)
                == .standard)
        #expect(CacheTTLPolicy.resolve(isPinned: false, isUnattended: false, principal: .main, backgroundFiresHourly: true)
                == .standard)
        // A subagent of Iris is not Iris.
        #expect(CacheTTLPolicy.resolve(isPinned: true, isUnattended: false, principal: .subagent, backgroundFiresHourly: true)
                == .standard)
        #expect(CacheTTLPolicy.resolve(isPinned: false, isUnattended: true, principal: .evaluator, backgroundFiresHourly: true)
                == .standard)
    }

    @Test func cadence() throws {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        func job(_ t: Trigger, enabled: Bool = true, paused: String? = nil, action: JobAction = .prompt) -> Job {
            var j = Job(name: "j", prompt: "p", trigger: t)
            j.enabled = enabled; j.pausedReason = paused; j.action = action
            return j
        }
        let every15 = Trigger.schedule(.interval(seconds: 900))
        #expect(JobCadence.anyFiresMoreOftenThanHourly([job(every15)], now: now))
        #expect(!JobCadence.anyFiresMoreOftenThanHourly([job(.schedule(.interval(seconds: 3600)))], now: now))
        #expect(!JobCadence.anyFiresMoreOftenThanHourly([job(every15, enabled: false)], now: now))
        #expect(!JobCadence.anyFiresMoreOftenThanHourly([job(every15, paused: "x")], now: now))
        #expect(!JobCadence.anyFiresMoreOftenThanHourly([job(every15, action: .builtin("digest"))], now: now))
        let cron = CronSchedule(expression: "*/20 9-17 * * 1-5", timeZone: "UTC")
        #expect(JobCadence.anyFiresMoreOftenThanHourly([job(.schedule(.cron(cron)))], now: now))
        let daily = CronSchedule(expression: "0 10 * * *", timeZone: "UTC")
        #expect(!JobCadence.anyFiresMoreOftenThanHourly([job(.schedule(.cron(daily)))], now: now))
        // Plan note 13: a poll ticks often but runs a model turn only on CHANGED.
        let poll = Job(name: "p", prompt: "p", trigger: .poll(PollSpec(schedule: .interval(seconds: 60), gate: .pathChanged(path: "/tmp"))))
        #expect(!JobCadence.anyFiresMoreOftenThanHourly([poll], now: now))
        #expect(JobCadence.anyFiresMoreOftenThanHourly([job(.schedule(.cron(daily))), job(every15)], now: now))
    }
}

/// 5c §0.9: OpenAI's one cache-routing field.
@Suite struct OpenAIPromptCacheKeyTests {
    private static let plain = GeminiRequest(contents: [Content(role: "user", parts: [Part(text: "hi")])],
                                             systemInstruction: nil, tools: nil)

    private func body(_ r: GeminiRequest) throws -> [String: Any] {
        let req = try OpenAIClient.makeURLRequest(request: r, model: "m", apiKey: "k", stream: false)
        let data = try #require(req.httpBody)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func sendsPromptCacheKey() throws {
        var r = Self.plain
        let id = UUID().uuidString
        r.cacheHints = CacheHints(promptCacheKey: id)
        #expect(try body(r)["prompt_cache_key"] as? String == id)
    }

    @Test func noHintsNoKeyAndLongKeysAreByteCapped() throws {
        #expect(try body(Self.plain)["prompt_cache_key"] == nil)
        var empty = Self.plain
        empty.cacheHints = CacheHints(promptCacheKey: "")
        #expect(try body(empty)["prompt_cache_key"] == nil)
        var long = Self.plain
        long.cacheHints = CacheHints(promptCacheKey: String(repeating: "é", count: 40))   // 80 bytes
        let key = try #require(try body(long)["prompt_cache_key"] as? String)
        #expect(key.utf8.count <= 64)
        #expect(key == String(repeating: "é", count: 32), "cut on a character boundary, not mid-scalar")
    }

    @Test func hintsWithoutAKeyChangeNoBytes() throws {
        var r = Self.plain
        let a = try OpenAIClient.makeURLRequest(request: r, model: "m", apiKey: "k", stream: false).httpBody
        r.cacheHints = CacheHints(ttl: .init(prefix: .oneHour, history: .oneHour))
        #expect(try OpenAIClient.makeURLRequest(request: r, model: "m", apiKey: "k", stream: false).httpBody == a)
    }
}
