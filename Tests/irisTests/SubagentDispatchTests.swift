import Testing
import Foundation
@testable import IrisKit

/// #239 half 2 (PR 2): `invoke_subagent` runs a subagent on a named provider and model. The
/// arguments are declared only when such a provider is usable (Invariant 6); a request resolves
/// before anything is spawned and refuses rather than falling back (Fork D); other families wait
/// out a job run until their pricing lands (#689). Each test has its own config and keychain.
@MainActor
@Suite("Subagent dispatch to other providers (#239)", .timeLimit(.minutes(1)))
struct SubagentDispatchTests {
    private func harness(endpoint: Bool) throws -> (ConfigManager, KeychainManager, String) {
        let suite = "iris-dispatch-\(UUID().uuidString)"
        let store = UserDefaults(suiteName: suite)!
        store.removePersistentDomain(forName: suite)
        let keychain = KeychainManager(serviceSuffix: ".test-\(UUID().uuidString)", inMemory: true)
        let config = ConfigManager(store: store, guardedSecrets: keychain)
        config.primaryProvider = LLMProvider.gemini.rawValue
        config.geminiAuthMode = GeminiAuthMode.adc.rawValue   // keyed with no secret written anywhere
        if endpoint {
            try config.saveSubagentEndpoint(ProviderEndpoint(id: "local-ollama", name: "Ollama", baseURL: "http://localhost:11434/v1",
                                                             models: ["gemma4:12b", "qwen3:8b"], needsKey: false), key: "")
        }
        return (config, keychain, suite)
    }

    private func teardown(_ suite: String) {
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        IrisDefaults.removeSuiteFile(named: suite, in: IrisDefaults.preferencesDirectory)
    }

    private func call(_ name: String, _ args: [String: JSONValue]) -> GeminiResponse {
        GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [Part(functionCall: FunctionCall(name: name, args: args))]))],
                       usageMetadata: nil)
    }

    private func names(_ declaration: FunctionDeclaration) -> Set<String> {
        Set(declaration.parameters?.properties?.keys.map { $0 } ?? [])
    }

    // MARK: the schema (Invariant 6)

    @Test("provider and model are declared only with a usable provider besides the primary")
    func schemaGate() {
        #expect(!names(SubagentManager.toolDeclaration()).contains("provider"))
        #expect(!names(SubagentManager.toolDeclaration()).contains("model"))
        let with = SubagentManager.toolDeclaration(providers: ["local-ollama", "anthropic"])
        #expect(names(with).isSuperset(of: ["provider", "model", "role", "task", "effort"]))
        #expect(with.parameters?.properties?["provider"]?.description?.contains("local-ollama, anthropic") == true)
    }

    @Test("an engine declares the arguments when an endpoint is usable, and not otherwise")
    func engineDeclares() async throws {
        for withEndpoint in [false, true] {
            let (config, _, suite) = try harness(endpoint: withEndpoint)
            defer { teardown(suite) }
            let state = AppState(store: try ConversationStore.inMemory(), tier2Provisioning: .provisioned,
                                 tier3Provisioning: .provisioned, createIfEmpty: false, emitLaunchNotices: false)
            let id = state.createNewConversation(isBackground: false, select: true)
            let client = CapturingLLMClient(reply: "ok")
            let engine = IrisEngine(state: state, tier: .medium, client: client, retryDelays: [], protectionEnabled: false,
                                    sessionPeerCount: 0, subagentConfig: config)
            await engine.processInput("hi", source: "UI", conversationId: id)
            let declared = client.requests.first?.tools?.flatMap(\.functionDeclarations)
                .first { $0.name == "invoke_subagent" }
            let props = try #require(declared?.parameters?.properties)
            #expect((props["provider"] != nil) == withEndpoint, "with endpoint: \(withEndpoint)")
            #expect((props["model"] != nil) == withEndpoint)
        }
    }

    // MARK: resolving before spawn (Fork D)

    @Test("no provider is the parent's own; a bad provider or model refuses, naming what is configured")
    func resolve() async throws {
        let (config, _, suite) = try harness(endpoint: true)
        defer { teardown(suite) }
        let state = AppState(store: try ConversationStore.inMemory(), tier2Provisioning: .provisioned,
                             tier3Provisioning: .provisioned, createIfEmpty: false, emitLaunchNotices: false)
        let id = state.createNewConversation(isBackground: false, select: true)
        let engine = IrisEngine(state: state, client: FakeLLMClient(responses: []), subagentConfig: config)

        guard case .route(nil) = await engine.resolveSubagentRoute([:], effort: "medium", conversationId: id) else {
            Issue.record("no provider must be the parent's own"); return
        }
        guard case .refused(let unknown) = await engine.resolveSubagentRoute(["provider": .string("deepseek")], effort: "medium", conversationId: id) else {
            Issue.record("an unknown provider must refuse"); return
        }
        #expect(unknown.contains("No provider `deepseek`") && unknown.contains("local-ollama"))
        guard case .refused(let alias) = await engine.resolveSubagentRoute(["provider": .string("local-ollama"), "model": .string("gemma4")],
                                                                          effort: "medium", conversationId: id) else {
            Issue.record("a bare alias must refuse"); return
        }
        #expect(alias.contains("isn't in provider `local-ollama`'s list"))
        guard case .refused = await engine.resolveSubagentRoute(["model": .string("gemma4:12b")], effort: "medium", conversationId: id) else {
            Issue.record("a model with no provider must refuse"); return
        }
        guard case .route(let route?) = await engine.resolveSubagentRoute(["provider": .string("local-ollama"), "model": .string("qwen3:8b")],
                                                                         effort: "medium", conversationId: id) else {
            Issue.record("a configured provider and model must resolve"); return
        }
        #expect(route.providerId == "local-ollama" && route.model == "qwen3:8b")
    }

    @Test("another family is refused inside a job run, at any depth; the primary is not")
    func jobRunRefusal() async throws {
        let (config, _, suite) = try harness(endpoint: true)
        defer { teardown(suite) }
        let state = AppState(store: try ConversationStore.inMemory(), tier2Provisioning: .provisioned,
                             tier3Provisioning: .provisioned, createIfEmpty: false, emitLaunchNotices: false)
        let job = state.createNewConversation(isBackground: true, select: false)
        // A job's subagent's subagent: background by inheritance, as `runSubagent` creates it.
        let nested = state.createNewConversation(isSubagent: true, isBackground: true, select: false)
        let engine = IrisEngine(state: state, client: FakeLLMClient(responses: []), subagentConfig: config)
        for conversation in [job, nested] {
            guard case .refused(let message) = await engine.resolveSubagentRoute(["provider": .string("local-ollama")], effort: "medium",
                                                                                conversationId: conversation) else {
                Issue.record("another family must be refused in a job run"); continue
            }
            #expect(message == SubagentManager.jobRunOtherFamilyRefusal)
        }
        guard case .route(let primary?) = await engine.resolveSubagentRoute(["provider": .string("gemini")], effort: "easy", conversationId: job) else {
            Issue.record("the primary stays allowed in a job run"); return
        }
        #expect(primary.target == .builtIn(.gemini) && primary.model == config.geminiModelEasy)
    }

    // MARK: running on the route

    @Test("a routed subagent runs on the routed client, and its result names the route actually used")
    func runsOnRoute() async throws {
        let app = AppState()
        app.autoApproveTools = true
        let parent = app.createNewConversation(select: false)
        let parentClient = FakeLLMClient(responses: [])
        let routedClient = FakeLLMClient(responses: [call("goal_complete", ["summary": .string("reviewed")])])
        let route = ProviderRoute(providerId: "local-ollama", target: .endpoint(baseURL: "http://localhost:11434/v1", apiKey: ""),
                                  model: "gemma4:12b")
        let outcome = await SubagentManager.shared.runSubagent(role: "security", task: "review", effort: "medium",
                                                               parentConversationId: parent, client: parentClient,
                                                               route: route, routedClient: routedClient, appState: app)
        #expect(outcome.status == .completed)
        #expect(routedClient.callCount == 1, "the subagent spoke to the routed client")
        #expect(parentClient.callCount == 0, "and never to the parent's")
        #expect(outcome.rendered.contains("Ran on provider `local-ollama`, model `gemma4:12b`."))
    }

    @Test("a routed subagent's own subagent, with no provider named, stays on the route; grading stays on the primary")
    func nestedInheritsRoute() async throws {
        let app = AppState()
        app.autoApproveTools = true
        let parent = app.createNewConversation(select: false)
        let route = ProviderRoute(providerId: "local-ollama", target: .endpoint(baseURL: "http://localhost:11434/v1", apiKey: ""),
                                  model: "gemma4:12b")
        // One scripted endpoint, shared in turn: the child delegates, the grandchild finishes, the child finishes.
        let routedClient = FakeLLMClient(responses: [
            call("invoke_subagent", ["role": .string("helper"), "task": .string("look"), "effort": .string("easy")]),
            call("goal_complete", ["summary": .string("grandchild done")]),
            call("goal_complete", ["summary": .string("child done")]),
        ])
        let primaryClient = FakeLLMClient(responses: [])
        let outcome = await SubagentManager.shared.runSubagent(role: "reviewer", task: "review", effort: "medium",
                                                               parentConversationId: parent, client: primaryClient,
                                                               route: route, routedClient: routedClient, appState: app)
        #expect(outcome.status == .completed)
        #expect(routedClient.callCount == 3, "the grandchild spoke to the route too")
        #expect(primaryClient.callCount == 0)
        let child = try #require(app.conversations.first { $0.isSubagent && $0.title.contains("reviewer") })
        let results = child.history.flatMap(\.parts).compactMap(\.functionResponse).map { "\($0.response)" }
        #expect(results.contains { $0.contains("Ran on provider `local-ollama`, model `gemma4:12b`.") },
                "the grandchild's result names the inherited route")
    }

    @Test("a subagent on a custom endpoint asks Allow Once only, and the dialog names the provider and model")
    func endpointApprovalIsAllowOnce() async throws {
        let app = AppState()
        app.autoApproveTools = false
        let parent = app.createNewConversation(select: false)
        let command = "true --never-run-\(UUID().uuidString)"
        let routedClient = FakeLLMClient(responses: [
            call("run_command", ["command": .string(command)]),
            call("goal_complete", ["summary": .string("asked")]),
        ])
        let route = ProviderRoute(providerId: "local-ollama", target: .endpoint(baseURL: "http://localhost:11434/v1", apiKey: ""),
                                  model: "gemma4:12b")
        let run = Task {
            await SubagentManager.shared.runSubagent(role: "worker", task: "t", effort: "easy", parentConversationId: parent,
                                                     client: FakeLLMClient(responses: []), route: route,
                                                     routedClient: routedClient, appState: app)
        }
        let end = TestClock.deadline(20)
        while app.pendingApprovals.isEmpty, TestClock.now() < end { try await Task.sleep(nanoseconds: 20_000_000) }
        let request = try #require(app.pendingApprovals.first)
        #expect(request.origin.contains("on local-ollama · gemma4:12b"))
        #expect(!request.offersAlwaysAllow, "Allow Once only (Brian, \"1: a\")")
        app.resolveApproval(id: request.id, .deny)
        _ = try await value(of: run, within: 20)
    }
}
