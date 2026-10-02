import Testing
import Foundation
@testable import iris

/// #181: the Anthropic provider gains an authentication mode mirroring Gemini's, so Claude on
/// Vertex AI is a setting on the provider the app already has, not a second provider. Every
/// test here uses its own `ConfigManager(store:)` over its own suite (invariant 7).
@Suite("Anthropic authentication mode (#181)")
struct AnthropicAuthModeTests {

    private func isolated() -> (ConfigManager, UserDefaults, String) {
        let name = "iris-181-\(UUID().uuidString)"
        let store = UserDefaults(suiteName: name)!
        return (ConfigManager(store: store), store, name)
    }

    private func tearDown(_ store: UserDefaults, _ name: String) {
        store.removePersistentDomain(forName: name)
        IrisDefaults.removeSuiteFile(named: name, in: IrisDefaults.preferencesDirectory)
    }

    @Test("defaults: API key mode, no project, location global")
    func defaults() {
        let (config, store, name) = isolated()
        defer { tearDown(store, name) }
        #expect(config.anthropicAuthMode == AnthropicAuthMode.apiKey.rawValue)
        #expect(config.anthropicVertexProject == "")
        #expect(config.anthropicVertexLocation == "global")
    }

    @Test("the three settings persist and read back through a second manager over the same store")
    func roundTrip() {
        let (config, store, name) = isolated()
        defer { tearDown(store, name) }
        config.anthropicAuthMode = AnthropicAuthMode.vertex.rawValue
        config.anthropicVertexProject = "gke-claude-dev"
        config.anthropicVertexLocation = "us-east5"
        let again = ConfigManager(store: store)
        #expect(again.anthropicAuthMode == AnthropicAuthMode.vertex.rawValue)
        #expect(again.anthropicVertexProject == "gke-claude-dev")
        #expect(again.anthropicVertexLocation == "us-east5")
    }

    @Test("a stored empty location reads back as global, never as an empty path segment")
    func emptyLocationIsGlobal() {
        let (config, store, name) = isolated()
        defer { tearDown(store, name) }
        config.anthropicVertexLocation = "   "
        #expect(config.effectiveVertexLocation == "global")
        #expect(ConfigManager(store: store).anthropicVertexLocation == "global")
    }

    @Test("isConfigured: Vertex mode needs a project and no key; API-key mode needs a key")
    func isConfigured() {
        let (config, store, name) = isolated()
        defer { tearDown(store, name) }
        config.primaryProvider = LLMProvider.anthropic.rawValue
        config.anthropicAPIKey = ""
        #expect(config.isConfigured == false)
        config.anthropicAuthMode = AnthropicAuthMode.vertex.rawValue
        #expect(config.isConfigured == false, "a project is required, never a silent fallback")
        config.anthropicVertexProject = "gke-claude-dev"
        #expect(config.isConfigured == true)
        config.anthropicAuthMode = AnthropicAuthMode.apiKey.rawValue
        #expect(config.isConfigured == false)
        config.anthropicAPIKey = "k"
        #expect(config.isConfigured == true)
    }

    @Test("the transport resolves from the config: direct in API-key mode, Vertex with the token otherwise")
    func transportResolution() async throws {
        let (config, store, name) = isolated()
        defer { tearDown(store, name) }
        config.anthropicAPIKey = "k"
        config.anthropicBaseURL = "https://proxy.example/v1"
        let direct = try await AnthropicTransport.resolve(config: config) { "unused" }
        #expect(direct == .direct(apiKey: "k", baseURL: "https://proxy.example/v1"))

        config.anthropicAuthMode = AnthropicAuthMode.vertex.rawValue
        config.anthropicVertexProject = "gke-claude-dev"
        config.anthropicVertexLocation = "us"
        var tokenCalls = 0
        let vertex = try await AnthropicTransport.resolve(config: config) { tokenCalls += 1; return "ya29.x" }
        #expect(vertex == .vertex(project: "gke-claude-dev", location: "us", accessToken: "ya29.x"))
        #expect(tokenCalls == 1)
    }

    @Test("Vertex mode with no project fails at resolution with a sentence naming the setting")
    func vertexWithoutProjectFails() async {
        let (config, store, name) = isolated()
        defer { tearDown(store, name) }
        config.anthropicAuthMode = AnthropicAuthMode.vertex.rawValue
        config.anthropicVertexProject = ""
        do {
            _ = try await AnthropicTransport.resolve(config: config) { "ya29.x" }
            Issue.record("expected a refusal")
        } catch {
            #expect((error as? APIError)?.message.contains("project") == true)
        }
    }

    @Test("the perf lane skips the Keychain for Anthropic on Vertex as it does for Gemini ADC")
    func keychainBypass() {
        #expect(PerfCLI.shouldBypassKeychain(provider: "Anthropic", geminiAuthMode: GeminiAuthMode.apiKey.rawValue,
                                             anthropicAuthMode: AnthropicAuthMode.vertex.rawValue))
        #expect(!PerfCLI.shouldBypassKeychain(provider: "Anthropic", geminiAuthMode: GeminiAuthMode.apiKey.rawValue,
                                              anthropicAuthMode: AnthropicAuthMode.apiKey.rawValue))
        #expect(PerfCLI.shouldBypassKeychain(provider: "Gemini", geminiAuthMode: GeminiAuthMode.adc.rawValue,
                                             anthropicAuthMode: AnthropicAuthMode.apiKey.rawValue))
    }
}
