import Testing
import Foundation
@testable import iris

/// #218: a guard tier whose model is installed but fails to load or infer had no UI signal — the
/// LED read `.configured` ("enabled, not loaded") while every guarded output was being replaced by
/// `[CONTENT BLOCKED …]`, and only a console print said why.
///
/// Each test gets its own `ConfigManager` over its own `UserDefaults` suite and its own
/// `GuardTierHealth`; neither process-global is touched (AGENTS invariant 7).
@MainActor
@Suite("Guard tier error LED (#218)")
struct GuardLEDErrorStateTests {

    private func harness() -> (ConfigManager, String) {
        let suite = "iris-guardled-\(UUID().uuidString)"
        let store = UserDefaults(suiteName: suite)!
        store.removePersistentDomain(forName: suite)
        let config = ConfigManager(store: store)
        config.enableAdvancedPromptInjectionProtection = true
        config.promptGuardCoreMLModel = ""
        config.promptGuardEngine = "llama_cpp"
        config.promptGuardModel = ""
        return (config, suite)
    }

    private func teardown(_ suite: String) {
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        IrisDefaults.removeSuiteFile(named: suite, in: IrisDefaults.preferencesDirectory)
    }

    @Test("a failing tier reads .error, not .configured or .unprovisioned")
    func failingTierIsError() {
        let (config, suite) = harness(); defer { teardown(suite) }
        let bar = ModelLEDBar(config: config)
        // Whatever the no-failure answer is — it depends on what this machine has on disk, which
        // is not what this test is about — it is not `.error`, and `.error` is what a recorded
        // failure produces. Asserting the baseline exactly would couple this to provisioning.
        #expect(bar.tier2State(failure: nil) != .error)
        #expect(bar.tier3State(failure: nil) != .error)
        // A tier that is installed and broken outranks whatever is on disk.
        #expect(bar.tier2State(failure: "could not load CoreML model") == .error)
        #expect(bar.tier3State(failure: "llama_cpp: unexpected EOF") == .error)
        // An empty string is not a failure — it is the absence of one.
        #expect(bar.tier2State(failure: "") != .error)
    }

    @Test("a disabled tier stays off even with a stale failure recorded")
    func disabledBeatsError() {
        let (config, suite) = harness(); defer { teardown(suite) }
        config.enableAdvancedPromptInjectionProtection = false
        let bar = ModelLEDBar(config: config)
        // A tier the user switched off blocks nothing, so a failure from before that is not news.
        #expect(bar.tier2State(failure: "boom") == .off)
        #expect(bar.tier3State(failure: "boom") == .off)
    }

    @Test("the tooltip names the error, because the fix depends on which one it is")
    func tooltipNamesTheError() {
        let led = ModelLED(label: "P2", state: .error, tierNumber: 2,
                           failure: "the model directory is missing weights.bin")
        #expect(led.tooltip.contains("the model directory is missing weights.bin"))
        #expect(led.tooltip.contains("tier 2"))
        // An error with no detail still says what state it is in rather than rendering blank.
        #expect(ModelLED(label: "P3", state: .error, tierNumber: 3).tooltip.contains("failing"))
    }

    @Test("a failing spell is announced once, not once per blocked output")
    func announcedOncePerSpell() {
        let health = GuardTierHealth()
        var said: [String] = []
        health.announce = { said.append($0) }
        // A broken tier is retried uncached on every evaluation, so this is the common case.
        health.recordTier2Failure("first")
        health.recordTier2Failure("second")
        health.recordTier2Failure("third")
        #expect(said.count == 1, "got \(said.count) notices for one failing spell")
        #expect(health.tier2Failure == "third", "the LED shows the latest error, not the first")
    }

    @Test("a tier that recovers and breaks again is announced again")
    func recoveryResetsTheSpell() {
        let health = GuardTierHealth()
        var said: [String] = []
        health.announce = { said.append($0) }
        health.recordTier2Failure("broke")
        health.clearTier2()
        #expect(health.tier2Failure == nil, "a tier that produced a verdict is working")
        health.recordTier2Failure("broke again")
        #expect(said.count == 2, "a second spell is a second thing worth saying")
    }

    @Test("the two tiers do not share a spell")
    func tiersAreIndependent() {
        let health = GuardTierHealth()
        health.recordTier2Failure("tier 2 is broken")
        #expect(health.tier2Failure != nil)
        #expect(health.tier3Failure == nil, "tier 3 is fine and must not be reported as failing")
        health.clearTier2()
        health.recordTier3Failure("tier 3 is broken")
        #expect(health.tier2Failure == nil)
        #expect(health.tier3Failure != nil)
    }

    @Test("the notice says which tier, what it is doing, and the error")
    func noticeIsActionable() {
        let text = GuardTierHealth.notice(tier: 3, description: "unexpected EOF")
        #expect(text.contains("tier-3"))
        #expect(text.contains("unexpected EOF"))
        #expect(text.lowercased().contains("settings"), "a notice with no way to act on it is a dead end")
    }
}

/// #261: the LEDs become optional.
@MainActor
@Suite("Model LED visibility setting (#261)")
struct ModelLEDVisibilityTests {

    @Test("defaults on, so an existing install keeps what it had")
    func defaultsOn() {
        let suite = "iris-ledvis-\(UUID().uuidString)"
        let store = UserDefaults(suiteName: suite)!
        store.removePersistentDomain(forName: suite)
        defer {
            store.removePersistentDomain(forName: suite)
            IrisDefaults.removeSuiteFile(named: suite, in: IrisDefaults.preferencesDirectory)
        }
        #expect(ConfigManager(store: store).showModelLEDs)
    }

    @Test("the choice survives a relaunch")
    func persists() {
        let suite = "iris-ledvis-\(UUID().uuidString)"
        let store = UserDefaults(suiteName: suite)!
        store.removePersistentDomain(forName: suite)
        defer {
            store.removePersistentDomain(forName: suite)
            IrisDefaults.removeSuiteFile(named: suite, in: IrisDefaults.preferencesDirectory)
        }
        let first = ConfigManager(store: store)
        first.showModelLEDs = false
        // A second manager over the same store is what a relaunch looks like.
        #expect(ConfigManager(store: store).showModelLEDs == false)
    }
}
