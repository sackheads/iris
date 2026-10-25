import Foundation
import Testing
@testable import IrisKit

/// #670: the person applies an agent profile to a conversation that already exists, from its
/// sidebar menu. Files go in a temp home of the test's own (Invariant 7).
@MainActor
@Suite("Agent profiles applied to an existing conversation (#670)", .timeLimit(.minutes(1)))
struct AgentProfileApplyTests {
    nonisolated private static let reviewer = """
    ---
    role: reviewer
    tools: [read_file]
    ---
    You review pull requests.
    """

    nonisolated private static let writer = """
    ---
    role: writer
    ---
    You write documentation.
    """

    private func setUp() throws -> (AppState, AgentProfileStore, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("iris-670-\(UUID().uuidString)")
        let store = AgentProfileStore(paths: IrisPaths(root: root))
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        try write(Self.reviewer, as: "reviewer", in: store)
        try write(Self.writer, as: "writer", in: store)
        let app = AppState(store: try ConversationStore.inMemory(), createIfEmpty: false, emitLaunchNotices: false)
        app.agentProfiles = store
        return (app, store, root)
    }

    private func write(_ text: String, as name: String, in store: AgentProfileStore) throws {
        try Data(text.utf8).write(to: store.directory.appendingPathComponent(name + ".md"))
    }

    private func conv(_ app: AppState, _ id: UUID) throws -> Conversation {
        try #require(app.conversations.first { $0.id == id })
    }

    private func notes(_ app: AppState, _ id: UUID) -> [String] {
        app.conversations.first { $0.id == id }?.messages.filter { $0.role == .system }.map(\.content)
            .filter { $0.hasPrefix("[agent profile]") } ?? []
    }

    @Test("applied to a plain conversation: linked, its copy kept, its role taken, said once")
    func appliesToPlain() throws {
        let (app, _, root) = try setUp(); defer { try? FileManager.default.removeItem(at: root) }
        let id = app.createNewConversation(select: false)
        app.appendMessage(role: .user, content: "earlier turn", to: id)
        app.applyAgentProfile("reviewer", toExisting: id)
        let c = try conv(app, id)
        #expect(c.agentProfile == "reviewer")
        #expect(c.agentProfileSnapshot?.prompt == "You review pull requests.")
        #expect(c.role == "reviewer")
        #expect(c.messages.first?.content == "earlier turn", "the history stays as it is")
        #expect(notes(app, id) == ["[agent profile] `reviewer` applied; it takes effect from the next turn."])
        #expect(app.resolveAgentProfile(for: id)?.name == "reviewer")
        #expect(notes(app, id).count == 1, "the first turn after it says nothing more")
    }

    @Test("a change from one profile to another replaces it, names both, and keeps the first one's role")
    func changes() throws {
        let (app, _, root) = try setUp(); defer { try? FileManager.default.removeItem(at: root) }
        let id = app.createNewConversation(select: false, agentProfile: "reviewer")
        app.applyAgentProfile("writer", toExisting: id)
        let c = try conv(app, id)
        #expect(c.agentProfile == "writer")
        #expect(c.agentProfileSnapshot?.prompt == "You write documentation.")
        #expect(c.role == "reviewer", "roles are addresses: the one it had stays")
        #expect(notes(app, id).last == "[agent profile] `writer` replaced `reviewer`; it takes effect from the next turn. This conversation keeps its role `reviewer`; `/role` changes it.")
        #expect(app.resolveAgentProfile(for: id)?.name == "writer")
    }

    @Test("picking the profile it already has changes nothing and says nothing")
    func sameIsNoOp() throws {
        let (app, _, root) = try setUp(); defer { try? FileManager.default.removeItem(at: root) }
        let id = app.createNewConversation(select: false, agentProfile: "reviewer")
        let before = notes(app, id)
        app.applyAgentProfile("reviewer", toExisting: id)
        #expect(notes(app, id) == before)
    }

    @Test("a role set by /role is kept; with none the profile's applies; one held elsewhere is not taken")
    func roles() throws {
        let (app, _, root) = try setUp(); defer { try? FileManager.default.removeItem(at: root) }
        let kept = app.createNewConversation(select: false)
        let idx = try #require(app.conversations.firstIndex { $0.id == kept })
        app.conversations[idx].role = "lead"
        app.applyAgentProfile("writer", toExisting: kept)
        #expect(try conv(app, kept).role == "lead")
        #expect(notes(app, kept).last?.hasSuffix("keeps its role `lead`; `/role` changes it.") == true)

        let applied = app.createNewConversation(select: false)
        app.applyAgentProfile("writer", toExisting: applied)
        #expect(try conv(app, applied).role == "writer")

        let elsewhere = app.createNewConversation(select: false)
        app.applyAgentProfile("writer", toExisting: elsewhere)
        let c = try conv(app, elsewhere)
        #expect(c.agentProfile == "writer", "the profile still applies")
        #expect(c.role == nil, "the holder keeps the role")
        #expect(try conv(app, applied).role == "writer")
        #expect(notes(app, elsewhere).contains { $0.contains("held by") })
    }

    @Test("Iris, a subagent's thread and a job run are refused: nothing changes, nothing is said")
    func refused() throws {
        let (app, _, root) = try setUp(); defer { try? FileManager.default.removeItem(at: root) }
        let pinned = app.createNewConversation(select: false)
        let idx = try #require(app.conversations.firstIndex { $0.id == pinned })
        app.conversations[idx].isPinned = true
        let subagent = app.createNewConversation(isSubagent: true, select: false)
        let background = app.createNewConversation(isBackground: true, select: false)
        for id in [pinned, subagent, background] {
            app.applyAgentProfile("reviewer", toExisting: id)
            let c = try conv(app, id)
            #expect(c.agentProfile == nil && c.agentProfileSnapshot == nil && c.role == nil)
            #expect(notes(app, id).isEmpty)
        }
    }

    @Test("a profile that can't be read at apply time is refused with a notice, and nothing changes")
    func unreadable() throws {
        let (app, store, root) = try setUp(); defer { try? FileManager.default.removeItem(at: root) }
        try write("---\ntier: huge\n---\nhi", as: "broken", in: store)
        let plain = app.createNewConversation(select: false)
        app.applyAgentProfile("broken", toExisting: plain)
        #expect(try conv(app, plain).agentProfile == nil)
        #expect(try conv(app, plain).role == nil)
        #expect(notes(app, plain).last?.hasPrefix("[agent profile] `broken` couldn't be read (") == true)
        #expect(notes(app, plain).last?.hasSuffix("so nothing changed; this conversation keeps running without a profile.") == true)

        let profiled = app.createNewConversation(select: false, agentProfile: "reviewer")
        let snapshot = try conv(app, profiled).agentProfileSnapshot
        app.applyAgentProfile("gone", toExisting: profiled)
        let c = try conv(app, profiled)
        #expect(c.agentProfile == "reviewer" && c.agentProfileSnapshot == snapshot)
        #expect(notes(app, profiled).last == "[agent profile] `gone` isn't there, so nothing changed; this conversation keeps `reviewer`.")
        #expect(app.resolveAgentProfile(for: profiled)?.name == "reviewer")
    }

    /// One turn through a real engine; returns the declared names.
    private func declared(_ app: AppState, _ id: UUID, _ prompt: String, facts: FactStoreManager) async -> Set<String> {
        let client = CapturingLLMClient(reply: "ok")
        let engine = IrisEngine(state: app, client: client, retryDelays: [], factStore: facts,
                                protectionEnabled: false, sessionPeerCount: 0)
        await engine.processInput(prompt, source: "UI", conversationId: id)
        return Set(client.requests.first?.tools?.flatMap { $0.functionDeclarations.map(\.name) } ?? [])
    }

    @Test("a profile applied later hides a sticky tool, which comes back after Clear Agent Profile")
    func narrowsAgainstSticky() async throws {
        let (app, _, root) = try setUp(); defer { try? FileManager.default.removeItem(at: root) }
        let facts = try FactStoreManager(inMemory: true)
        try facts.addFact(content: "Brian lives in Seattle", entity: "Brian")
        let id = app.createNewConversation(select: false)
        #expect(await declared(app, id, "Where does Brian live?", facts: facts).contains("manage_fact"))
        #expect(app.stickyTools.names(for: id).contains("manage_fact"), "precondition: it is sticky now")

        app.applyAgentProfile("reviewer", toExisting: id)
        let narrowed = await declared(app, id, "What is two plus two?", facts: facts)
        #expect(!narrowed.contains("manage_fact"), "the profile wins over the sticky set")
        #expect(narrowed.contains("read_file"))

        app.clearAgentProfile(for: id)
        #expect(await declared(app, id, "What is two plus two?", facts: facts).contains("manage_fact"))
    }
}
