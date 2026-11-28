import Testing
import Foundation
@testable import IrisKit

/// #1429 slice 1: a profile names its model as `provider/model`, the snapshot keeps it, and it resolves to a route by the
/// same checks a subagent's provider gets. Nothing routes a conversation by it yet (slice 2). Config is an isolated
/// `ConfigManager(store:)` and an in-memory Keychain (Invariant 7).
@MainActor
@Suite("A profile's model: ModelRef, the registry and its route (#1429)", .timeLimit(.minutes(1)))
struct ModelRefTests {
    private func harness() -> (ConfigManager, KeychainManager, String) {
        let suite = "iris-modelref-\(UUID().uuidString)"
        let store = UserDefaults(suiteName: suite)!
        store.removePersistentDomain(forName: suite)
        let config = ConfigManager(store: store)
        // As SubagentProvidersTests: primary OpenAI with no key, Gemini over ADC (no key needed), Anthropic unconfigured.
        config.primaryProvider = LLMProvider.openai.rawValue
        config.geminiAuthMode = GeminiAuthMode.adc.rawValue
        config.anthropicAuthMode = AnthropicAuthMode.vertex.rawValue
        config.anthropicVertexProject = ""
        return (config, KeychainManager(serviceSuffix: ".test-\(UUID().uuidString)", inMemory: true), suite)
    }

    private func teardown(_ suite: String) {
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        IrisDefaults.removeSuiteFile(named: suite, in: IrisDefaults.preferencesDirectory)
    }

    private func profile(_ frontmatter: String) -> Result<AgentProfile, AgentProfileStore.ParseError> {
        AgentProfileStore.parse(name: "reviewer", data: Data("---\n\(frontmatter)\n---\nReview carefully.\n".utf8))
    }

    @Test("provider/model parses at the first slash, so a model id may hold one")
    func parses() throws {
        #expect(try ModelRef.parse("anthropic/claude-sonnet-5-5").get() == ModelRef(providerId: "anthropic", model: "claude-sonnet-5-5"))
        #expect(try ModelRef.parse(" openrouter/anthropic/claude-x ").get() == ModelRef(providerId: "openrouter", model: "anthropic/claude-x"))
        #expect(ModelRef(providerId: "deepseek", model: "deepseek-v4-pro").text == "deepseek/deepseek-v4-pro")
    }

    @Test("a model with no provider, a provider that isn't an id, or a model that isn't one, is refused")
    func refuses() {
        #expect(ModelRef.parse("claude-sonnet-5-5") == .failure(.noSlash))
        #expect(ModelRef.parse("Anthropic/Claude-X") == .success(ModelRef(providerId: "anthropic", model: "Claude-X")))
        #expect(ModelRef.parse("an_thropic/claude") == .failure(.badProvider("an_thropic")))
        #expect(ModelRef.parse("/claude") == .failure(.badProvider("")))
        #expect(ModelRef.parse("-x/claude") == .failure(.badProvider("-x")))
        #expect(ModelRef.parse("anthropic/") == .failure(.badModel("")))
        #expect(ModelRef.parse("anthropic/has space") == .failure(.badModel("has space")))
    }

    @Test("a profile's model: is read, and a bad one is ignored with a notice, the profile still loading")
    func profileFrontmatter() throws {
        let read = try profile("model: deepseek/deepseek-v4-pro").get()
        #expect(read.model == ModelRef(providerId: "deepseek", model: "deepseek-v4-pro") && read.modelProblem == nil)
        #expect(try profile("tier: hard").get().model == nil, "no model: means the default")
        // Claude Code's agent files say `model: sonnet`: a ported one still loads (dev-2's #1457 review).
        let ported = try profile("model: sonnet\ntier: hard").get()
        #expect(ported.model == nil && ported.tier == .hard)
        let line = try #require(KnownCapabilities(tools: [], mcpServers: [], skills: []).unknownLine(for: ported))
        #expect(line.contains("`model: sonnet` doesn't read") && line.contains(ModelRef.ParseError.noSlash.message) && line.hasSuffix("It is ignored."))
        #expect(KnownCapabilities(tools: [], mcpServers: [], skills: []).unknownLine(for: read) == nil)
    }

    @Test("the snapshot keeps the model, so a file edit doesn't move a conversation, and an old snapshot decodes with none")
    func snapshot() throws {
        let read = try profile("model: deepseek/deepseek-v4-pro").get()
        let back = try JSONDecoder().decode(AgentProfileSnapshot.self, from: JSONEncoder().encode(read.snapshot))
        #expect(back.profile.model == read.model)
        let legacy = #"{"name":"reviewer","prompt":"x"}"#
        #expect(try JSONDecoder().decode(AgentProfileSnapshot.self, from: Data(legacy.utf8)).profile.model == nil)
    }

    @Test("registered models are each usable provider's models, derived from the settings")
    func registered() {
        let (config, keychain, suite) = harness(); defer { teardown(suite) }
        #expect(!config.registeredModels(keychain: keychain).contains { $0.providerId == "gemini" }, "switched off")
        #expect(config.registeredModels(keychain: keychain).contains { $0.providerId == "openai" }, "the primary always")
        config.setSubagentUse(BuiltInSubagentUse(enabled: true), for: .gemini)
        #expect(config.registeredModels(keychain: keychain)
            .contains(ModelRef(providerId: "gemini", model: config.geminiModelHard)))
    }

    @Test("a profile's model routes by the subagent checks: refused, never swapped, when its provider can't take it")
    func routes() throws {
        let (config, keychain, suite) = harness(); defer { teardown(suite) }
        let ref = ModelRef(providerId: "gemini", model: config.geminiModelHard)
        #expect(config.route(for: ref, keychain: keychain) == .failure(.notEnabled("Gemini")))
        #expect(config.route(for: ModelRef(providerId: "anthropic", model: "claude-sonnet-5-5"), keychain: keychain)
            == .failure(.noKey("anthropic", isBuiltIn: true)))
        guard case .failure(.unknownProvider("mistral", _)) = config.route(for: ModelRef(providerId: "mistral", model: "m"), keychain: keychain)
        else { Issue.record("an unknown provider must refuse"); return }

        config.setSubagentUse(BuiltInSubagentUse(enabled: true), for: .gemini)
        let route = try config.route(for: ref, keychain: keychain).get()
        #expect(route.providerId == "gemini" && route.model == config.geminiModelHard)
    }
}
