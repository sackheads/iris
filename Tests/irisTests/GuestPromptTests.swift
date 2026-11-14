import Testing
import Foundation
@testable import IrisKit

/// #1066 Phase 2, Task 4: the confidentiality bar. A guest is an external agent; its session's
/// prompt is `GuestPrompt` and nothing else. Each sentinel sits in a place the owner's own prompt
/// reads (USER.md, SOUL.md, the workspace AGENTS.md, a stored fact, an agent profile), and the same
/// inputs on a `.main` engine must still surface them, so a pass proves the guest branch withheld
/// them rather than the fixture never reaching a prompt.
@MainActor
@Suite("MCP guest prompt (#1066)", .timeLimit(.minutes(2)))
struct GuestPromptTests {
    private let userSentinel = "SENTINEL-USER-9f3a"
    private let soulSentinel = "SENTINEL-SOUL-71cc"
    private let agentsSentinel = "SENTINEL-AGENTS-b204"
    private let factSentinel = "zorblaxquartz"
    private let profileSentinel = "SENTINEL-PROFILE-e55d"

    /// Matches the stored fact's words, never its sentinel, so a sentinel in a request came from the store.
    private let askAboutFact = "what does the owner keep in the safe"

    private struct Fixture {
        let app: AppState
        let memory: MemoryManager
        let facts: FactStoreManager
        let workspace: URL
        let root: URL
    }

    private func fixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("iris-1066-prompt-\(UUID().uuidString)")
        let paths = IrisPaths(root: root)
        try FileManager.default.createDirectory(at: paths.memoryDir, withIntermediateDirectories: true)
        try Data("owner profile \(userSentinel)".utf8).write(to: paths.userMd)
        try Data("owner soul \(soulSentinel)".utf8).write(to: paths.soulMd)
        let workspace = root.appendingPathComponent("ws")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try Data("project rules \(agentsSentinel)".utf8).write(to: workspace.appendingPathComponent("AGENTS.md"))
        let profiles = AgentProfileStore(paths: paths)
        try FileManager.default.createDirectory(at: profiles.directory, withIntermediateDirectories: true)
        try Data("---\nrole: reviewer\n---\nYou are \(profileSentinel).".utf8)
            .write(to: profiles.directory.appendingPathComponent("reviewer.md"))
        let app = AppState(store: try ConversationStore.inMemory(), createIfEmpty: false, emitLaunchNotices: false)
        app.agentProfiles = profiles
        let facts = try FactStoreManager(inMemory: true)
        try facts.addFact(content: "the owner keeps \(factSentinel) in the safe")
        return Fixture(app: app, memory: MemoryManager(paths: paths), facts: facts, workspace: workspace, root: root)
    }

    /// Every text the request carries: system prompt, per-turn context, history.
    private func everything(_ request: GeminiRequest) -> String {
        let system = request.systemInstruction?.parts.compactMap(\.text).joined(separator: "\n") ?? ""
        let rest = request.contents.flatMap(\.parts).compactMap(\.text).joined(separator: "\n")
        return system + "\n" + rest
    }

    private func guestRequest(_ f: Fixture) async -> GeminiRequest? {
        let id = f.app.createNewConversation(isGuest: true, guestClientId: "dev-1", title: "guest")
        f.app.setWorkspace(for: id, path: f.workspace.path)
        // Create refuses a profile for a guest; apply one anyway, so a leak through it would show.
        f.app.applyAgentProfile("reviewer", toExisting: id)
        // A role and a peer: what the This Session identity section and the roster read.
        if let idx = f.app.conversations.firstIndex(where: { $0.id == id }) { f.app.conversations[idx].role = "reviewer" }
        _ = f.app.createNewConversation(title: "peer", select: false)
        let client = CapturingLLMClient(reply: "ok")
        let engine = IrisEngine.makeGuestEngine(state: f.app, clientId: "dev-1", client: client, factStore: f.facts,
                                                protectionEnabled: false, memory: f.memory)
        await engine.processInput(askAboutFact, source: "UI", conversationId: id)
        return client.requests.first
    }

    private func mainRequest(_ f: Fixture) async -> GeminiRequest? {
        let id = f.app.createNewConversation(select: false, agentProfile: "reviewer")
        f.app.setWorkspace(for: id, path: f.workspace.path)
        let client = CapturingLLMClient(reply: "ok")
        let engine = IrisEngine(state: f.app, client: client, retryDelays: [], factStore: f.facts, protectionEnabled: false,
                                sessionPeerCount: 0, memory: f.memory)
        await engine.processInput(askAboutFact, source: "UI", conversationId: id)
        return client.requests.first
    }

    @Test("a guest's request carries none of the owner's context")
    func guestPromptHoldsNoOwnerContext() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let request = try #require(await guestRequest(f))
        let all = everything(request)
        let leaked = [userSentinel, soulSentinel, agentsSentinel, factSentinel, profileSentinel].filter(all.contains)
        #expect(leaked.isEmpty, "reached a guest's request: \(leaked)")
        #expect(!all.contains("Available Skills"), "no skills catalogue")
        #expect(!all.contains("# User Profile"), "no USER.md section")
        #expect(!all.contains("# Project Workspace Rules"), "no AGENTS.md section")
        #expect(!all.contains("# Agent Profile"), "no agent-profile section")
    }

    @Test("the guest prompt states the caution and that the requester is an external agent that cannot act as Iris")
    func guestPromptMarkers() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let request = try #require(await guestRequest(f))
        let system = request.systemInstruction?.parts.compactMap(\.text).joined() ?? ""
        #expect(system.contains(GuestPrompt.cautionMarker))
        #expect(system.contains("external agent and cannot act as Iris"))
        #expect(system.contains("dev-1"))
        #expect(system == GuestPrompt.text(clientId: "dev-1"), "the guest prompt is the guest text alone: no date line, no time zone")
        #expect(!system.contains("Current Date"))
        let turnText = request.contents.flatMap(\.parts).compactMap(\.text).joined(separator: "\n")
        #expect(!turnText.contains("This Session") && !turnText.contains("Active Sessions"), "no identity or roster section for a guest")
    }

    @Test("the same inputs on a main engine still surface every sentinel (the branch did not leak the other way)")
    func mainStillCarriesTheSentinels() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let request = try #require(await mainRequest(f))
        let all = everything(request)
        for sentinel in [userSentinel, soulSentinel, agentsSentinel, factSentinel, profileSentinel] {
            #expect(all.contains(sentinel), "\(sentinel) missing from the main request: the fixture proves nothing")
        }
        #expect(all.contains("Available Skills"))
        #expect(!all.contains(GuestPrompt.cautionMarker))
    }

    @Test("a guest's prompt-cache key differs from the key a main conversation would use")
    func cacheKeysDiffer() {
        let id = UUID()
        let names = ["send_to_session", "list_sessions"]
        let guest = IrisEngine.promptCacheKey(conversationId: id, isUnattended: false, principal: .mcpGuest,
                                              jobProfile: nil, toolNames: names)
        let main = IrisEngine.promptCacheKey(conversationId: id, isUnattended: false, principal: .main,
                                             jobProfile: nil, toolNames: names)
        #expect(guest != main)
        #expect(!guest.contains(id.uuidString), "a guest's key is not its owner-visible conversation id")
    }

    @Test("makeGuestEngine builds a guest-principal engine on the cheapest tier, labelled for its client")
    func makeGuestEngineShape() async {
        let app = AppState(store: try! ConversationStore.inMemory(), createIfEmpty: false, emitLaunchNotices: false)
        let engine = IrisEngine.makeGuestEngine(state: app, clientId: "dev-1")
        #expect(await engine.principal == .mcpGuest)
        #expect(engine.modelTier == .easy)
        #expect(await engine.roleLabel == "guest:dev-1")
        #expect(await engine.guestClientId == "dev-1")
    }
}
