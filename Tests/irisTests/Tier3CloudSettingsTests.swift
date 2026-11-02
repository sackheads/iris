import Testing
import Foundation
@testable import IrisKit

/// #800: a Cloud tier 3 has its own model field and an optional thinking level, and neither changes
/// anyone who has not set them.
@Suite("Tier 3's cloud model and thinking level (#800)")
struct Tier3CloudSettingsTests {
    private func isolated() -> (ConfigManager, UserDefaults, () -> Void) {
        let name = "iris-tier3cloud-\(UUID().uuidString)"
        let store = UserDefaults(suiteName: name)!
        return (ConfigManager(store: store), store, {
            store.removePersistentDomain(forName: name)
            IrisDefaults.removeSuiteFile(named: name, in: IrisDefaults.preferencesDirectory)
        })
    }

    @Test("the canary asks its own field, then Vibecop's, then the easy tier; Vibecop never reads the new one")
    func resolutionOrder() {
        let (config, _, cleanup) = isolated(); defer { cleanup() }
        let canary = CloudAuxiliaryEngine.canaryRole
        #expect(CloudAuxiliaryEngine.configuredModel(role: canary, config: config) == nil, "nothing set: the easy tier, as before")
        #expect(CloudAuxiliaryEngine.effectiveModel(role: canary, config: config) == config.getModel(for: .easy))

        config.vibecopCloudModel = "vibecop-model"
        #expect(CloudAuxiliaryEngine.configuredModel(role: canary, config: config) == "vibecop-model", "today's behaviour for anyone who has not set the new field")

        config.tier3CloudModel = "  tier3-model \n"
        #expect(CloudAuxiliaryEngine.configuredModel(role: canary, config: config) == "tier3-model")
        #expect(CloudAuxiliaryEngine.configuredModel(role: "vibecop", config: config) == "vibecop-model", "the new field is tier 3's alone")

        config.tier3CloudModel = "   "
        #expect(CloudAuxiliaryEngine.configuredModel(role: canary, config: config) == "vibecop-model", "blank is unset")
    }

    @Test("both settings persist, default to none, and an unknown level reads as none")
    func persistence() {
        let (config, store, cleanup) = isolated(); defer { cleanup() }
        #expect(config.tier3CloudModel.isEmpty && config.tier3ThinkingLevel.isEmpty)
        config.tier3CloudModel = "gemini-3.8-flash"
        config.tier3ThinkingLevel = "low"
        let again = ConfigManager(store: store)
        #expect(again.tier3CloudModel == "gemini-3.8-flash" && again.tier3ThinkingLevel == "low")

        store.set("extreme", forKey: "PROMPT_GUARD_THINKING_LEVEL")
        #expect(ConfigManager(store: store).tier3ThinkingLevel.isEmpty, "a hand-edited level is not sent")
    }

    @Test("the level goes only to the canary, and only a known level")
    func levelIsTheCanarysAlone() {
        let (config, _, cleanup) = isolated(); defer { cleanup() }
        let canary = CloudAuxiliaryEngine.canaryRole
        #expect(CloudAuxiliaryEngine.thinkingLevel(role: canary, config: config) == nil)
        config.tier3ThinkingLevel = "medium"
        #expect(CloudAuxiliaryEngine.thinkingLevel(role: canary, config: config) == "medium")
        #expect(CloudAuxiliaryEngine.thinkingLevel(role: "vibecop", config: config) == nil)
    }

    @Test("a cloud tier 3's model and level are in the fingerprint and the cache key; another engine ignores them")
    func fingerprintAndKey() {
        let (config, _, cleanup) = isolated(); defer { cleanup() }
        config.promptGuardEngine = "cloud"
        func fingerprint() -> InjectionGuard.GuardConfigFingerprint {
            InjectionGuard.currentConfigFingerprint(protectionEnabled: true, settings: config)
        }
        func key(_ f: InjectionGuard.GuardConfigFingerprint) -> String {
            InjectionGuard.cacheKey(clean: "text", source: "s", maxTier: .tier3_canary, fingerprint: f)
        }
        let base = fingerprint()
        config.tier3CloudModel = "model-a"
        let model = fingerprint()
        #expect(model.tier3CloudModel.hasSuffix("|model-a") && key(base) != key(model), "the new field changes the key")
        config.tier3ThinkingLevel = "low"
        let low = fingerprint()
        #expect(low.tier3ThinkingLevel == "low" && key(model) != key(low), "the level changes the key")
        config.tier3ThinkingLevel = "medium"
        #expect(key(low) != key(fingerprint()), "another level, another key")

        config.promptGuardEngine = "ollama"
        let other = fingerprint()
        #expect(other.tier3CloudModel.isEmpty && other.tier3ThinkingLevel.isEmpty, "a local tier 3 ignores both")
    }

    private final class Seen: @unchecked Sendable {
        private let lock = NSLock()
        private var levels: [String?] = []
        func add(_ l: String?) { lock.withLock { levels.append(l) } }
        var all: [String?] { lock.withLock { levels } }
    }

    @Test("the engine puts the level on the request it sends")
    func engineSendsTheLevel() async throws {
        let ok = GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [
            Part(text: "SAFE", functionCall: nil, functionResponse: nil, thought_signature: nil, thoughtSignature: nil)]))],
                                usageMetadata: nil)
        for level in ["low", nil] as [String?] {
            let seen = Seen()
            var engine = CloudAuxiliaryEngine()
            engine.role = CloudAuxiliaryEngine.canaryRole
            engine.thinkingLevel = { level }
            engine.send = { request, _ in seen.add(request.thinkingLevel); return ok }
            _ = try await engine.generate(prompt: "p", jsonSchema: nil)
            #expect(seen.all == [level])
        }
    }

    @Test("the Gemini body carries the level, and is byte-for-byte what it was when there is none")
    func wireBody() throws {
        var request = GeminiRequest(contents: [Content(role: "user", parts: [Part(text: "hi")])], systemInstruction: nil, tools: nil)
        let plain = try LLMClient.encodeGeminiBody(request)
        // Every Gemini call goes through this encoder, so the no-level body is pinned byte for byte.
        #expect(String(decoding: plain, as: UTF8.self) == #"{"contents":[{"parts":[{"text":"hi"}],"role":"user"}]}"#)
        request.thinkingLevel = "low"
        let body = try LLMClient.encodeGeminiBody(request)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let thinking = ((json["generationConfig"] as? [String: Any])?["thinkingConfig"]) as? [String: Any]
        #expect(thinking?["thinkingLevel"] as? String == "low")
        #expect(json["contents"] != nil, "the rest of the body is still there")
    }

    @Test("a model that answers 400 to the level is asked again without it, once noticed")
    func levelRefusedIsRetriedWithout() async throws {
        let ok = GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [
            Part(text: "SAFE", functionCall: nil, functionResponse: nil, thought_signature: nil, thoughtSignature: nil)]))],
                                usageMetadata: nil)
        let seen = Seen()
        let said = Seen()
        var engine = CloudAuxiliaryEngine()
        engine.thinkingLevel = { "low" }
        let model = "gemini-2.5-flash-\(UUID().uuidString)"   // one name for both calls, and not another test's
        engine.model = { model }
        engine.send = { request, _ in
            seen.add(request.thinkingLevel)
            if request.thinkingLevel != nil { throw APIError(message: "Invalid value at thinking_level", statusCode: 400, provider: "Gemini") }
            return ok
        }
        engine.notice = { said.add($0) }
        let text = try await engine.generate(prompt: "p", jsonSchema: nil)
        #expect(text == "SAFE" && seen.all == ["low", nil], "asked with the level, then without")
        #expect(said.all.count == 1)
        // The refusal is remembered: the next check sends one request, without the level.
        _ = try await engine.generate(prompt: "p", jsonSchema: nil)
        #expect(seen.all == ["low", nil, nil] && said.all.count == 1, "no second failed round trip, no second notice")

        // A 400 that is not about the level still surfaces (the second ask fails the same way).
        var failing = engine
        failing.send = { _, _ in throw APIError(message: "bad request", statusCode: 400, provider: "Gemini") }
        await #expect(throws: APIError.self) { _ = try await failing.generate(prompt: "p", jsonSchema: nil) }
    }
}
