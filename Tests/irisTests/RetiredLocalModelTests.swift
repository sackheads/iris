import Testing
import Foundation
@testable import IrisKit

/// #932: Qwen3.5-2B blocked or fail-closed every text through the `llama_cpp` canary, so it is no
/// longer offered, and a saved choice of it (or of the older Qwen-1.5B) becomes the Gemma default.
/// Each test builds its own `ConfigManager(store:)` over its own suite, never `ConfigManager.shared`.
@Suite("Retired local guard models (#932)")
struct RetiredLocalModelTests {
    private func suite(_ tag: String) -> (UserDefaults, String) {
        let name = "iris-retired-\(tag)-\(UUID().uuidString)"
        let store = UserDefaults(suiteName: name)!
        store.removePersistentDomain(forName: name)
        return (store, name)
    }

    private func cleanup(_ store: UserDefaults, _ name: String) {
        store.removePersistentDomain(forName: name)
        IrisDefaults.removeSuiteFile(named: name, in: IrisDefaults.preferencesDirectory)
    }

    @Test("a fresh install's tier-3 and Vibecop model is Gemma E2B, and nothing offers Qwen")
    @MainActor
    func freshDefaultIsGemma() {
        let (store, name) = suite("fresh")
        defer { cleanup(store, name) }
        let config = ConfigManager(store: store)
        #expect(config.promptGuardModel == "gemma-4-E2B-it-Q4_K_M.gguf")
        #expect(config.vibecopModel == "gemma-4-E2B-it-Q4_K_M.gguf")
        #expect(ModelDownloader().knownModels.keys.allSatisfy { !$0.lowercased().contains("qwen") })
        #expect(ModelDownloader().knownModelSizes.keys.allSatisfy { !$0.lowercased().contains("qwen") })
    }

    @Test("a saved Qwen3.5-2B or Qwen-1.5B tier-3 model is replaced by the Gemma default, and the store is rewritten")
    func savedQwenIsMigrated() {
        for retired in ["Qwen3.5-2B-Q4_K_M.gguf", "Qwen-1.5B-Q4_K_M.gguf",
                        "https://huggingface.co/unsloth/Qwen3.5-2B-GGUF/resolve/main/Qwen3.5-2B-Q4_K_M.gguf"] {
            let (store, name) = suite("tier3")
            defer { cleanup(store, name) }
            store.set(retired, forKey: "PROMPT_GUARD_MODEL")
            let config = ConfigManager(store: store)
            #expect(config.promptGuardModel == "gemma-4-E2B-it-Q4_K_M.gguf", "\(retired)")
            #expect(store.string(forKey: "PROMPT_GUARD_MODEL") == "gemma-4-E2B-it-Q4_K_M.gguf", "\(retired) is migrated once, in the store")
        }
    }

    @Test("a saved Qwen Vibecop model is migrated the same way")
    func savedQwenVibecopIsMigrated() {
        let (store, name) = suite("vibecop")
        defer { cleanup(store, name) }
        store.set("Qwen3.5-2B-Q4_K_M.gguf", forKey: "VIBECOP_MODEL")
        let config = ConfigManager(store: store)
        #expect(config.vibecopModel == "gemma-4-E2B-it-Q4_K_M.gguf")
    }

    @Test("a model the user chose that is not retired is left alone, Qwen or not")
    func otherChoicesKept() {
        for chosen in ["gemma-4-12B-it-Q4_K_M.gguf", "Qwen3-8B-Q4_K_M.gguf", "my-own-model.gguf"] {
            let (store, name) = suite("kept")
            defer { cleanup(store, name) }
            store.set(chosen, forKey: "PROMPT_GUARD_MODEL")
            let config = ConfigManager(store: store)
            #expect(config.promptGuardModel == chosen)
            #expect(store.string(forKey: "PROMPT_GUARD_MODEL") == chosen)
        }
    }

    @Test("a migrated user with no Gemma file lands in the not-downloaded state, not a broken canary")
    func migratedUserIsUnprovisioned() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("iris-932-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let (store, name) = suite("unprovisioned")
        defer { cleanup(store, name) }
        let migrated = ConfigManager.migratedLocalModel("Qwen3.5-2B-Q4_K_M.gguf", key: "PROMPT_GUARD_MODEL", in: store)
        #expect(InjectionGuard.tier3Provisioning(engine: "llama_cpp", modelName: migrated, modelsDir: dir)
                == .unprovisioned(modelName: "gemma-4-E2B-it-Q4_K_M.gguf"))
    }
}
