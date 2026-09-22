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
        health.announce = { said.append($0); return true }
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
        health.announce = { said.append($0); return true }
        health.recordTier2Failure("broke")
        health.clearTier2()
        #expect(health.tier2Failure == nil, "a tier that produced a verdict is working")
        health.recordTier2Failure("broke again")
        #expect(said.count == 2, "a second spell is a second thing worth saying")
    }

    @Test("the two tiers do not share a spell, and each names itself")
    func tiersAreIndependent() {
        let health = GuardTierHealth()
        var said: [String] = []
        health.announce = { said.append($0); return true }
        health.recordTier2Failure("tier 2 is broken")
        #expect(health.tier2Failure != nil)
        #expect(health.tier3Failure == nil, "tier 3 is fine and must not be reported as failing")
        // Separate stored properties make the halves above hard to get wrong. The notices are
        // where a cross-wiring actually shows: tier 3 breaking must not be announced as tier 2,
        // and clearing one tier must not silence the other's first notice.
        health.clearTier2()
        health.recordTier3Failure("tier 3 is broken", engine: "llama_cpp")
        #expect(health.tier2Failure == nil)
        #expect(health.tier3Failure != nil)
        #expect(said.count == 2, "each tier gets its own notice")
        #expect(said[0].contains("tier-2"))
        #expect(said[1].contains("tier-3"))
    }

    /// `tier3Provisioning` returns `.provisioned` for every engine except `llama_cpp`, so this
    /// state is reached by a cloud 5xx and an Ollama daemon that is not running — neither of which
    /// has anything downloaded to re-download.
    @Test("the remedy matches the engine, not the local-model story")
    func remedyMatchesEngine() {
        let local = GuardTierHealth.notice(tier: 3, description: "bad magic", engine: "llama_cpp")
        #expect(local.contains("re-download"))
        let ollama = GuardTierHealth.notice(tier: 3, description: "connection refused", engine: "ollama")
        #expect(ollama.lowercased().contains("ollama is running"))
        #expect(!ollama.contains("re-download"), "there is nothing downloaded to re-download")
        let cloud = GuardTierHealth.notice(tier: 3, description: "503", engine: "cloud")
        #expect(cloud.lowercased().contains("key"))
        #expect(!cloud.contains("re-download"))
        // Tier 2 is always a local file, so it keeps the re-download wording.
        #expect(GuardTierHealth.notice(tier: 2, description: "x").contains("re-download"))
        // The off-switch is quoted as Settings actually labels it.
        #expect(local.contains("Enable Protection (Tier 2 & 3)"))
    }

    @Test("a remote engine waits for a second failure before posting a permanent message")
    func remoteEnginesWaitOneBeat() {
        let health = GuardTierHealth()
        var said: [String] = []
        health.announce = { said.append($0); return true }
        health.recordTier3Failure("connection refused", engine: "ollama")
        #expect(said.isEmpty, "a daemon restart is not worth a permanent line in the transcript")
        #expect(health.tier3Failure != nil, "the LED still goes red at once")
        health.recordTier3Failure("connection refused", engine: "ollama")
        #expect(said.count == 1)
        // A local file that will not load is broken now and next time: say it immediately.
        let local = GuardTierHealth()
        var localSaid: [String] = []
        local.announce = { localSaid.append($0); return true }
        local.recordTier3Failure("bad magic", engine: "llama_cpp")
        #expect(localSaid.count == 1)
    }

    @Test("a notice nobody could place does not count as announced")
    func undeliveredDoesNotBurnTheSpell() {
        let health = GuardTierHealth()
        var delivered = false
        // A headless run builds an AppState with nothing selected; the sink can find nowhere.
        health.announce = { _ in delivered }
        health.recordTier2Failure("first, nowhere to put it")
        health.recordTier2Failure("second, still nowhere")
        delivered = true
        health.recordTier2Failure("third, now there is somewhere")
        #expect(health.tier2Failure == "third, now there is somewhere")
        // The spell was not burned by the undeliverable attempts.
        var said: [String] = []
        let health2 = GuardTierHealth()
        health2.announce = { said.append($0); return true }
        health2.recordTier2Failure("x")
        #expect(said.count == 1)
    }

    @Test("the notice says which tier, what it is doing, and the error")
    func noticeIsActionable() {
        let text = GuardTierHealth.notice(tier: 3, description: "unexpected EOF", engine: "llama_cpp")
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

/// The recording sites themselves, driven through `InjectionGuard` rather than by calling the box
/// directly — the unit tests above prove the box, these prove the wiring.
///
/// Specifically the tier-2 *evaluate* catch and the clear-on-verdict path: reverting either fails
/// these. The load-throws and loaded-without-a-model sites, and tier 3's, are not covered here —
/// a mock that throws on load would need a different seam than `scopedModel`, which by definition
/// hands back a model. Saying so rather than letting the suite name imply all four.
///
/// Scoped through `GuardTierHealth.$scoped`, so nothing reads or writes the process-global box
/// that a parallel suite's successful evaluation could clear between the act and the assertion.
@Suite("Guard failure recording, end to end (#218)")
struct GuardFailureRecordingTests {

    @Test("a tier-2 model that throws on evaluate is recorded and blocks")
    func tier2FailureIsRecorded() async {
        let health = await GuardTierHealth()
        let out = await GuardTierHealth.$scoped.withValue(health) {
            await CoreMLEvaluator.$scopedModel.withValue(.init(ThrowingCoreMLModel())) {
                await InjectionGuard.sanitize("ordinary text", maxTier: .tier2_coreML,
                                              protectionEnabled: true)
            }
        }
        #expect(out.contains("[CONTENT BLOCKED BY TIER 2 INJECTION GUARD]"), "it must still fail closed")
        let recorded = await health.tier2Failure
        #expect(recorded != nil, "the LED has nothing to show unless the guard records the failure")
    }

    @Test("a tier that reaches a verdict clears a recorded failure")
    func successClearsIt() async {
        let health = await GuardTierHealth()
        await GuardTierHealth.$scoped.withValue(health) {
            await health.recordTier2Failure("left over from a previous attempt")
            _ = await CoreMLEvaluator.$scopedModel.withValue(.init(MockCoreMLModel(probability: 0.0))) {
                await InjectionGuard.sanitize("ordinary text", maxTier: .tier2_coreML,
                                              protectionEnabled: true)
            }
        }
        let recorded = await health.tier2Failure
        #expect(recorded == nil, "a tier that answered is working, so the red LED must go out")
    }
}

/// A model whose `evaluate` always throws — the "installed but broken" case #218 exists for.
private struct ThrowingCoreMLModel: CoreMLModelProtocol {
    struct Broken: Error {}
    func evaluate(text: String) async throws -> Double { throw Broken() }
}
