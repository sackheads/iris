import Foundation

/// One assignable slot in the Models tab: a provider's Easy/Medium/Hard tier, or the auxiliary
/// vision model (which has no provider of its own — one field regardless of `primaryProvider`).
/// Used by the "List Available Models…" sheet's "Use as" menu (#207) to write a model id chosen
/// from the list straight into a tier field.
enum ModelTierField: CaseIterable {
    case easy
    case medium
    case hard
    case vision

    /// The menu item / help text label for this tier.
    var label: String {
        switch self {
        case .easy: return "Easy Subagent Model"
        case .medium: return "Primary / Medium Model"
        case .hard: return "Hard Subagent Model"
        case .vision: return "Vision Model"
        }
    }

    /// The short name used on a row's "already assigned" tag.
    var shortLabel: String {
        switch self {
        case .easy: return "Easy"
        case .medium: return "Medium"
        case .hard: return "Hard"
        case .vision: return "Vision"
        }
    }

    /// The persisted `ConfigManager` field backing this tier for `provider`. `.vision` ignores
    /// `provider` — there is exactly one vision model field, independent of the primary provider.
    static func keyPath(provider: LLMProvider, tier: ModelTierField) -> ReferenceWritableKeyPath<ConfigManager, String> {
        switch tier {
        case .vision:
            return \ConfigManager.auxiliaryVisionModel
        case .easy:
            switch provider {
            case .gemini: return \ConfigManager.geminiModelEasy
            case .anthropic: return \ConfigManager.anthropicModelEasy
            case .openai: return \ConfigManager.openaiModelEasy
            }
        case .medium:
            switch provider {
            case .gemini: return \ConfigManager.geminiModelMedium
            case .anthropic: return \ConfigManager.anthropicModelMedium
            case .openai: return \ConfigManager.openaiModelMedium
            }
        case .hard:
            switch provider {
            case .gemini: return \ConfigManager.geminiModelHard
            case .anthropic: return \ConfigManager.anthropicModelHard
            case .openai: return \ConfigManager.openaiModelHard
            }
        }
    }
}
