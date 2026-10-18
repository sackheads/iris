import Testing
import Foundation
@testable import IrisKit

/// #620: the cloud Vibecop engine asks the model set in Settings, or the easy tier's when none is;
/// a model the provider does not have falls back to the easy tier, said once.
@Suite("Vibecop's cloud model (#620)")
struct CloudVibecopModelTests {
    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var models: [String?] = []
        private var notices: [String] = []
        func sent(_ m: String?) { lock.withLock { models.append(m) } }
        func said(_ n: String) { lock.withLock { notices.append(n) } }
        var sentModels: [String?] { lock.withLock { models } }
        var saidNotices: [String] { lock.withLock { notices } }
    }

    private static let ok = GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [
        Part(text: #"{"decision":"APPROVE","reason":"r"}"#, functionCall: nil, functionResponse: nil,
             thought_signature: nil, thoughtSignature: nil)]))], usageMetadata: nil)

    private func engine(model: String?, calls: Calls, failing: Set<String> = [], failure: APIError? = nil) -> CloudAuxiliaryEngine {
        var e = CloudAuxiliaryEngine()
        e.model = { model }
        e.send = { _, m in
            calls.sent(m)
            if let m, failing.contains(m) {
                throw failure ?? APIError(message: "Gemini HTTP 404 NOT_FOUND: models/\(m) is not found", statusCode: 404, provider: "Gemini")
            }
            return Self.ok
        }
        e.notice = { calls.said($0) }
        return e
    }

    @Test("no model set, or only spaces, is the easy tier, as before")
    func emptyIsEasyTier() async throws {
        for model in [nil, "", "   "] as [String?] {
            let calls = Calls()
            _ = try await engine(model: model, calls: calls).generate(prompt: "p", jsonSchema: nil)
            #expect(calls.sentModels == [nil])
        }
    }

    @Test("a model set in Settings is the one asked")
    func configuredModelIsAsked() async throws {
        let calls = Calls()
        _ = try await engine(model: " gemini-2.5-flash ", calls: calls).generate(prompt: "p", jsonSchema: nil)
        #expect(calls.sentModels == ["gemini-2.5-flash"])
    }

    @Test("a model the provider does not have falls back to the easy tier, and the notice is said once per model")
    func unavailableFallsBack() async throws {
        let calls = Calls()
        let name = "gemini-typo-\(UUID().uuidString)"
        let e = engine(model: name, calls: calls, failing: [name])
        let text = try await e.generate(prompt: "p", jsonSchema: nil)
        #expect(text.contains("APPROVE"), "the verdict still comes back, from the easy tier")
        _ = try await e.generate(prompt: "p", jsonSchema: nil)
        #expect(calls.sentModels == [name, nil, name, nil])
        #expect(calls.saidNotices.count == 1)
        #expect(calls.saidNotices.first?.contains("Vibecop's cloud model \(name) couldn't be used on Gemini") == true)
        #expect(calls.saidNotices.first?.contains("is not found") == true, "the provider's own words are in the notice")
    }

    @Test("any other failure is not a fallback: it surfaces as before")
    func otherErrorsSurface() async {
        let calls = Calls()
        let name = "gemini-busy-\(UUID().uuidString)"
        let e = engine(model: name, calls: calls, failing: [name],
                       failure: APIError(message: "Gemini HTTP 503", statusCode: 503, provider: "Gemini"))
        await #expect(throws: APIError.self) { _ = try await e.generate(prompt: "p", jsonSchema: nil) }
        #expect(calls.sentModels == [name])
        #expect(calls.saidNotices.isEmpty)
    }

    @Test("what counts as a missing or invalid model")
    func modelUnavailable() {
        #expect(CloudAuxiliaryEngine.isModelUnavailable(APIError(message: "x", statusCode: 404)))
        #expect(CloudAuxiliaryEngine.isModelUnavailable(APIError(message: "OpenAI HTTP 400: invalid model ID", statusCode: 400)))
        #expect(CloudAuxiliaryEngine.isModelUnavailable(APIError(message: "OpenAI HTTP 400: The model `x` does not exist", statusCode: 400)))
        #expect(!CloudAuxiliaryEngine.isModelUnavailable(APIError(message: "OpenAI HTTP 400: bad request", statusCode: 400)))
        // A real model refusing the request: surface it, never retry it elsewhere (#627 review).
        for refusal in ["OpenAI HTTP 400: This model's maximum context length is 8192 tokens",
                        "OpenAI HTTP 400: max_tokens is not supported with this model",
                        "Gemini HTTP 400 INVALID_ARGUMENT: Function calling is not enabled for models/gemini-x"] {
            #expect(!CloudAuxiliaryEngine.isModelUnavailable(APIError(message: refusal, statusCode: 400)), "\(refusal)")
        }
        #expect(!CloudAuxiliaryEngine.isModelUnavailable(APIError(message: "x", statusCode: 429)))
        #expect(!CloudAuxiliaryEngine.isModelUnavailable(APIError(message: "no status")))
    }

    @Test("Settings warns when the model does not look like the primary provider's")
    func providerMismatch() {
        #expect(CloudAuxiliaryEngine.providerMismatch(model: "gemini-2.5-flash", provider: "Gemini") == nil)
        #expect(CloudAuxiliaryEngine.providerMismatch(model: "claude-haiku-5-5", provider: "Anthropic") == nil)
        #expect(CloudAuxiliaryEngine.providerMismatch(model: "gpt-5-mini", provider: "OpenAI") == nil)
        #expect(CloudAuxiliaryEngine.providerMismatch(model: "my-local-llama", provider: "OpenAI") == nil,
                "an OpenAI-compatible endpoint serves any name")
        #expect(CloudAuxiliaryEngine.providerMismatch(model: "gemini-2.5-flash", provider: "Anthropic") != nil)
        #expect(CloudAuxiliaryEngine.providerMismatch(model: "gemma-4-E2B-it-Q4_K_M.gguf", provider: "Anthropic") != nil)
        #expect(CloudAuxiliaryEngine.providerMismatch(model: "claude-haiku-5-5", provider: "Gemini") != nil)
        #expect(CloudAuxiliaryEngine.providerMismatch(model: "claude-haiku-5-5", provider: "OpenAI") != nil)
        #expect(CloudAuxiliaryEngine.providerMismatch(model: "", provider: "Anthropic") == nil)
    }

    @Test("the setting is its own key, empty by default, and persists")
    func setting() {
        let name = "iris-620-\(UUID().uuidString)"
        let store = UserDefaults(suiteName: name)!
        defer {
            store.removePersistentDomain(forName: name)
            IrisDefaults.removeSuiteFile(named: name, in: IrisDefaults.preferencesDirectory)
        }
        let config = ConfigManager(store: store)
        #expect(config.vibecopCloudModel == "")
        #expect(config.vibecopModel == "gemma-4-E2B-it-Q4_K_M.gguf", "the local engines' field is untouched")
        config.vibecopCloudModel = "gemini-2.5-flash"
        #expect(ConfigManager(store: store).vibecopCloudModel == "gemini-2.5-flash")
    }
}
