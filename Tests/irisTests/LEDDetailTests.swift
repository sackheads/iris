import Testing
import Foundation
@testable import IrisKit

/// #88: each status light opens a popover with its details and, when it is not green, one step
/// that opens Settings where the fix is. Every test has its own `ConfigManager` over its own
/// suite and its own `GuardTierHealth` (AGENTS invariant 7); no key or secret is written.
@MainActor
@Suite("Status light details (#88)")
struct LEDDetailTests {

    private func harness() -> (ConfigManager, String) {
        let suite = "iris-leddetail-\(UUID().uuidString)"
        let store = UserDefaults(suiteName: suite)!
        store.removePersistentDomain(forName: suite)
        return (ConfigManager(store: store), suite)
    }

    private func teardown(_ suite: String) {
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        IrisDefaults.removeSuiteFile(named: suite, in: IrisDefaults.preferencesDirectory)
    }

    @Test("a green light offers no action; every other light offers one, on its own tab")
    func actionsFollowState() {
        let (config, suite) = harness(); defer { teardown(suite) }
        let bar = ModelLEDBar(config: config)
        for kind in LEDKind.allCases {
            for state in ModelLED.LEDState.allCases {
                let action = bar.detail(for: kind, state: state, failure: nil).action
                if state.isGreen {
                    #expect(action == nil, "\(kind) \(state)")
                } else if state == .configured && kind != .vibecop {
                    // P2's model is on disk and loads on first use: nothing to fix.
                    #expect(action == nil, "\(kind) \(state)")
                } else {
                    #expect(action?.tab == kind.tab, "\(kind) \(state)")
                }
            }
        }
    }

    @Test("each light's settings tab is where its controls are")
    func tabs() {
        #expect(LEDKind.primary.tab == .models)
        #expect(LEDKind.vibecop.tab == .vibecop)
        #expect(LEDKind.tier1.tab == .security)
        #expect(LEDKind.tier2.tab == .security)
        #expect(LEDKind.tier3.tab == .security)
    }

    @Test("a missing model's action is a download; a failing tier's names the error in full")
    func downloadAndFailure() {
        let (config, suite) = harness(); defer { teardown(suite) }
        let bar = ModelLEDBar(config: config)
        #expect(bar.detail(for: .tier3, state: .unprovisioned, failure: nil).action?.title
                == "Download the model in Settings")
        #expect(bar.detail(for: .vibecop, state: .configured, failure: nil).action?.title
                == "Download the model in Settings")

        let long = "load failed: " + String(repeating: "x", count: 4000)
        let red = bar.detail(for: .tier2, state: .error, failure: long)
        #expect(red.failure == long)
        #expect(red.summary.contains("blocking guarded output"))
        // A stale failure under a state that is not red is not news (the LED's own precedence).
        #expect(bar.detail(for: .tier2, state: .off, failure: long).failure == nil)
    }

    @Test("the light's state and failure come from the injected health")
    func stateFromHealth() {
        let (config, suite) = harness(); defer { teardown(suite) }
        config.enableAdvancedPromptInjectionProtection = true
        let health = GuardTierHealth()
        health.recordTier3Failure("canary model missing tensor", engine: "llama_cpp")
        let bar = ModelLEDBar(config: config, health: health)
        #expect(bar.failure(of: .tier3) == "canary model missing tensor")
        #expect(bar.failure(of: .tier2) == nil)
        #expect(bar.state(of: .tier3, failure: bar.failure(of: .tier3)) == .error)
        #expect(bar.state(of: .tier1, failure: nil) == bar.tier1State())
    }

    /// The seam agent profiles part 3 changes: it must pass the conversation's resolved tier and
    /// change these labels with it (Invariant 9).
    @Test("PRI's models are the configured defaults, and say so")
    func primaryFactsAreDefaults() {
        let (config, suite) = harness(); defer { teardown(suite) }
        config.primaryProvider = LLMProvider.anthropic.rawValue
        config.anthropicModelEasy = "easy-one"
        config.anthropicModelMedium = "medium-one"
        config.anthropicModelHard = ""
        let facts = ModelLEDBar(config: config).primaryModelFacts()
        #expect(facts == [
            .init(label: "Provider", value: LLMProvider.anthropic.rawValue),
            .init(label: "Default model", value: "medium-one"),
            .init(label: "Default easy model", value: "easy-one"),
            .init(label: "Default hard model", value: "not set"),
        ])
        #expect(ModelLEDBar(config: config).detail(for: .primary, state: .ready, failure: nil).facts == facts)
    }

    @Test("Vibecop's cloud engine with no model of its own names the easy model it uses")
    func vibecopCloudModel() {
        let (config, suite) = harness(); defer { teardown(suite) }
        config.primaryProvider = LLMProvider.anthropic.rawValue
        config.anthropicModelEasy = "easy-one"
        config.vibecopEngine = "cloud"
        config.vibecopCloudModel = "  "
        let facts = ModelLEDBar(config: config).detail(for: .vibecop, state: .ready, failure: nil).facts
        #expect(facts.contains(.init(label: "Model", value: "the easy model (easy-one)")))
        #expect(facts.contains(.init(label: "Engine", value: "Cloud (primary provider)")))
    }

    @Test("each state has its own spoken words")
    func spoken() {
        let words = ModelLED.LEDState.allCases.map(\.spoken)
        #expect(Set(words).count == words.count)
    }

    @Test("opening a tab selects it, even when Settings is already showing another")
    func navigation() {
        let navigation = SettingsNavigation()
        var opened = 0
        navigation.show(.plugins) { opened += 1 }
        #expect(navigation.selected == .plugins)
        navigation.show(.security) { opened += 1 }
        #expect(navigation.selected == .security)
        #expect(opened == 2)
    }
}
