import Testing
import Foundation
@testable import IrisKit

/// #472: `AppState.start()` runs again from the setup wizard's finish, and each run posted the
/// Ollama-unreachable warning again. It posts once per process for the same services.
@MainActor
@Suite("Ollama-unreachable warning posts once (#472)")
struct OllamaWarningOnceTests {

    private func harness() -> (ConfigManager, String) {
        let suite = "iris-ollamawarn-\(UUID().uuidString)"
        let store = UserDefaults(suiteName: suite)!
        store.removePersistentDomain(forName: suite)
        let config = ConfigManager(store: store)
        config.enableVibecop = true
        config.vibecopEngine = "ollama"
        config.enableAdvancedPromptInjectionProtection = false
        return (config, suite)
    }

    private func teardown(_ suite: String) {
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        IrisDefaults.removeSuiteFile(named: suite, in: IrisDefaults.preferencesDirectory)
    }

    private func warnings(_ app: AppState, _ id: UUID) -> [String] {
        (app.conversations.first { $0.id == id }?.messages ?? [])
            .filter { $0.role == .system && $0.content.contains("Ollama daemon is not reachable") }
            .map(\.content)
    }

    @Test("a second start-up check posts no second warning")
    func secondCheckIsSilent() async {
        let (config, suite) = harness()
        defer { teardown(suite) }
        let app = AppState()
        let id = UUID()
        app.createNewConversation(id: id)
        let engine = IrisEngine(state: app, client: CapturingLLMClient(), protectionEnabled: false)

        await engine.warnIfOllamaUnreachable(config: config, isReachable: { false })
        await engine.warnIfOllamaUnreachable(config: config, isReachable: { false })

        #expect(warnings(app, id).count == 1)
    }

    @Test("a check that names different services warns again")
    func newServiceWarns() async {
        let (config, suite) = harness()
        defer { teardown(suite) }
        let app = AppState()
        let id = UUID()
        app.createNewConversation(id: id)
        let engine = IrisEngine(state: app, client: CapturingLLMClient(), protectionEnabled: false)

        await engine.warnIfOllamaUnreachable(config: config, isReachable: { false })
        config.enableAdvancedPromptInjectionProtection = true
        config.promptGuardEngine = "ollama"
        await engine.warnIfOllamaUnreachable(config: config, isReachable: { false })

        let posted = warnings(app, id)
        #expect(posted.count == 2)
        #expect(posted.last?.contains("Vibecop Guardian and Prompt Guard") == true)
    }

    @Test("a reachable daemon posts nothing")
    func reachableIsSilent() async {
        let (config, suite) = harness()
        defer { teardown(suite) }
        let app = AppState()
        let id = UUID()
        app.createNewConversation(id: id)
        let engine = IrisEngine(state: app, client: CapturingLLMClient(), protectionEnabled: false)

        await engine.warnIfOllamaUnreachable(config: config, isReachable: { true })

        #expect(warnings(app, id).isEmpty)
    }
}
