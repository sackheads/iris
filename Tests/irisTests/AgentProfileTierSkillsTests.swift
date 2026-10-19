import Foundation
import Testing
@testable import IrisKit

/// #465 part 3: a conversation's own tier (`/model`, #667), a profile's tier, and a profile's
/// skills list. Profile files go in a temp home of the test's own (Invariant 7).
@MainActor
@Suite("Agent profile tier and skills (#465, #667)", .timeLimit(.minutes(1)))
struct AgentProfileTierSkillsTests {
    private final class Recorder: LLMClientProtocol, @unchecked Sendable {
        private let lock = NSLock()
        private var seen: [(tier: ModelTier, system: String)] = []
        var calls: [(tier: ModelTier, system: String)] { lock.withLock { seen } }
        func generateContent(request: GeminiRequest, tier: ModelTier) async throws -> GeminiResponse {
            lock.withLock { seen.append((tier, request.systemInstruction?.parts.compactMap(\.text).joined() ?? "")) }
            return GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [Part(text: "ok")]))], usageMetadata: nil)
        }
    }

    private func setUp(_ profile: String) throws -> (AppState, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("iris-465c-\(UUID().uuidString)")
        let store = AgentProfileStore(paths: IrisPaths(root: root))
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        try Data(profile.utf8).write(to: store.directory.appendingPathComponent("reviewer.md"))
        let app = AppState(store: try ConversationStore.inMemory(), createIfEmpty: false, emitLaunchNotices: false)
        app.agentProfiles = store
        return (app, root)
    }

    private func engine(_ app: AppState, _ client: Recorder) -> IrisEngine {
        let engine = IrisEngine(state: app, client: client, retryDelays: [], protectionEnabled: false, sessionPeerCount: 0)
        app.installEngine(engine)
        return engine
    }

    private func lastSystemLine(_ app: AppState, _ id: UUID) -> String {
        app.conversations.first { $0.id == id }?.messages.last?.content ?? ""
    }

    // MARK: Tier

    @Test("/model sets this conversation's tier for its next turn, and no other's (#667)")
    func modelSetsConversationTier() async throws {
        let (app, root) = try setUp("---\nrole: reviewer\n---\nYou review."); defer { try? FileManager.default.removeItem(at: root) }
        let one = app.createNewConversation(select: true)
        let other = app.createNewConversation(select: false)
        app.selectedConversationId = one
        let client = Recorder()
        let engine = engine(app, client)
        app.sendMessage("/model hard")
        #expect(app.conversations.first { $0.id == one }?.modelTier == .hard)
        #expect(lastSystemLine(app, one).contains(ConfigManager.shared.getModel(for: .hard)), "the reply names the model")
        await engine.processInput("hi", source: "UI", conversationId: one)
        await engine.processInput("hi", source: "UI", conversationId: other)
        #expect(client.calls.map(\.tier) == [.hard, .medium])
        app.sendMessage("/model default")
        #expect(app.conversations.first { $0.id == one }?.modelTier == nil)
        await engine.processInput("again", source: "UI", conversationId: one)
        #expect(client.calls.last?.tier == .medium)
    }

    @Test("a profile's tier applies with no /model, and /model wins over it")
    func profileTier() async throws {
        let (app, root) = try setUp("---\ntier: easy\n---\nYou review."); defer { try? FileManager.default.removeItem(at: root) }
        let id = app.createNewConversation(select: true, agentProfile: "reviewer")
        let client = Recorder()
        let engine = engine(app, client)
        #expect(app.effectiveTier(for: id) == (.easy, "from agent profile `reviewer`"))
        await engine.processInput("hi", source: "UI", conversationId: id)
        app.sendMessage("/model hard")
        await engine.processInput("hi", source: "UI", conversationId: id)
        #expect(client.calls.map(\.tier) == [.easy, .hard])
        #expect(app.effectiveTier(for: id) == (.hard, "set by /model"))
    }

    @Test("a subagent's turn, started inside a parent's, runs on its own engine's tier")
    func subagentKeepsItsTier() async throws {
        let (app, root) = try setUp("---\ntier: hard\n---\nYou review."); defer { try? FileManager.default.removeItem(at: root) }
        let child = app.createNewConversation(isSubagent: true, select: false)
        let client = Recorder()
        let sub = IrisEngine(state: app, tier: .easy, principal: .subagent, roleLabel: "helper", client: client,
                             retryDelays: [], protectionEnabled: false, sessionPeerCount: 0)
        await IrisEngine.$turnTier.withValue(.hard) {
            await sub.processInput("go", source: "System", conversationId: child)
        }
        #expect(client.calls.first?.tier == .easy)
    }

    @Test("the tier persists with the conversation; a row from before #667 has none; a bad one drops only itself")
    func tierPersists() throws {
        let store = try ConversationStore.inMemory()
        let first = AppState(store: store, createIfEmpty: false, emitLaunchNotices: false)
        let id = first.createNewConversation(select: false)
        let idx = try #require(first.conversations.firstIndex { $0.id == id })
        first.conversations[idx].modelTier = .hard
        first.markChanged(id, .metadata)
        first.flushSave()
        let again = AppState(store: store, createIfEmpty: false, emitLaunchNotices: false)
        #expect(again.conversations.first { $0.id == id }?.modelTier == .hard)
        let legacy = #"{"id":"\#(UUID().uuidString)","title":"t","messages":[]}"#
        #expect(try JSONDecoder().decode(Conversation.self, from: Data(legacy.utf8)).modelTier == nil)
        let bad = #"{"id":"\#(UUID().uuidString)","title":"t","messages":[],"modelTier":"huge"}"#
        let kept = try JSONDecoder().decode(Conversation.self, from: Data(bad.utf8))
        #expect(kept.modelTier == nil && kept.title == "t")
    }

    @Test("PRI's details name this conversation's model and where its tier came from")
    func ledNamesConversationTier() {
        let suite = "iris-465c-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer {
            defaults.removePersistentDomain(forName: suite)
            IrisDefaults.removeSuiteFile(named: suite, in: IrisDefaults.preferencesDirectory)
        }
        let config = ConfigManager(store: defaults)
        config.primaryProvider = LLMProvider.anthropic.rawValue
        config.anthropicModelHard = "hard-one"
        let facts = ModelLEDBar(config: config, conversationTier: (.hard, "set by /model")).primaryModelFacts()
        #expect(facts.contains(.init(label: "This conversation", value: "hard-one (hard, set by /model)")))
        #expect(!ModelLEDBar(config: config).primaryModelFacts().contains { $0.label == "This conversation" })
    }

    // MARK: Skills

    @Test("an invalidation rebuilds a profile's base too, so it never keeps a stale SOUL or skills list")
    func profileBaseRebuilt() async throws {
        let (app, root) = try setUp("---\nskills: [code-review]\n---\nYou review."); defer { try? FileManager.default.removeItem(at: root) }
        let paths = IrisPaths(root: root)
        try FileManager.default.createDirectory(at: paths.memoryDir, withIntermediateDirectories: true)
        try Data("SOUL-ONE".utf8).write(to: paths.soulMd)
        let id = app.createNewConversation(select: false, agentProfile: "reviewer")
        let client = Recorder()
        let engine = IrisEngine(state: app, client: client, retryDelays: [], protectionEnabled: false,
                                sessionPeerCount: 0, memory: MemoryManager(paths: paths))
        await engine.processInput("hi", source: "UI", conversationId: id)
        try Data("SOUL-TWO".utf8).write(to: paths.soulMd)
        await engine.processInput("hi", source: "UI", conversationId: id)
        await engine.invalidateSystemPrompt()
        await engine.processInput("hi", source: "UI", conversationId: id)
        let prompts = client.calls.map(\.system)
        #expect(prompts[0].contains("SOUL-ONE") && prompts[1].contains("SOUL-ONE"), "cached until invalidated")
        #expect(prompts[2].contains("SOUL-TWO"), "the invalidation reached the profile's base")
    }

    @Test("a profile's skills list replaces the global skills for its conversation, and survives a skill change")
    func profileSkills() async throws {
        let (app, root) = try setUp("---\nskills: [code-review]\n---\nYou review."); defer { try? FileManager.default.removeItem(at: root) }
        let profiled = app.createNewConversation(select: false, agentProfile: "reviewer")
        let plain = app.createNewConversation(select: false)
        let client = Recorder()
        let engine = engine(app, client)
        await engine.processInput("hi", source: "UI", conversationId: profiled)
        await engine.processInput("hi", source: "UI", conversationId: plain)
        await engine.invalidateSystemPrompt()   // what a skill write does
        await engine.processInput("again", source: "UI", conversationId: profiled)
        let prompts = client.calls.map(\.system)
        #expect(prompts[0].contains("# Available Skills (Active Bundle: agent profile)"))
        #expect(!prompts[1].contains("Active Bundle: agent profile"), "a plain conversation keeps the global skills")
        #expect(prompts[2].contains("# Available Skills (Active Bundle: agent profile)"))
    }
}
