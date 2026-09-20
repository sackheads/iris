import Testing
import Foundation
@testable import iris

/// #210: mirror of #202 for tier 2. `InjectionGuard.executeTier2CoreML` used to swallow any load
/// error via `try?` and let `CoreMLEvaluator.evaluate` fall back to a "safe" 0.0 when no model was
/// loaded, so an absent *or* broken tier-2 model silently passed everything while the LED still
/// read "enabled, not loaded". These tests cover the pure predicate and the pure launch-notice
/// text; neither touches `ConfigManager.shared`, `IrisDefaults.store`, `~/.iris`, or
/// `CoreMLEvaluator.shared` — everything is driven through a temp directory and explicit
/// arguments.
///
/// Deliberately not covered here (unlike tier 3's `testTier3SkippedWhenModelUnprovisioned` /
/// `testRegisteredEngineOverridesFileAbsence` / `testSkippedVerdictDoesNotOutliveProvisioning` in
/// InjectionGuardTests.swift): a dynamic `sanitize()`-level test proving the tier-2 skip falls
/// through to tier 3, and one proving a skipped-tier-2 cache entry is invalidated once the model
/// appears. Both would need `CoreMLEvaluator.shared.hasModelLoaded` to be reliably `false` at the
/// start of the test. Tier 3's equivalent tests get this via `AuxiliaryModelManager.unloadEngine`,
/// which already existed as production API before #202; `CoreMLEvaluator` has no such
/// unload/reset, only `setModel` (used throughout InjectionGuardTests.swift and
/// EngineInstrumentationTests.swift to *install* a model), so once any test in the process has
/// called it — and several already do — the shared singleton stays "loaded" for the rest of the
/// run and a later test cannot force it back to "unprovisioned". Per the brief's ruling, adding a
/// reset seam to `CoreMLEvaluator` is out of scope for this PR; the skip path (the predicate above,
/// which never touches `CoreMLEvaluator`) and the verdict mapping (the `.unprovisioned`/
/// `.notConfigured` → `.skipped` mapping and `.skipped` being cached alongside `.safe`, both in
/// `InjectionGuard.executeTier2CoreML`/`sanitize`) are covered by predicate tests and code
/// structure instead — mirroring `.skipped`'s existing, already-tested tier-3 handling exactly.
@Suite("Tier 2 provisioning predicate")
struct Tier2ProvisioningTests {

    private func makeTempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("iris-tier2-provisioning-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("provisioned when the unzipped model directory exists in the models dir")
    func provisionedWhenDirectoryExists() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let modelDir = dir.appendingPathComponent("some-model.onnx")
        try FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)

        let result = InjectionGuard.tier2Provisioning(modelName: "some-model.onnx", modelsDir: dir)
        #expect(result == .provisioned)
    }

    @Test("unprovisioned when the directory is absent from the models dir")
    func unprovisionedWhenDirectoryAbsent() {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let result = InjectionGuard.tier2Provisioning(modelName: "missing-model.onnx", modelsDir: dir)
        #expect(result == .unprovisioned(modelName: "missing-model.onnx"))
    }

    @Test("a .zip-suffixed, URL-valued model name resolves to the same unzipped directory")
    func zipAndURLValuedModelNameResolves() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let modelDir = dir.appendingPathComponent("deberta-v3-base-prompt-injection-v2.onnx")
        try FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)

        let urlName = "https://luthen.scromp.net/iris/deberta-v3-base-prompt-injection-v2.onnx.zip"
        let result = InjectionGuard.tier2Provisioning(modelName: urlName, modelsDir: dir)
        #expect(result == .provisioned)

        // Also confirm the unprovisioned case reports the resolved (unzipped) directory name, not
        // the raw URL or the .zip-suffixed filename.
        let missingDir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: missingDir) }
        let missingResult = InjectionGuard.tier2Provisioning(modelName: urlName, modelsDir: missingDir)
        #expect(missingResult == .unprovisioned(modelName: "deberta-v3-base-prompt-injection-v2.onnx"))
    }

    @Test("an empty model name is notConfigured, even with a nonexistent models dir")
    func emptyModelNameIsNotConfigured() {
        let dir = makeTempDir()
        try? FileManager.default.removeItem(at: dir) // guarantee it doesn't exist

        let result = InjectionGuard.tier2Provisioning(modelName: "", modelsDir: dir)
        #expect(result == .notConfigured)
    }
}

/// #210: the combined launch-notice text naming whichever of tier 2 / tier 3 are unprovisioned.
/// Replaces the #202-only `tier3UnprovisionedNotice`.
@Suite("Unprovisioned guard notice text")
struct UnprovisionedGuardNoticeTests {

    @Test("nil when protection is off, even if both tiers are unprovisioned")
    func nilWhenProtectionOff() {
        let notice = InjectionGuard.unprovisionedGuardNotice(
            protectionEnabled: false,
            tier2: .unprovisioned(modelName: "coreml-model.onnx"),
            tier3: .unprovisioned(modelName: "canary-model.gguf"))
        #expect(notice == nil)
    }

    @Test("nil when protection is on and both tiers are provisioned")
    func nilWhenBothProvisioned() {
        let notice = InjectionGuard.unprovisionedGuardNotice(
            protectionEnabled: true, tier2: .provisioned, tier3: .provisioned)
        #expect(notice == nil)
    }

    @Test("singular form names only the tier-2 model when tier 3 is provisioned")
    func singularTier2Only() {
        let notice = InjectionGuard.unprovisionedGuardNotice(
            protectionEnabled: true,
            tier2: .unprovisioned(modelName: "coreml-model.onnx"),
            tier3: .provisioned)
        #expect(notice == "Prompt-injection protection is on, but the tier-2 guard model coreml-model.onnx is not downloaded. Tier 2 is skipped until it is (Settings \u{2192} Security).")
    }

    @Test("singular form names only the tier-3 model when tier 2 is provisioned (unchanged wording from #202)")
    func singularTier3Only() {
        let notice = InjectionGuard.unprovisionedGuardNotice(
            protectionEnabled: true,
            tier2: .provisioned,
            tier3: .unprovisioned(modelName: "canary-model.gguf"))
        #expect(notice == "Prompt-injection protection is on, but the tier-3 guard model canary-model.gguf is not downloaded. Tier 3 is skipped until it is (Settings \u{2192} Security).")
    }

    @Test("notConfigured is named like unprovisioned, without a filename")
    func notConfiguredNamedWithoutFilename() {
        let notice = InjectionGuard.unprovisionedGuardNotice(
            protectionEnabled: true, tier2: .notConfigured, tier3: .provisioned)
        #expect(notice == "Prompt-injection protection is on, but the tier-2 guard model is not downloaded. Tier 2 is skipped until it is (Settings \u{2192} Security).")
    }

    @Test("plural form names both models when both are unprovisioned")
    func pluralBothMissing() {
        let notice = InjectionGuard.unprovisionedGuardNotice(
            protectionEnabled: true,
            tier2: .unprovisioned(modelName: "coreml-model.onnx"),
            tier3: .unprovisioned(modelName: "canary-model.gguf"))
        let unwrapped = try? #require(notice)
        #expect(unwrapped?.contains("tier-2 guard model coreml-model.onnx") == true)
        #expect(unwrapped?.contains("tier-3 guard model canary-model.gguf") == true)
        #expect(unwrapped?.contains("Those tiers are skipped until they are") == true)
        #expect(unwrapped?.contains("Settings \u{2192} Security") == true)
    }
}
