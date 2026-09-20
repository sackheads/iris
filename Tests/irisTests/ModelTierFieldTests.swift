import Testing
import Foundation
@testable import iris

/// #207 amendment: "Use as" assignment from the model list into a tier field. `keyPath` is pure;
/// the assignment test writes through an isolated `ConfigManager(store:)`, never `.shared`
/// (Invariant 7).
@Suite("Model tier field mapping (#207 amendment)")
struct ModelTierFieldTests {
    // `ReferenceWritableKeyPath` isn't `Sendable`, so the combinations are checked in one
    // synchronous test rather than via `@Test(arguments:)` (which requires Sendable arguments).
    @Test("keyPath resolves every provider x tier combination, plus vision")
    func nineCombinationsPlusVision() {
        #expect(ModelTierField.keyPath(provider: .gemini, tier: .easy) == \ConfigManager.geminiModelEasy)
        #expect(ModelTierField.keyPath(provider: .gemini, tier: .medium) == \ConfigManager.geminiModelMedium)
        #expect(ModelTierField.keyPath(provider: .gemini, tier: .hard) == \ConfigManager.geminiModelHard)
        #expect(ModelTierField.keyPath(provider: .anthropic, tier: .easy) == \ConfigManager.anthropicModelEasy)
        #expect(ModelTierField.keyPath(provider: .anthropic, tier: .medium) == \ConfigManager.anthropicModelMedium)
        #expect(ModelTierField.keyPath(provider: .anthropic, tier: .hard) == \ConfigManager.anthropicModelHard)
        #expect(ModelTierField.keyPath(provider: .openai, tier: .easy) == \ConfigManager.openaiModelEasy)
        #expect(ModelTierField.keyPath(provider: .openai, tier: .medium) == \ConfigManager.openaiModelMedium)
        #expect(ModelTierField.keyPath(provider: .openai, tier: .hard) == \ConfigManager.openaiModelHard)

        // Vision ignores the provider — one field backs it regardless.
        #expect(ModelTierField.keyPath(provider: .gemini, tier: .vision) == \ConfigManager.auxiliaryVisionModel)
        #expect(ModelTierField.keyPath(provider: .anthropic, tier: .vision) == \ConfigManager.auxiliaryVisionModel)
        #expect(ModelTierField.keyPath(provider: .openai, tier: .vision) == \ConfigManager.auxiliaryVisionModel)
    }

    @Test("assigning through the keyPath writes the tier field on an isolated ConfigManager")
    func assignmentWritesField() {
        let name = "iris-modeltierfield-\(UUID().uuidString)"
        let store = UserDefaults(suiteName: name)!
        defer {
            store.removePersistentDomain(forName: name)
            IrisDefaults.removeSuiteFile(named: name, in: IrisDefaults.preferencesDirectory)
        }
        let config = ConfigManager(store: store)

        config[keyPath: ModelTierField.keyPath(provider: .anthropic, tier: .medium)] = "claude-sonnet-5"
        #expect(config.anthropicModelMedium == "claude-sonnet-5")

        config[keyPath: ModelTierField.keyPath(provider: .gemini, tier: .vision)] = "gemini-3.5-flash"
        #expect(config.auxiliaryVisionModel == "gemini-3.5-flash")

        // Writing through the keyPath must not disturb an unrelated tier or provider.
        #expect(config.anthropicModelEasy != "claude-sonnet-5")
        #expect(config.openaiModelMedium != "claude-sonnet-5")
    }
}
