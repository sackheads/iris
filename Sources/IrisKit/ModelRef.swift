import Foundation

/// #1429 slice 1: one registered model, a provider and a model id, as a profile names it (`model: anthropic/claude-sonnet-5-5`).
/// Valid only while its provider is configured, which `ConfigManager.route(for:)` checks at the moment it's used. Nothing
/// routes a conversation by it yet: that is slice 2.
struct ModelRef: Codable, Equatable, Hashable, Sendable {
    let providerId: String
    let model: String

    init(providerId: String, model: String) {
        self.providerId = providerId
        self.model = model
    }

    /// `<provider>/<model>`, split at the first `/`, since a model id may hold one (OpenRouter's `anthropic/claude-…`).
    /// The provider is a built-in's id (`anthropic`, `gemini`, `openai`) or an endpoint's; the model is any id a provider
    /// may list (`ProviderSlug.isValidModelId`).
    static func parse(_ text: String) -> Result<ModelRef, ParseError> {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let slash = trimmed.firstIndex(of: "/") else { return .failure(.noSlash) }
        let provider = String(trimmed[..<slash]), model = String(trimmed[trimmed.index(after: slash)...])
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-")
        guard (1...32).contains(provider.count), provider.allSatisfy(allowed.contains), provider.first != "-", provider.last != "-"
        else { return .failure(.badProvider(provider)) }
        guard ProviderSlug.isValidModelId(model) else { return .failure(.badModel(model)) }
        return .success(ModelRef(providerId: provider, model: model))
    }

    enum ParseError: Error, Equatable {
        case noSlash, badProvider(String), badModel(String)

        var message: String {
            switch self {
            case .noSlash: return "model must be provider/model, for example anthropic/claude-sonnet-5-5"
            case .badProvider(let p): return "model's provider \(p.isEmpty ? "is missing" : "`\(p)` isn't a provider id") (lowercase letters, digits and inner dashes)"
            case .badModel(let m): return "model's id \(m.isEmpty ? "is missing" : "`\(m)` isn't a model id") (letters, digits and . _ : / -, up to 100)"
            }
        }
    }

    var text: String { "\(providerId)/\(model)" }
}

extension ConfigManager {
    /// #1429: every model a profile may name now: each usable provider's models (a built-in's tier models and extras, an
    /// endpoint's list), in the registry's order. Derived each time, never stored, so it can't drift from the settings.
    func registeredModels(keychain: KeychainManager? = nil) -> [ModelRef] {
        providerRegistry(keychain: keychain).filter(\.usable).flatMap { entry in
            entry.models.map { ModelRef(providerId: entry.id, model: $0) }
        }
    }

    /// #1429: the route for a profile's model, by the same checks a subagent's provider gets: refused, never a fallback to
    /// another model, when the provider is unknown, unkeyed, switched off or moved, or the model isn't one it lists.
    func route(for ref: ModelRef, tier: ModelTier = .medium, keychain: KeychainManager? = nil) -> Result<ProviderRoute, SubagentRouteRefusal> {
        subagentRoute(provider: ref.providerId, model: ref.model, tier: tier, keychain: keychain)
    }
}
