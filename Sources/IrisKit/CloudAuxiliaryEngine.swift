import Foundation

/// A guard on the primary provider. Vibecop (#620) asks the model set in Settings
/// (`vibecopCloudModel`), or the easy tier's when none is. Tier 3's canary (#800) asks
/// `tier3CloudModel`, else Vibecop's, else the easy tier's, and may send a thinking level. A model the provider does not have falls back to the easy tier for
/// that call, with one notice per model, so a typo never quietly turns every check into a prompt.
struct CloudAuxiliaryEngine: AuxiliaryInferenceEngine {
    typealias Send = @Sendable (GeminiRequest, String?) async throws -> GeminiResponse

    /// The role tier 3's canary engine is built for.
    static let canaryRole = "canary"

    /// Tier 3 runs as "canary"; Settings tests it as "promptGuard" (`ModelLoadPurpose`), and the test
    /// must ask what the guard asks.
    static func isTier3(_ role: String) -> Bool { ModelLoadPurpose(role: role) == .guardTier3 }

    /// The model the Settings name for `role`, trimmed, or nil for the easy tier. A canary's own
    /// field comes first and falls back to Vibecop's, which is what tier 3 used before it had one.
    static func configuredModel(role: String, config: ConfigManager) -> String? {
        func trimmed(_ text: String) -> String? {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }
        if isTier3(role), let own = trimmed(config.tier3CloudModel) { return own }
        return trimmed(config.vibecopCloudModel)
    }

    /// What a call for `role` asks, the easy tier's model when none is set: the one place Settings,
    /// the LED detail and the verdict cache's key read it from.
    static func effectiveModel(role: String, config: ConfigManager) -> String {
        configuredModel(role: role, config: config) ?? config.getModel(for: .easy)
    }

    /// The thinking level to send for `role`, or nil: only the canary has one, and only a known
    /// level (`ConfigManager.tier3ThinkingLevels`) counts.
    static func thinkingLevel(role: String, config: ConfigManager) -> String? {
        guard isTier3(role), ConfigManager.tier3ThinkingLevels.contains(config.tier3ThinkingLevel) else { return nil }
        return config.tier3ThinkingLevel
    }

    /// The configured model, read at each call so a change in Settings applies at once; nil or
    /// blank is the easy tier. The default is Vibecop's; `AuxiliaryModelManager` sets the role's.
    var model: @Sendable () -> String? = { ConfigManager.shared.vibecopCloudModel }
    /// The thinking level to send, read at each call; nil sends none.
    var thinkingLevel: @Sendable () -> String? = { nil }
    var send: Send = { request, model in try await LLMClient().generateContent(request: request, tier: .easy, model: model) }
    /// Which guard this engine serves ("vibecop", "canary"), for the unattributed-usage log.
    var role = "guard"
    var notice: @Sendable (String) async -> Void = { text in
        await MainActor.run { _ = GuardTierHealth.shared.announce?(text) }
    }

    func loadModel(config: AuxiliaryModelConfig) async throws {
        // Cloud models don't require explicit loading into memory.
    }
    
    func unloadModel() async {
        // No-op
    }
    
    func generate(prompt: String, jsonSchema: String?) async throws -> String {
        var finalPrompt = prompt
        if let schema = jsonSchema {
            finalPrompt += "\n\nYou MUST return your response as a valid JSON object matching the following schema. Return ONLY JSON, no markdown formatting or prose:\n\(schema)"
        }
        
        let requestContent = Content(
            role: "user", 
            parts: [Part(text: finalPrompt, functionCall: nil, functionResponse: nil, thought_signature: nil, thoughtSignature: nil)]
        )
        
        var request = GeminiRequest(contents: [requestContent], systemInstruction: nil, tools: nil)
        request.thinkingLevel = thinkingLevel()
        
        let chosen = model()?.trimmingCharacters(in: .whitespacesAndNewlines)
        let response: GeminiResponse
        if let chosen, !chosen.isEmpty {
            do {
                response = try await send(request, chosen)
            } catch let error as APIError where Self.isModelUnavailable(error) {
                if Self.firstFallback(for: chosen) {
                    // The provider's own words too: a 404 can also be a wrong project or region,
                    // and the easy-tier retry then fails on its own, so the notice must not blame
                    // the model alone.
                    await notice("Vibecop's cloud model \(chosen) couldn't be used on \(error.provider ?? "the primary provider") (\(error.message)); using the easy tier's model instead. Change it in Settings → Vibecop.")
                }
                response = try await send(request, nil)
            }
        } else {
            // The easy tier, as always: speed and cost.
            response = try await send(request, nil)
        }
        
        // #689: the call's tokens go to whoever caused it, not nowhere.
        await GuardUsage.report(response.usageMetadata, role: role)

        guard let candidate = response.candidates?.first, 
              let content = candidate.content,
              let part = content.parts.first, 
              let text = part.text else {
            throw APIError(message: "No text returned from cloud provider for Vibecop.")
        }
        
        return text
    }

    /// A provider's answer that the model does not exist: a 404 (Gemini, Anthropic, OpenAI's
    /// `model_not_found`), or a 400 in not-found words. Not any 400 that mentions a model: "this
    /// model's maximum context length", "max_tokens is not supported with this model" or "function
    /// calling is not enabled for models/…" are a real model refusing the request, and must surface
    /// rather than be retried on another model (#627 review).
    static func isModelUnavailable(_ error: APIError) -> Bool {
        guard let status = error.statusCode else { return false }
        if status == 404 { return true }
        guard status == 400 else { return false }
        let text = (error.message + " " + (error.detail ?? "")).lowercased()
        return ["model_not_found", "does not exist", "not found", "unknown model", "invalid model",
                "no such model", "is not a valid model"].contains { text.contains($0) }
    }

    private static let fallbackLock = NSLock()
    nonisolated(unsafe) private static var announced: Set<String> = []

    /// True the first time a model falls back in this process, so the notice is said once.
    static func firstFallback(for model: String) -> Bool {
        fallbackLock.withLock { announced.insert(model).inserted }
    }

    /// Whether `model` looks like one of `provider`'s, for Settings' warning; nil when it does or
    /// when that cannot be told (an OpenAI-compatible endpoint serves any names).
    static func providerMismatch(model: String, provider: String) -> String? {
        let m = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !m.isEmpty else { return nil }
        let looksGemini = m.hasPrefix("gemini") || m.hasPrefix("gemma")
        let looksClaude = m.hasPrefix("claude")
        switch provider {
        case LLMProvider.anthropic.rawValue where !looksClaude:
            return "This doesn't look like a Claude model, and the primary provider is Anthropic."
        case LLMProvider.gemini.rawValue where !looksGemini:
            return "This doesn't look like a Gemini model, and the primary provider is Gemini."
        case LLMProvider.openai.rawValue where looksGemini || looksClaude:
            return "This looks like another provider's model, and the primary provider is OpenAI."
        default:
            return nil
        }
    }
}
