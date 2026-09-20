import XCTest
@testable import iris

@MainActor
final class ModelLEDBarTests: XCTestCase {

    /// Each test gets its OWN ConfigManager over its OWN UserDefaults suite rather than mutating
    /// `ConfigManager.shared`, which is process-global: parallel suites racing on it is the in-run
    /// half of #109. A storeless `ConfigManager()` is a separate object over the same process-global
    /// store (#193), so it is not isolation by itself — the injected suite is what isolates us.
    /// `ModelLEDBar` already takes an injectable `config`, so nothing here needs the singleton.
    private var config = ConfigManager()
    private var suiteName = ""

    override func setUp() {
        super.setUp()
        suiteName = "iris-modelledbar-\(UUID().uuidString)"
        let store = UserDefaults(suiteName: suiteName)!
        store.removePersistentDomain(forName: suiteName)
        config = ConfigManager(store: store)
        // Known defaults so each test starts clean.
        config.primaryProvider = "Gemini"
        config.geminiAPIKey = "test-key"
        config.anthropicAPIKey = ""
        config.openAIAPIKey = ""
        config.enableVibecop = false
        config.vibecopEngine = "llama_cpp"
        config.vibecopModel = ""
        config.enableAdvancedPromptInjectionProtection = false
        config.promptGuardCoreMLModel = ""
        config.promptGuardEngine = "llama_cpp"
        config.promptGuardModel = ""
    }

    override func tearDown() {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        // removePersistentDomain does not delete the backing plist on current macOS (#178);
        // IrisDefaults sweeps stale iris-*-<UUID> plists by age, but clean up anyway.
        IrisDefaults.removeSuiteFile(named: suiteName, in: IrisDefaults.preferencesDirectory)
        super.tearDown()
    }

    // MARK: - Primary LED

    func testPrimaryOffWhenNotConfigured() {
        config.primaryProvider = "Gemini"
        config.geminiAPIKey = ""
        let bar = ModelLEDBar(config: config)
        XCTAssertEqual(bar.primaryState(), .off)
    }

    func testPrimaryReadyWhenConfigured() {
        config.primaryProvider = "Anthropic"
        config.anthropicAPIKey = "key"
        let bar = ModelLEDBar(config: config)
        XCTAssertEqual(bar.primaryState(), .ready)
    }

    func testPrimaryActiveWhenThinking() {
        config.primaryProvider = "Anthropic"
        config.anthropicAPIKey = "key"
        let bar = ModelLEDBar(config: config, isThinking: true)
        XCTAssertEqual(bar.primaryState(), .active)
    }

    // MARK: - Vibecop LED

    func testVibecopOffWhenDisabled() {
        config.enableVibecop = false
        let bar = ModelLEDBar(config: config)
        XCTAssertEqual(bar.vibecopState(), .off)
    }

    func testVibecopConfiguredWhenGGUFMissing() {
        config.enableVibecop = true
        config.vibecopEngine = "llama_cpp"
        config.vibecopModel = "nonexistent.gguf"
        let bar = ModelLEDBar(config: config)
        XCTAssertEqual(bar.vibecopState(), .configured)
    }

    func testVibecopReadyForOllama() {
        config.enableVibecop = true
        config.vibecopEngine = "ollama"
        let bar = ModelLEDBar(config: config)
        XCTAssertEqual(bar.vibecopState(), .ready)
    }

    // MARK: - Tier 1 LED

    func testTier1OffWhenDisabled() {
        config.enableAdvancedPromptInjectionProtection = false
        let bar = ModelLEDBar(config: config)
        XCTAssertEqual(bar.tier1State(), .off)
    }

    func testTier1ReadyWhenEnabled() {
        config.enableAdvancedPromptInjectionProtection = true
        let bar = ModelLEDBar(config: config)
        XCTAssertEqual(bar.tier1State(), .ready)
    }

    // MARK: - Tier 2 LED

    func testTier2OffWhenProtectionDisabled() {
        config.enableAdvancedPromptInjectionProtection = false
        let bar = ModelLEDBar(config: config)
        XCTAssertEqual(bar.tier2State(), .off)
    }

    func testTier2ConfiguredWhenModelFieldEmpty() {
        config.enableAdvancedPromptInjectionProtection = true
        config.promptGuardCoreMLModel = ""
        let bar = ModelLEDBar(config: config)
        XCTAssertEqual(bar.tier2State(), .configured)
    }

    func testTier2ConfiguredWhenModelNotDownloaded() {
        config.enableAdvancedPromptInjectionProtection = true
        config.promptGuardCoreMLModel = "nonexistent.onnx.zip"
        let bar = ModelLEDBar(config: config)
        XCTAssertEqual(bar.tier2State(), .configured)
    }

    // MARK: - Tier 3 LED

    func testTier3OffWhenProtectionDisabled() {
        config.enableAdvancedPromptInjectionProtection = false
        let bar = ModelLEDBar(config: config)
        XCTAssertEqual(bar.tier3State(), .off)
    }

    func testTier3UnprovisionedWhenGGUFMissing() {
        // #202: an absent tier-3 model is a distinct LED state from "downloaded but not loaded" —
        // the guard skips tier 3 entirely rather than blocking, and the LED must say so.
        config.enableAdvancedPromptInjectionProtection = true
        config.promptGuardEngine = "llama_cpp"
        config.promptGuardModel = "nonexistent.gguf"
        let bar = ModelLEDBar(config: config)
        XCTAssertEqual(bar.tier3State(), .unprovisioned)
    }

    func testTier3ReadyForOllama() {
        config.enableAdvancedPromptInjectionProtection = true
        config.promptGuardEngine = "ollama"
        let bar = ModelLEDBar(config: config)
        XCTAssertEqual(bar.tier3State(), .ready)
    }
}
