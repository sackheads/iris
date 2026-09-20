import Testing
import Foundation
@testable import iris

/// #202: tier 3 must distinguish "no model provisioned" (skip, tiers 1/2 still ran) from "model
/// present but failed to load" (fail closed, unchanged). These tests cover the pure predicate and
/// the pure launch-notice text; neither touches `ConfigManager.shared`, `IrisDefaults.store`, or
/// `~/.iris` — everything is driven through a temp directory and explicit arguments.
@Suite("Tier 3 provisioning predicate")
struct Tier3ProvisioningTests {

    private func makeTempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("iris-tier3-provisioning-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("provisioned when the gguf file exists in the models dir")
    func provisionedWhenFileExists() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let modelFile = dir.appendingPathComponent("some-model.gguf")
        try "not a real model, just needs to exist".write(to: modelFile, atomically: true, encoding: .utf8)

        let result = InjectionGuard.tier3Provisioning(engine: "llama_cpp", modelName: "some-model.gguf", modelsDir: dir)
        #expect(result == .provisioned)
    }

    @Test("unprovisioned when the file is absent from the models dir")
    func unprovisionedWhenFileAbsent() {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let result = InjectionGuard.tier3Provisioning(engine: "llama_cpp", modelName: "missing-model.gguf", modelsDir: dir)
        #expect(result == .unprovisioned(modelName: "missing-model.gguf"))
    }

    @Test("a URL-valued model name resolves to its last path component")
    func urlValuedModelNameResolves() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let modelFile = dir.appendingPathComponent("Qwen3.5-2B-Q4_K_M.gguf")
        try "stub".write(to: modelFile, atomically: true, encoding: .utf8)

        let urlName = "https://huggingface.co/unsloth/Qwen3.5-2B-GGUF/resolve/main/Qwen3.5-2B-Q4_K_M.gguf"
        let result = InjectionGuard.tier3Provisioning(engine: "llama_cpp", modelName: urlName, modelsDir: dir)
        #expect(result == .provisioned)

        // Also confirm the unprovisioned case reports the resolved filename, not the raw URL.
        let missingDir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: missingDir) }
        let missingResult = InjectionGuard.tier3Provisioning(engine: "llama_cpp", modelName: urlName, modelsDir: missingDir)
        #expect(missingResult == .unprovisioned(modelName: "Qwen3.5-2B-Q4_K_M.gguf"))
    }

    @Test("non-llama_cpp engines are always provisioned, even with a nonexistent models dir")
    func nonLlamaCppEnginesAlwaysProvisioned() {
        let dir = makeTempDir()
        try? FileManager.default.removeItem(at: dir) // guarantee it doesn't exist

        for engine in ["cloud", "ollama", "mlx"] {
            let result = InjectionGuard.tier3Provisioning(engine: engine, modelName: "irrelevant.gguf", modelsDir: dir)
            #expect(result == .provisioned, "engine \(engine) should always be provisioned")
        }
    }

    // Launch-notice text for tier 3 (and the combined tier-2/tier-3 form) moved to
    // `UnprovisionedGuardNoticeTests` in Tier2ProvisioningTests.swift (#210): the notice function
    // now names whichever of tier 2 / tier 3 are unprovisioned, replacing the tier-3-only
    // `tier3UnprovisionedNotice` this suite used to test directly.
}
