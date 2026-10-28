import Foundation
import Testing
@testable import IrisKit

private final class Log: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func append(_ s: String) { lock.withLock { lines.append(s) } }
    var all: [String] { lock.withLock { lines } }
}

@Suite("Guard engines built at launch (#792)", .timeLimit(.minutes(1)))
struct LaunchWarmupTests {
    /// A ConfigManager over a suite of its own (Invariant 7), with nothing guarded on.
    private func withConfig(_ body: (ConfigManager, URL) throws -> Void) rethrows {
        let name = "iris-warmup-\(UUID().uuidString)"
        let store = UserDefaults(suiteName: name)!
        let models = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        defer {
            store.removePersistentDomain(forName: name)
            IrisDefaults.removeSuiteFile(named: name, in: IrisDefaults.preferencesDirectory)
            try? FileManager.default.removeItem(at: models)
        }
        let config = ConfigManager(store: store)
        config.enableVibecop = false
        try body(config, models)
    }

    @Test func tier3IsBuiltWhenProtectionIsOnAndTheEngineIsLocal() {
        withConfig { config, models in
            config.enableAdvancedPromptInjectionProtection = true
            config.promptGuardEngine = "ollama"
            config.promptGuardModel = "gemma4:12b"
            let engines = LaunchWarmup.engines(config: config, modelsDir: models)
            #expect(engines.map(\.role) == ["canary"])
            #expect(engines.first?.engineType == .ollama && engines.first?.modelPathOrName == "gemma4:12b")
        }
    }

    @Test func nothingWhenProtectionIsOffOrTier3IsCloud() {
        withConfig { config, models in
            config.promptGuardEngine = "ollama"
            config.enableAdvancedPromptInjectionProtection = false
            #expect(LaunchWarmup.engines(config: config, modelsDir: models).isEmpty)
            config.enableAdvancedPromptInjectionProtection = true
            config.promptGuardEngine = "cloud"
            #expect(LaunchWarmup.engines(config: config, modelsDir: models).isEmpty)
        }
    }

    @Test func mlxIsLeftToFirstUse() {
        withConfig { config, models in
            config.enableAdvancedPromptInjectionProtection = true
            config.promptGuardEngine = "mlx"
            config.enableVibecop = true
            config.vibecopEngine = "mlx"
            #expect(LaunchWarmup.engines(config: config, modelsDir: models).isEmpty)
        }
    }

    @Test func aMissingLlamaModelIsNotBuilt() throws {
        try withConfig { config, models in
            config.enableAdvancedPromptInjectionProtection = true
            config.promptGuardEngine = "llama_cpp"
            config.promptGuardModel = "guard.gguf"
            #expect(LaunchWarmup.engines(config: config, modelsDir: models).isEmpty)
            try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: models.appendingPathComponent("guard.gguf"))
            #expect(LaunchWarmup.engines(config: config, modelsDir: models).map(\.role) == ["canary"])
        }
    }

    @Test func vibecopIsBuiltWhenOnAndLocal() {
        withConfig { config, models in
            config.enableAdvancedPromptInjectionProtection = false
            config.enableVibecop = true
            config.vibecopEngine = "ollama"
            config.vibecopModel = "gemma4:12b"
            #expect(LaunchWarmup.engines(config: config, modelsDir: models).map(\.role) == ["vibecop"])
            config.vibecopEngine = "cloud"
            #expect(LaunchWarmup.engines(config: config, modelsDir: models).isEmpty)
            config.enableVibecop = false
            config.vibecopEngine = "ollama"
            #expect(LaunchWarmup.engines(config: config, modelsDir: models).isEmpty)
        }
    }

    @Test func launchDoesNotWaitForTheLoad() async throws {
        let release = AsyncStream<Void>.makeStream()
        let started = Log()
        let start = TestClock.now()
        let task = try #require(LaunchWarmup.start([.init(role: "canary", engineType: .ollama, modelPathOrName: "m")]) { config in
            started.append(config.role)
            for await _ in release.stream { break }
        })
        #expect(TestClock.seconds(since: start) < 1)
        release.continuation.yield()
        release.continuation.finish()
        try await value(of: task, within: 10)
        #expect(started.all == ["canary"])
        #expect(LaunchWarmup.start([]) == nil)
    }

    @Test func theWarmupIsATrackedLoad() async throws {
        let log = Log()
        let manager = AuxiliaryModelManager(tracker: ModelLoadTracker(log: { log.append($0) }))
        let task = try #require(LaunchWarmup.start([.init(role: "canary", engineType: .llamaCPP,
                                                          modelPathOrName: "missing-\(UUID().uuidString).gguf")]) { config in
            _ = try await manager.getEngine(for: config.role, config: config)
        })
        // Generous: if this is the process's first llama.cpp use, ggml compiles its Metal library
        // first, which took 14 s on CI's runner (#795, run 40634864744); later loads take ~1 ms.
        try await value(of: task, within: 50)
        #expect(log.all.first?.contains("model.load begin purpose=\"guard (tier 3)\"") == true)
        #expect(log.all.last?.contains("failed") == true)
    }
}
