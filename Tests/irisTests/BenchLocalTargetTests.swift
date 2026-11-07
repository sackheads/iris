import Testing
import Foundation
@testable import IrisKit

/// #854: `--bench --real` can drive a loopback OpenAI-compatible server (Ollama) as the primary model,
/// with the key held in memory and the tier-3 canary on the same server. The Keychain is never read or
/// written for it, and a non-loopback URL is refused.
@Suite("Bench local target (#854)")
struct BenchLocalTargetTests {
    private static let url = "http://127.0.0.1:11434/v1"

    @Test("parse reads --local-openai, --local-model and --local-canary, and their values are not the scenario path")
    func parseFlags() throws {
        let o = try #require(BenchCLI.parse(["iris", "--bench", "--local-openai", Self.url, "--local-model", "gemma4:12b",
                                             "--local-canary", "qwen3:8b", "scen.json", "--real"]))
        #expect(o.scenarioPath == "scen.json")
        #expect(o.localTarget == BenchLocalTarget(baseURL: Self.url, model: "gemma4:12b", canaryModel: "qwen3:8b"))
    }

    @Test("the canary defaults to gemma4:12b, the model #801 ships")
    func canaryDefault() throws {
        let o = try #require(BenchCLI.parse(["iris", "--bench", "--local-openai", Self.url, "--local-model", "gemma4:12b", "--real"]))
        #expect(o.localTarget?.canaryModel == "gemma4:12b")
    }

    @Test("no flag, no target")
    func none() throws {
        #expect(try #require(BenchCLI.parse(["iris", "--bench", "--real"])).localTarget == nil)
    }

    @Test("a URL without a model, or a model without a URL, is refused")
    func halfGiven() throws {
        let urlOnly = try #require(BenchCLI.parse(["iris", "--bench", "--real", "--local-openai", Self.url]))
        #expect(BenchCLI.refusal(urlOnly, scenario: Self.real)?.contains("--local-model") == true)
        let modelOnly = try #require(BenchCLI.parse(["iris", "--bench", "--real", "--local-model", "gemma4:12b"]))
        #expect(BenchCLI.refusal(modelOnly, scenario: Self.real)?.contains("--local-openai") == true)
    }

    @Test("a loopback URL is allowed, in every spelling of loopback")
    func loopbackAllowed() throws {
        for u in ["http://127.0.0.1:11434/v1", "http://localhost:11434/v1", "http://[::1]:11434/v1"] {
            let o = try #require(BenchCLI.parse(["iris", "--bench", "--real", "--local-openai", u, "--local-model", "m"]))
            #expect(BenchCLI.refusal(o, scenario: Self.real) == nil, "\(u) was refused")
        }
    }

    @Test("a URL that is not loopback is refused, including the lookalikes", arguments: [
        "https://api.openai.com/v1", "http://192.168.1.5:11434/v1", "http://127.0.0.1.evil.example/v1",
        "http://localhost.evil.example/v1", "http://example.com@127.0.0.1.evil.example/v1", "file:///etc/passwd", "ftp://127.0.0.1/v1", "not a url", "",
    ])
    func nonLoopbackRefused(url: String) throws {
        let o = try #require(BenchCLI.parse(["iris", "--bench", "--real", "--local-openai", url, "--local-model", "m"]))
        #expect(BenchCLI.refusal(o, scenario: Self.real)?.contains("loopback") == true, "\(url) was not refused")
    }

    @Test("a local target needs a real run: a fake scenario would ignore it silently")
    func needsReal() throws {
        let o = try #require(BenchCLI.parse(["iris", "--bench", "--local-openai", Self.url, "--local-model", "m"]))
        #expect(BenchCLI.refusal(o, scenario: Self.fake)?.contains("--real") == true)
    }

    @Test("apply points the primary model, every tier and the tier-3 canary at the local server, key in memory")
    @MainActor
    func applySetsEverything() throws {
        let name = "iris-benchlocal-\(UUID().uuidString)"
        let store = try #require(UserDefaults(suiteName: name))
        defer {
            store.removePersistentDomain(forName: name)
            IrisDefaults.removeSuiteFile(named: name, in: IrisDefaults.preferencesDirectory)
        }
        let keychain = KeychainManager(serviceSuffix: ".benchlocal", inMemory: true)
        let config = ConfigManager(store: store, guardedSecrets: keychain)

        BenchLocalTarget(baseURL: Self.url, model: "gemma4:12b", canaryModel: "gemma4:12b").apply(to: config)

        #expect(config.primaryProvider == LLMProvider.openai.rawValue)
        #expect(config.openAIBaseURL == Self.url)
        for tier in [ModelTier.easy, .medium, .hard] { #expect(config.getModel(for: tier) == "gemma4:12b") }
        #expect(config.promptGuardEngine == "ollama")
        #expect(config.promptGuardModel == "gemma4:12b")
        #expect(config.enableAdvancedPromptInjectionProtection)
        #expect(!config.openAIAPIKey.isEmpty)
        #expect(config.enableSandboxing)
    }

    private static var real: Scenario { var s = BenchCLI.defaultScenario; s.clientMode = .real; return s }
    private static var fake: Scenario { BenchCLI.defaultScenario }
}
