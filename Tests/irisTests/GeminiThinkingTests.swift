import Testing
import Foundation
@testable import IrisKit

/// #1019: Gemini's per-tier thinking level, live thought summaries, and the fallback for a route
/// that 400s either field.
@Suite("Gemini thinking level and thought summaries (#1019)", .timeLimit(.minutes(1)))
struct GeminiThinkingTests {
    private func isolated() -> (ConfigManager, UserDefaults, () -> Void) {
        let name = "iris-geminithink-\(UUID().uuidString)"
        let store = UserDefaults(suiteName: name)!
        return (ConfigManager(store: store), store, {
            store.removePersistentDomain(forName: name)
            IrisDefaults.removeSuiteFile(named: name, in: IrisDefaults.preferencesDirectory)
        })
    }

    private func key() -> String { "test|\(UUID().uuidString)|model" }

    private func body(_ request: GeminiRequest) throws -> [String: Any] {
        let data = try LLMClient.encodeGeminiBody(request)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private let empty = GeminiRequest(contents: [Content(role: "user", parts: [Part(text: "hi")])], systemInstruction: nil, tools: nil)

    // MARK: config

    @Test("each tier reads its own level; empty, unknown and hand-edited words read as none")
    func perTierResolution() {
        let (config, store, cleanup) = isolated(); defer { cleanup() }
        for tier in [ModelTier.easy, .medium, .hard] { #expect(config.geminiThinkingLevel(for: tier) == nil) }
        config.geminiThinkingLevelEasy = "minimal"
        config.geminiThinkingLevelMedium = "low"
        config.geminiThinkingLevelHard = "high"
        #expect(config.geminiThinkingLevel(for: .easy) == "minimal")
        #expect(config.geminiThinkingLevel(for: .medium) == "low")
        #expect(config.geminiThinkingLevel(for: .hard) == "high")
        config.geminiThinkingLevelHard = "ludicrous"
        #expect(config.geminiThinkingLevel(for: .hard) == nil)

        let again = ConfigManager(store: store)
        #expect(again.geminiThinkingLevel(for: .easy) == "minimal", "persisted")
        #expect(again.geminiThinkingLevel(for: .hard) == nil, "a stored unknown word still reads as none")
    }

    @Test("the tier's level goes to a chat call, never to a guard call or a named model, and the request's own wins")
    func resolution() {
        let (config, _, cleanup) = isolated(); defer { cleanup() }
        config.geminiThinkingLevelEasy = "minimal"
        var chat = empty
        #expect(LLMClient.resolvedThinkingLevel(request: chat, tier: .easy, config: config, modelOverride: false) == "minimal")
        #expect(LLMClient.resolvedThinkingLevel(request: chat, tier: .medium, config: config, modelOverride: false) == nil)
        #expect(LLMClient.resolvedThinkingLevel(request: chat, tier: .easy, config: config, modelOverride: true) == nil)
        var guardCall = empty
        guardCall.ignoresTierThinkingLevel = true
        #expect(LLMClient.resolvedThinkingLevel(request: guardCall, tier: .easy, config: config, modelOverride: false) == nil,
                "a guard that fell back to the easy tier's model must not take the user's easy level")
        chat.thinkingLevel = "low"
        #expect(LLMClient.resolvedThinkingLevel(request: chat, tier: .easy, config: config, modelOverride: false) == "low")
    }

    @Test("the guard's cloud engine marks its requests")
    func guardMarks() throws {
        let source = try String(contentsOf: PerfPaths.repoRoot().appendingPathComponent("Sources/IrisKit/CloudAuxiliaryEngine.swift"), encoding: .utf8)
        #expect(source.contains("request.ignoresTierThinkingLevel = true"))
    }

    // MARK: wire

    @Test("a request with neither field is byte-identical to before")
    func unchangedBody() throws {
        let plain = try LLMClient.encodeGeminiBody(empty)
        #expect(try body(empty)["generationConfig"] == nil)
        #expect(String(decoding: plain, as: UTF8.self).contains("thinkingConfig") == false)
    }

    @Test("the level and includeThoughts land in generationConfig.thinkingConfig")
    func wireShape() throws {
        var r = empty
        r.thinkingLevel = "low"
        r.includeThoughts = true
        let gen = try #require(try body(r)["generationConfig"] as? [String: Any])
        let config = try #require(gen["thinkingConfig"] as? [String: Any])
        #expect(config["thinkingLevel"] as? String == "low")
        #expect(config["includeThoughts"] as? Bool == true)

        var only = empty
        only.includeThoughts = true
        let gen2 = try #require(try body(only)["generationConfig"] as? [String: Any])
        let c2 = try #require(gen2["thinkingConfig"] as? [String: Any])
        #expect(c2["thinkingLevel"] == nil && c2["includeThoughts"] as? Bool == true)
    }

    // MARK: stream mapper

    @Test("a thought part is a status-line fragment, never reply text; the answer stays text")
    func mapperSplitsThoughts() throws {
        var mapper = GeminiStreamMapper()
        let chunk = #"{"candidates":[{"content":{"parts":[{"text":"Weighing it","thought":true},{"text":"Answer"}]}}]}"#
        let events = try mapper.handle(SSEEvent(event: nil, data: chunk))
        #expect(events == [.thinkingText("Weighing it"), .textDelta("Answer")])
    }

    @Test("a part without the flag decodes as before, and a request never encodes one")
    func partFlagIsOptional() throws {
        let part = try JSONDecoder().decode(Part.self, from: Data(#"{"text":"x"}"#.utf8))
        #expect(part.thought == nil)
        let encoded = String(decoding: try JSONEncoder().encode(Part(text: "x")), as: UTF8.self)
        #expect(!encoded.contains("thought\""))
    }

    // MARK: fallback

    @Test("the ladder drops each field alone, then both; known refusals are left out")
    func ladderShape() {
        let k = key()
        #expect(GeminiThinkingFallback.ladder(key: k, level: "low", includeThoughts: true) == [
            .init(level: "low", includeThoughts: true), .init(level: nil, includeThoughts: true),
            .init(level: "low", includeThoughts: false), .init(level: nil, includeThoughts: false)])
        #expect(GeminiThinkingFallback.ladder(key: k, level: nil, includeThoughts: false) == [.init(level: nil, includeThoughts: false)])
        #expect(GeminiThinkingFallback.ladder(key: k, level: nil, includeThoughts: true).count == 2)
    }

    @Test("a 400 for the level alone drops only the level, and the next call does not retry it")
    func levelRefusedOnce() async throws {
        let k = key()
        let seen = Sent()
        let r1: String = try await GeminiThinkingFallback.run(key: k, level: "minimal", includeThoughts: true) { rung in
            await seen.add(rung)
            if rung.level != nil { throw APIError(message: "bad level", statusCode: 400) }
            return "ok"
        }
        #expect(r1 == "ok")
        #expect(await seen.all == [.init(level: "minimal", includeThoughts: true), .init(level: nil, includeThoughts: true)])
        #expect(GeminiThinkingFallback.levelRefused(key: k, level: "minimal"))
        #expect(!GeminiThinkingFallback.thoughtsRefused(key: k), "thoughts were accepted, so they are not blamed")

        let second = Sent()
        _ = try await GeminiThinkingFallback.run(key: k, level: "minimal", includeThoughts: true) { rung in await second.add(rung); return "ok" }
        #expect(await second.all == [.init(level: nil, includeThoughts: true)], "one round trip, with no level")
        #expect(!GeminiThinkingFallback.levelRefused(key: k, level: "high"), "another level is its own question")
    }

    @Test("a route that refuses both ends with neither, and remembers both")
    func bothRefused() async throws {
        let k = key()
        let r: String = try await GeminiThinkingFallback.run(key: k, level: "low", includeThoughts: true) { rung in
            if rung.level != nil || rung.includeThoughts { throw APIError(message: "unknown field", statusCode: 400) }
            return "ok"
        }
        #expect(r == "ok")
        #expect(GeminiThinkingFallback.levelRefused(key: k, level: "low") && GeminiThinkingFallback.thoughtsRefused(key: k))
    }

    @Test("a 400 that every rung gets (the prompt) throws the first error and remembers nothing")
    func promptFourHundredBlamesNothing() async {
        let k = key()
        let outcome: Result<String, Error> = await Result {
            try await GeminiThinkingFallback.run(key: k, level: "low", includeThoughts: true) { _ in
                throw APIError(message: "prompt too large", statusCode: 400)
            }
        }
        guard case .failure(let error) = outcome else { Issue.record("should have thrown"); return }
        #expect((error as? APIError)?.message == "prompt too large")
        #expect(!GeminiThinkingFallback.levelRefused(key: k, level: "low") && !GeminiThinkingFallback.thoughtsRefused(key: k))
    }

    @Test("an unladdered call (the guard's) sends once and lets its 400 through to sendAsking")
    func guardOwnsItsFourHundred() async {
        let k = key()
        let sent = Sent()
        let outcome: Result<String, Error> = await Result {
            try await GeminiThinkingFallback.run(key: k, level: "low", includeThoughts: false, laddered: false) { rung in
                await sent.add(rung)
                throw APIError(message: "no level", statusCode: 400)
            }
        }
        #expect(outcome.isFailure)
        #expect(await sent.all == [.init(level: "low", includeThoughts: false)])
        #expect(!GeminiThinkingFallback.levelRefused(key: k, level: "low"))
    }

    @Test("the client ladders every call but the guard's")
    func clientPassesLaddered() throws {
        let source = try String(contentsOf: PerfPaths.repoRoot().appendingPathComponent("Sources/IrisKit/LLMClient.swift"), encoding: .utf8)
        #expect(source.contains("laddered: !asked.ignoresTierThinkingLevel"))
    }

    @Test("a signature on a thought part is forwarded, not dropped, and the answer's own replaces it")
    func thoughtPartSignature() throws {
        var mapper = GeminiStreamMapper()
        let chunk = #"{"candidates":[{"content":{"parts":[{"text":"hm","thought":true,"thoughtSignature":"SIG1"},{"text":"Answer","thoughtSignature":"SIG2"}]}}]}"#
        let events = try mapper.handle(SSEEvent(event: nil, data: chunk))
        #expect(events == [.thinkingText("hm"), .thoughtSignature("SIG1"), .textDelta("Answer"), .thoughtSignature("SIG2")])
        var assembler = StreamAssembler()
        for e in events { assembler.apply(e, now: 0) }
        #expect(assembler.response().candidates?.first?.content?.parts.first?.thoughtSignature == "SIG2")
    }

    @Test("a transient error before the stream's first event (503, 429, 500) reopens nothing and remembers nothing")
    func streamTransientErrorsPassThrough() async {
        for status in [503, 429, 500] {
            let k = key()
            let sent = Sent()
            let stream = GeminiThinkingFallback.stream(key: k, level: "low", includeThoughts: true) { rung in
                AsyncThrowingStream { c in
                    Task { await sent.add(rung) }
                    c.finish(throwing: APIError(message: "busy", statusCode: status))
                }
            }
            do { for try await _ in stream {}; Issue.record("should throw") }
            catch { #expect((error as? APIError)?.statusCode == status) }
            let rungs = await sent.all
            #expect(rungs == [.init(level: "low", includeThoughts: true)], "status \(status) walked the ladder")
            #expect(!GeminiThinkingFallback.levelRefused(key: k, level: "low") && !GeminiThinkingFallback.thoughtsRefused(key: k))
        }
    }

    @Test("a non-400 error is not a refusal: no retry")
    func otherErrorsPassThrough() async {
        let k = key()
        let sent = Sent()
        let outcome: Result<String, Error> = await Result {
            try await GeminiThinkingFallback.run(key: k, level: "low", includeThoughts: true) { rung in
                await sent.add(rung)
                throw APIError(message: "overloaded", statusCode: 503)
            }
        }
        #expect(outcome.isFailure)
        #expect(await sent.all.count == 1)
    }

    @Test("a stream rejected before its first event is reopened without the field; later errors pass through")
    func streamFallback() async throws {
        let k = key()
        let sent = Sent()
        let stream = GeminiThinkingFallback.stream(key: k, level: "low", includeThoughts: true) { rung in
            AsyncThrowingStream { c in
                Task { await sent.add(rung) }
                if rung.level != nil { c.finish(throwing: APIError(message: "bad", statusCode: 400)); return }
                c.yield(.textDelta("hi")); c.yield(.done(finishReason: "STOP"))
                c.finish()
            }
        }
        var got: [LLMStreamEvent] = []
        for try await e in stream { got.append(e) }
        #expect(got == [.textDelta("hi"), .done(finishReason: "STOP")])
        #expect(GeminiThinkingFallback.levelRefused(key: k, level: "low"))

        let k2 = key()
        let mid = GeminiThinkingFallback.stream(key: k2, level: "low", includeThoughts: true) { _ in
            AsyncThrowingStream { c in c.yield(.textDelta("a")); c.finish(throwing: APIError(message: "late", statusCode: 400)) }
        }
        var events = 0
        do { for try await _ in mid { events += 1 } } catch { #expect((error as? APIError)?.message == "late") }
        #expect(events == 1)
        #expect(!GeminiThinkingFallback.levelRefused(key: k2, level: "low"), "an error after output is not the field's")
    }
}

private actor Sent {
    var all: [GeminiThinkingFallback.Attempt] = []
    func add(_ a: GeminiThinkingFallback.Attempt) { all.append(a) }
}

private extension Result where Failure == Error {
    init(_ body: () async throws -> Success) async {
        do { self = .success(try await body()) } catch { self = .failure(error) }
    }
    var isFailure: Bool { if case .failure = self { return true } else { return false } }
}
