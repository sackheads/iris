import XCTest
@testable import iris

@MainActor
final class ModelLEDBarTests: XCTestCase {

    /// ConfigManager writes every setter straight through to UserDefaults, so values set here
    /// outlive the test process and leak into later runs on the same machine. Captured in setUp
    /// and put back in tearDown — without this, leaving prompt-injection protection off here makes
    /// InjectionGuardTests' Tier 2 cases fail on the NEXT run, which is baffling to debug.
    private var savedInjectionProtection: Bool = true

    override func setUp() {
        super.setUp()
        savedInjectionProtection = ConfigManager.shared.enableAdvancedPromptInjectionProtection
        // Reset ConfigManager to known defaults so each test starts clean.
        ConfigManager.shared.primaryProvider = "Gemini"
        ConfigManager.shared.geminiAPIKey = "test-key"
        ConfigManager.shared.anthropicAPIKey = ""
        ConfigManager.shared.openAIAPIKey = ""
        ConfigManager.shared.enableVibecop = false
        ConfigManager.shared.vibecopEngine = "llama_cpp"
        ConfigManager.shared.vibecopModel = ""
        ConfigManager.shared.enableAdvancedPromptInjectionProtection = false
        ConfigManager.shared.promptGuardCoreMLModel = ""
        ConfigManager.shared.promptGuardEngine = "llama_cpp"
        ConfigManager.shared.promptGuardModel = ""
    }

    override func tearDown() {
        ConfigManager.shared.enableAdvancedPromptInjectionProtection = savedInjectionProtection
        super.tearDown()
    }

    // MARK: - Primary LED

    func testPrimaryOffWhenNotConfigured() {
        ConfigManager.shared.primaryProvider = "Gemini"
        ConfigManager.shared.geminiAPIKey = ""
        let bar = ModelLEDBar()
        XCTAssertEqual(bar.primaryState(), .off)
    }

    func testPrimaryReadyWhenConfigured() {
        ConfigManager.shared.primaryProvider = "Anthropic"
        ConfigManager.shared.anthropicAPIKey = "key"
        let bar = ModelLEDBar()
        XCTAssertEqual(bar.primaryState(), .ready)
    }

    func testPrimaryActiveWhenThinking() {
        ConfigManager.shared.primaryProvider = "Anthropic"
        ConfigManager.shared.anthropicAPIKey = "key"
        let bar = ModelLEDBar(isThinking: true)
        XCTAssertEqual(bar.primaryState(), .active)
    }

    // MARK: - Vibecop LED

    func testVibecopOffWhenDisabled() {
        ConfigManager.shared.enableVibecop = false
        let bar = ModelLEDBar()
        XCTAssertEqual(bar.vibecopState(), .off)
    }

    func testVibecopConfiguredWhenGGUFMissing() {
        ConfigManager.shared.enableVibecop = true
        ConfigManager.shared.vibecopEngine = "llama_cpp"
        ConfigManager.shared.vibecopModel = "nonexistent.gguf"
        let bar = ModelLEDBar()
        XCTAssertEqual(bar.vibecopState(), .configured)
    }

    func testVibecopReadyForOllama() {
        ConfigManager.shared.enableVibecop = true
        ConfigManager.shared.vibecopEngine = "ollama"
        let bar = ModelLEDBar()
        XCTAssertEqual(bar.vibecopState(), .ready)
    }

    // MARK: - Tier 1 LED

    func testTier1OffWhenDisabled() {
        ConfigManager.shared.enableAdvancedPromptInjectionProtection = false
        let bar = ModelLEDBar()
        XCTAssertEqual(bar.tier1State(), .off)
    }

    func testTier1ReadyWhenEnabled() {
        ConfigManager.shared.enableAdvancedPromptInjectionProtection = true
        let bar = ModelLEDBar()
        XCTAssertEqual(bar.tier1State(), .ready)
    }

    // MARK: - Tier 2 LED

    func testTier2OffWhenProtectionDisabled() {
        ConfigManager.shared.enableAdvancedPromptInjectionProtection = false
        let bar = ModelLEDBar()
        XCTAssertEqual(bar.tier2State(), .off)
    }

    func testTier2ConfiguredWhenModelFieldEmpty() {
        ConfigManager.shared.enableAdvancedPromptInjectionProtection = true
        ConfigManager.shared.promptGuardCoreMLModel = ""
        let bar = ModelLEDBar()
        XCTAssertEqual(bar.tier2State(), .configured)
    }

    func testTier2ConfiguredWhenModelNotDownloaded() {
        ConfigManager.shared.enableAdvancedPromptInjectionProtection = true
        ConfigManager.shared.promptGuardCoreMLModel = "nonexistent.onnx.zip"
        let bar = ModelLEDBar()
        XCTAssertEqual(bar.tier2State(), .configured)
    }

    // MARK: - Tier 3 LED

    func testTier3OffWhenProtectionDisabled() {
        ConfigManager.shared.enableAdvancedPromptInjectionProtection = false
        let bar = ModelLEDBar()
        XCTAssertEqual(bar.tier3State(), .off)
    }

    func testTier3ConfiguredWhenGGUFMissing() {
        ConfigManager.shared.enableAdvancedPromptInjectionProtection = true
        ConfigManager.shared.promptGuardEngine = "llama_cpp"
        ConfigManager.shared.promptGuardModel = "nonexistent.gguf"
        let bar = ModelLEDBar()
        XCTAssertEqual(bar.tier3State(), .configured)
    }

    func testTier3ReadyForOllama() {
        ConfigManager.shared.enableAdvancedPromptInjectionProtection = true
        ConfigManager.shared.promptGuardEngine = "ollama"
        let bar = ModelLEDBar()
        XCTAssertEqual(bar.tier3State(), .ready)
    }
}
