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

    /// The pure rule, with literals: setting `config.anthropicAPIKey` would write the
    /// process-global Keychain store (invariant 7), so the instance property is exercised only
    /// on the Vertex branch, which never reads the key.
    @Test("isConfigured: Vertex mode needs a project and no key; API-key mode needs a key")
    func isConfigured() {
        func configured(mode: String, key: String, project: String) -> Bool {
            ConfigManager.isConfigured(provider: LLMProvider.anthropic.rawValue, geminiAuthMode: GeminiAuthMode.apiKey.rawValue, geminiAPIKey: "",
                                       anthropicAuthMode: mode, anthropicAPIKey: key, anthropicVertexProject: project, openAIAPIKey: "")
        }
        #expect(configured(mode: AnthropicAuthMode.apiKey.rawValue, key: "", project: "gke-claude-dev") == false)
        #expect(configured(mode: AnthropicAuthMode.apiKey.rawValue, key: "k", project: "") == true)
        #expect(configured(mode: AnthropicAuthMode.vertex.rawValue, key: "k", project: "") == false, "a project is required, never a silent fallback")
        #expect(configured(mode: AnthropicAuthMode.vertex.rawValue, key: "", project: "gke-claude-dev") == true)
        #expect(configured(mode: AnthropicAuthMode.vertex.rawValue, key: "", project: "   ") == false)

        let (config, store, name) = isolated()
        defer { tearDown(store, name) }
        config.primaryProvider = LLMProvider.anthropic.rawValue
        config.anthropicAuthMode = AnthropicAuthMode.vertex.rawValue
        #expect(config.isConfigured == false)
        config.anthropicVertexProject = "gke-claude-dev"
        #expect(config.isConfigured == true)
    }

    @Test("the transport resolves from the settings: direct in API-key mode, Vertex with the token otherwise")
    func transportResolution() async throws {
        let direct = try await AnthropicTransport.resolve(authMode: AnthropicAuthMode.apiKey.rawValue, apiKey: "k", baseURL: "https://proxy.example/v1",
                                                          project: "", location: "global") { "unused" }
        #expect(direct == .direct(apiKey: "k", baseURL: "https://proxy.example/v1"))

        var tokenCalls = 0
        let vertex = try await AnthropicTransport.resolve(authMode: AnthropicAuthMode.vertex.rawValue, apiKey: "", baseURL: "",
                                                          project: " gke-claude-dev ", location: "us") { tokenCalls += 1; return "ya29.x" }
        #expect(vertex == .vertex(project: "gke-claude-dev", location: "us", accessToken: "ya29.x"))
        #expect(tokenCalls == 1)
    }

    @Test("Vertex mode with no project, a bad project or a bad location fails before the token is fetched")
    func vertexRefusals() async {
        for (project, location, word) in [("", "global", "project"), ("Bad/Project", "global", "project"), ("gke-claude-dev", "foo.example.com/x?", "location")] {
            var tokenCalls = 0
            do {
                _ = try await AnthropicTransport.resolve(authMode: AnthropicAuthMode.vertex.rawValue, apiKey: "", baseURL: "",
                                                         project: project, location: location) { tokenCalls += 1; return "ya29.x" }
                Issue.record("expected a refusal for \(project.debugDescription) / \(location.debugDescription)")
            } catch {
                #expect((error as? APIError)?.message.lowercased().contains(word) == true)
            }
            #expect(tokenCalls == 0, "no token fetch for a settings mistake")
        }
    }

    @Test("the router's seam resolves Vertex mode from an injected config with an injected token")
    func routerSeam() async throws {
        let (config, store, name) = isolated()
        defer { tearDown(store, name) }
        config.anthropicAuthMode = AnthropicAuthMode.vertex.rawValue
        config.anthropicVertexProject = "gke-claude-dev"
        config.anthropicVertexLocation = "eu"
        let transport = try await LLMClient.anthropicTransport(config: config) { "ya29.seam" }
        #expect(transport == .vertex(project: "gke-claude-dev", location: "eu", accessToken: "ya29.seam"))
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
