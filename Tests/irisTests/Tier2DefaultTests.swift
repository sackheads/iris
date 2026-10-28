import Testing
import Foundation
@testable import IrisKit

/// #781: a fresh install has no tier-2 model (DeBERTa failed #770's bar), but an install that
/// downloaded the old default without ever saving the field keeps it. Each test has its own store
/// and its own models directory (AGENTS invariant 7); nothing touches `~/.iris` or `.shared`.
@MainActor
@Suite("No tier-2 model by default (#781)")
struct Tier2DefaultTests {
    static let key = "PROMPT_GUARD_COREML_MODEL"

    struct Home {
        let suite: String
        let store: UserDefaults
        let models: URL

        init() throws {
            suite = "iris-tier2default-\(UUID().uuidString)"
            store = UserDefaults(suiteName: suite)!
            store.removePersistentDomain(forName: suite)
            models = FileManager.default.temporaryDirectory.appendingPathComponent("iris-tier2default-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
        }

        /// The old default's bundle as a download leaves it: the unzipped `<name>.onnx` folder.
        func installLegacyBundle(named name: String = "deberta-v3-base-prompt-injection-v2.onnx") throws {
            try FileManager.default.createDirectory(at: models.appendingPathComponent(name), withIntermediateDirectories: true)
        }

        func config() -> ConfigManager { ConfigManager(store: store, modelsDir: models) }

        func tearDown() {
            store.removePersistentDomain(forName: suite)
            IrisDefaults.removeSuiteFile(named: suite, in: IrisDefaults.preferencesDirectory)
            try? FileManager.default.removeItem(at: models)
        }
    }

    @Test("nothing saved and no bundle: no model, tier 2 off, and no launch notice for it")
    func freshInstall() throws {
        let home = try Home(); defer { home.tearDown() }
        let config = home.config()
        #expect(config.promptGuardCoreMLModel == "")
        #expect(home.store.object(forKey: Self.key) == nil, "nothing written")
        let provisioning = InjectionGuard.tier2Provisioning(modelName: config.promptGuardCoreMLModel, modelsDir: home.models)
        #expect(provisioning == .notConfigured)
        config.enableAdvancedPromptInjectionProtection = true
        #expect(ModelLEDBar(config: config).tier2State() == .off)
        #expect(InjectionGuard.unprovisionedGuardNotice(protectionEnabled: true, tier2: provisioning, tier3: .provisioned) == nil)
    }

    @Test("nothing saved but the old default downloaded: it's kept, and nothing is written")
    func inheritsDownloadedBundle() throws {
        let home = try Home(); defer { home.tearDown() }
        try home.installLegacyBundle()
        let config = home.config()
        #expect(config.promptGuardCoreMLModel == ConfigManager.legacyTier2Model)
        #expect(home.store.object(forKey: Self.key) == nil, "inherited, not persisted")
        #expect(InjectionGuard.tier2Provisioning(modelName: config.promptGuardCoreMLModel, modelsDir: home.models) == .provisioned)
    }

    @Test("a saved empty value stays empty, even with the old default downloaded")
    func savedEmptySticks() throws {
        let home = try Home(); defer { home.tearDown() }
        try home.installLegacyBundle()
        home.store.set("", forKey: Self.key)
        #expect(home.config().promptGuardCoreMLModel == "")
    }

    @Test("clearing the field in Settings persists, and the next launch reads it back empty")
    func clearingPersists() throws {
        let home = try Home(); defer { home.tearDown() }
        try home.installLegacyBundle()
        let config = home.config()
        #expect(config.promptGuardCoreMLModel == ConfigManager.legacyTier2Model)
        config.promptGuardCoreMLModel = ""
        #expect(home.store.string(forKey: Self.key) == "")
        #expect(home.config().promptGuardCoreMLModel == "")
    }

    @Test("a saved model is used as is, with or without a bundle")
    func savedModelUsed() throws {
        let home = try Home(); defer { home.tearDown() }
        home.store.set("https://example.org/my-guard.onnx.zip", forKey: Self.key)
        #expect(home.config().promptGuardCoreMLModel == "https://example.org/my-guard.onnx.zip")
        try home.installLegacyBundle()
        #expect(home.config().promptGuardCoreMLModel == "https://example.org/my-guard.onnx.zip")
    }

    @Test("the old default's folder renamed aside (…onnx-no) is no model: neutral, no notice")
    func renamedAside() throws {
        let home = try Home(); defer { home.tearDown() }
        try home.installLegacyBundle(named: "deberta-v3-base-prompt-injection-v2.onnx-no")
        let config = home.config()
        #expect(config.promptGuardCoreMLModel == "")
        #expect(InjectionGuard.tier2Provisioning(modelName: config.promptGuardCoreMLModel, modelsDir: home.models) == .notConfigured)
    }

    @Test("a URL set but not downloaded still reads as not downloaded, as before")
    func unprovisionedUnchanged() throws {
        let home = try Home(); defer { home.tearDown() }
        home.store.set("https://example.org/my-guard.onnx.zip", forKey: Self.key)
        let config = home.config()
        let provisioning = InjectionGuard.tier2Provisioning(modelName: config.promptGuardCoreMLModel, modelsDir: home.models)
        #expect(provisioning == .unprovisioned(modelName: "my-guard.onnx"))
        #expect(InjectionGuard.unprovisionedGuardNotice(protectionEnabled: true, tier2: provisioning, tier3: .provisioned)?
            .contains("tier-2 guard model my-guard.onnx is not downloaded") == true)
    }

    @Test("with tier 2 unset, the launch notice names only a missing tier 3")
    func noticeNamesTier3Alone() {
        let notice = InjectionGuard.unprovisionedGuardNotice(
            protectionEnabled: true, tier2: .notConfigured, tier3: .unprovisioned(modelName: "canary.gguf"))
        #expect(notice == "Prompt-injection protection is on, but the tier-3 guard model canary.gguf is not downloaded. Tier 3 is skipped until it is (Settings \u{2192} Security).")
    }

    @Test("the P2 light with no model says tier 2 is off by choice, not that protection is off")
    func ledDetail() throws {
        let home = try Home(); defer { home.tearDown() }
        let config = home.config()
        config.enableAdvancedPromptInjectionProtection = true
        let detail = ModelLEDBar(config: config).detail(for: .tier2, state: .off, failure: nil)
        #expect(detail.summary.contains("No tier-2 model is set"))
        config.enableAdvancedPromptInjectionProtection = false
        #expect(ModelLEDBar(config: config).detail(for: .tier2, state: .off, failure: nil).summary
                == "Prompt injection protection is turned off.")
    }
}
