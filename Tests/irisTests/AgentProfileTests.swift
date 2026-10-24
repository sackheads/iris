import Foundation
import Testing
@testable import IrisKit

/// #465: agent profiles. Files are written to a temp home of the test's own (Invariant 7).
@MainActor
@Suite("Agent profiles (#465)", .timeLimit(.minutes(1)))
struct AgentProfileTests {
    nonisolated private static let reviewer = """
    ---
    role: reviewer
    tier: hard
    skills: [code-review, swift-testing]
    tools:
      - read_file
      - run_command
    ---
    You review pull requests. Lead with what is wrong.
    """

    private func home() throws -> (IrisPaths, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("iris-465-\(UUID().uuidString)")
        let paths = IrisPaths(root: root)
        try FileManager.default.createDirectory(at: AgentProfileStore(paths: paths).directory, withIntermediateDirectories: true)
        return (paths, root)
    }

    private func write(_ text: String, as name: String, in paths: IrisPaths) throws {
        try Data(text.utf8).write(to: AgentProfileStore(paths: paths).directory.appendingPathComponent(name + ".md"))
    }

    private func app(_ paths: IrisPaths, store: ConversationStore? = nil) throws -> AppState {
        let app = AppState(store: try store ?? ConversationStore.inMemory(), createIfEmpty: false, emitLaunchNotices: false)
        app.agentProfiles = AgentProfileStore(paths: paths)
        return app
    }

    private func notes(_ app: AppState, _ id: UUID) -> [String] {
        app.conversations.first { $0.id == id }?.messages.filter { $0.role == .system }.map(\.content)
            .filter { $0.hasPrefix("[agent profile]") } ?? []
    }

    // MARK: The file

    @Test("a profile file parses: role, tier, inline and block lists, the body, and a content hash")
    nonisolated func parses() throws {
        let profile = try AgentProfileStore.parse(name: "reviewer", data: Data(Self.reviewer.utf8)).get()
        #expect(profile.role == "reviewer")
        #expect(profile.tier == .hard)
        #expect(profile.skills == ["code-review", "swift-testing"])
        #expect(profile.tools == ["read_file", "run_command"])
        #expect(profile.prompt == "You review pull requests. Lead with what is wrong.")
        #expect(profile.contentHash.count == 64)
        let edited = try AgentProfileStore.parse(name: "reviewer", data: Data((Self.reviewer + " Be brief.").utf8)).get()
        #expect(edited.contentHash != profile.contentHash)
    }

    @Test("a file that does not parse says why")
    nonisolated func refusals() {
        func why(_ text: String, _ name: String = "x") -> String? {
            if case .failure(let e) = AgentProfileStore.parse(name: name, data: Data(text.utf8)) { return e.message }
            return nil
        }
        #expect(why("---\nname: other\n---\nhi")?.contains("file is x.md") == true)
        #expect(why("---\ntier: huge\n---\nhi")?.contains("easy, medium or hard") == true)
        #expect(why("---\nrole: Not A Role\n---\nhi")?.contains("role must be") == true)
        #expect(why("---\ntools: read_file\n---\nhi")?.contains("tools must be a list") == true)
        #expect(why("---\nrole: x\n---\n")?.contains("no text") == true)
    }

    @Test("the store lists usable and unusable profiles, and a missing one reads as missing")
    func storeLists() throws {
        let (paths, root) = try home(); defer { try? FileManager.default.removeItem(at: root) }
        try write(Self.reviewer, as: "reviewer", in: paths)
        try write("---\ntier: huge\n---\nhi", as: "broken", in: paths)
        let store = AgentProfileStore(paths: paths)
        let list = store.list()
        #expect(list.map(\.name) == ["broken", "reviewer"])
        guard case .unreadable = list[0].load, case .loaded = list[1].load else { Issue.record("\(list)"); return }
        #expect(store.load("gone") == .missing)
    }

    @Test("the examples are written once, and one the person deletes stays deleted")
    nonisolated func examplesOnce() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("iris-465-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = IrisPaths(root: root)
        AgentProfileStore.seedExamplesIfNeeded(paths)
        let store = AgentProfileStore(paths: paths)
        #expect(store.list().count == AgentProfileStore.examples.count)
        for entry in store.list() { if case .loaded = entry.load {} else { Issue.record("example \(entry.name) does not parse") } }
        try FileManager.default.removeItem(at: store.directory.appendingPathComponent("writer.md"))
        AgentProfileStore.seedExamplesIfNeeded(paths)
        #expect(store.load("writer") == .missing)
    }

    // MARK: A conversation and its profile

    @Test("a conversation started on a profile links it, keeps its first read, and takes its role")
    func createsWithProfile() throws {
        let (paths, root) = try home(); defer { try? FileManager.default.removeItem(at: root) }
        try write(Self.reviewer, as: "reviewer", in: paths)
        let app = try app(paths)
        let id = app.createNewConversation(select: false, agentProfile: "reviewer")
        let conv = try #require(app.conversations.first { $0.id == id })
        #expect(conv.agentProfile == "reviewer")
        #expect(conv.agentProfileSnapshot?.prompt.hasPrefix("You review") == true)
        #expect(conv.role == "reviewer")
    }

    @Test("a role another session holds is not taken: no role, and the notice names the holder")
    func roleHeldElsewhere() throws {
        let (paths, root) = try home(); defer { try? FileManager.default.removeItem(at: root) }
        try write(Self.reviewer, as: "reviewer", in: paths)
        let app = try app(paths)
        let first = app.createNewConversation(select: false, agentProfile: "reviewer")
        let second = app.createNewConversation(select: false, agentProfile: "reviewer")
        #expect(app.conversations.first { $0.id == first }?.role == "reviewer", "the holder keeps it")
        #expect(app.conversations.first { $0.id == second }?.role == nil)
        #expect(notes(app, second).contains { $0.contains("held by") })
    }

    @Test("the pinned Iris conversation never runs on a profile, even with one stored")
    func pinnedNever() throws {
        let (paths, root) = try home(); defer { try? FileManager.default.removeItem(at: root) }
        try write(Self.reviewer, as: "reviewer", in: paths)
        let app = try app(paths)
        let id = app.createNewConversation(select: false)
        let idx = try #require(app.conversations.firstIndex { $0.id == id })
        app.conversations[idx].isPinned = true
        app.conversations[idx].agentProfile = "reviewer"
        #expect(app.resolveAgentProfile(for: id) == nil)
    }

    @Test("an edited file is used on the next turn, its copy refreshed, and the change said once")
    func editedFile() throws {
        let (paths, root) = try home(); defer { try? FileManager.default.removeItem(at: root) }
        try write(Self.reviewer, as: "reviewer", in: paths)
        let app = try app(paths)
        let id = app.createNewConversation(select: false, agentProfile: "reviewer")
        #expect(app.resolveAgentProfile(for: id)?.prompt.hasSuffix("wrong.") == true)
        try write(Self.reviewer + " Be brief.", as: "reviewer", in: paths)
        #expect(app.resolveAgentProfile(for: id)?.prompt.hasSuffix("Be brief.") == true)
        #expect(app.conversations.first { $0.id == id }?.agentProfileSnapshot?.prompt.hasSuffix("Be brief.") == true)
        _ = app.resolveAgentProfile(for: id)
        #expect(notes(app, id).filter { $0.contains("changed") }.count == 1)
    }

    @Test("a file edited while Iris was closed is said on the first turn after the launch")
    func editedWhileClosed() throws {
        let (paths, root) = try home(); defer { try? FileManager.default.removeItem(at: root) }
        try write(Self.reviewer, as: "reviewer", in: paths)
        let store = try ConversationStore.inMemory()
        let before = try app(paths, store: store)
        let id = before.createNewConversation(select: false, agentProfile: "reviewer")
        before.flushSave()
        try write(Self.reviewer + " Be brief.", as: "reviewer", in: paths)
        let after = try app(paths, store: store)   // a fresh launch: nothing seen yet this run
        #expect(after.resolveAgentProfile(for: id)?.prompt.hasSuffix("Be brief.") == true)
        #expect(notes(after, id).contains { $0.contains("changed") })
    }

    @Test("a deleted or broken file falls back to the last good read, said once, never widening")
    func lastKnownGood() throws {
        let (paths, root) = try home(); defer { try? FileManager.default.removeItem(at: root) }
        try write(Self.reviewer, as: "reviewer", in: paths)
        let app = try app(paths)
        let id = app.createNewConversation(select: false, agentProfile: "reviewer")
        try write("---\ntools: read_file\n---\nhi", as: "reviewer", in: paths)
        let broken = app.resolveAgentProfile(for: id)
        #expect(broken?.tools == ["read_file", "run_command"], "the last good read, not the defaults")
        #expect(!app.agentProfileFileReads(id))
        try FileManager.default.removeItem(at: AgentProfileStore(paths: paths).directory.appendingPathComponent("reviewer.md"))
        #expect(app.resolveAgentProfile(for: id)?.prompt.hasPrefix("You review") == true)
        _ = app.resolveAgentProfile(for: id)
        let said = notes(app, id).filter { $0.contains("last version it read") }
        #expect(said.count == 2, "once when it broke, once when it went: \(said)")
        #expect(said.first?.contains("tools must be a list") == true, "the notice names the parse error")
    }

    @Test("Clear Agent Profile drops the link and the copy, and the chat runs without a profile")
    func clears() throws {
        let (paths, root) = try home(); defer { try? FileManager.default.removeItem(at: root) }
        try write(Self.reviewer, as: "reviewer", in: paths)
        let app = try app(paths)
        let id = app.createNewConversation(select: false, agentProfile: "reviewer")
        app.clearAgentProfile(for: id)
        let conv = try #require(app.conversations.first { $0.id == id })
        #expect(conv.agentProfile == nil && conv.agentProfileSnapshot == nil)
        #expect(app.resolveAgentProfile(for: id) == nil)
    }

    @Test("the link and the copy persist; a row from before #465 reads as none; a bad copy drops only itself")
    func persists() throws {
        let (paths, root) = try home(); defer { try? FileManager.default.removeItem(at: root) }
        try write(Self.reviewer, as: "reviewer", in: paths)
        let store = try ConversationStore.inMemory()
        let first = try app(paths, store: store)
        let id = first.createNewConversation(select: false, agentProfile: "reviewer")
        first.flushSave()
        let again = try app(paths, store: store)
        let conv = try #require(again.conversations.first { $0.id == id })
        #expect(conv.agentProfile == "reviewer")
        #expect(conv.agentProfileSnapshot == first.conversations.first { $0.id == id }?.agentProfileSnapshot)
        let legacy = #"{"id":"\#(UUID().uuidString)","title":"t","messages":[]}"#
        let decoded = try JSONDecoder().decode(Conversation.self, from: Data(legacy.utf8))
        #expect(decoded.agentProfile == nil && decoded.agentProfileSnapshot == nil)
        let badCopy = #"{"id":"\#(UUID().uuidString)","title":"t","messages":[],"agentProfile":"reviewer","agentProfileSnapshot":{"oops":1}}"#
        let kept = try JSONDecoder().decode(Conversation.self, from: Data(badCopy.utf8))
        #expect(kept.agentProfile == "reviewer" && kept.agentProfileSnapshot == nil)
    }

    // MARK: The prompt

    private final class Recorder: LLMClientProtocol, @unchecked Sendable {
        private let lock = NSLock()
        private var seen: [String] = []
        var systemPrompts: [String] { lock.withLock { seen } }
        func generateContent(request: GeminiRequest, tier: ModelTier) async throws -> GeminiResponse {
            lock.withLock { seen.append(request.systemInstruction?.parts.compactMap(\.text).joined() ?? "") }
            return GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [Part(text: "ok")]))], usageMetadata: nil)
        }
    }

    @Test("a profiled conversation sends its profile's text, and keeps it after a skill change")
    func promptLayer() async throws {
        let (paths, root) = try home(); defer { try? FileManager.default.removeItem(at: root) }
        try write(Self.reviewer, as: "reviewer", in: paths)
        let app = try app(paths)
        let profiled = app.createNewConversation(select: false, agentProfile: "reviewer")
        let plain = app.createNewConversation(select: false)
        let client = Recorder()
        let engine = IrisEngine(state: app, client: client, retryDelays: [], protectionEnabled: false, sessionPeerCount: 0)
        await engine.processInput("hi", source: "UI", conversationId: profiled)
        await engine.processInput("hi", source: "UI", conversationId: plain)
        await engine.invalidateSystemPrompt()   // what a skill write does
        await engine.processInput("again", source: "UI", conversationId: profiled)
        let prompts = client.systemPrompts
        #expect(prompts.count == 3)
        #expect(prompts[0].contains("# Agent Profile: reviewer\nYou review pull requests."))
        #expect(!prompts[1].contains("# Agent Profile"), "a conversation without a profile is unchanged")
        #expect(prompts[2].contains("# Agent Profile: reviewer"), "a skill change keeps the profile layer")
    }

    @Test("an engine given its own base prompt keeps it when the prompt is invalidated (#668)")
    func customBaseSurvives() async throws {
        let (paths, root) = try home(); defer { try? FileManager.default.removeItem(at: root) }
        let app = try app(paths)
        let id = app.createNewConversation(isSubagent: true, select: false)
        let client = Recorder()
        let engine = IrisEngine(state: app, principal: .subagent, roleLabel: "code_reviewer", client: client,
                                retryDelays: [], protectionEnabled: false, sessionPeerCount: 0)
        await engine.setSystemPrompt(text: "ROLE: careful code reviewer.")
        await engine.invalidateSystemPrompt()   // what a subagent's own skill write does
        await engine.processInput("go", source: "System", conversationId: id)
        let prompt = try #require(client.systemPrompts.first)
        #expect(prompt.hasPrefix("ROLE: careful code reviewer."), "the role prompt, not the default: \(prompt.prefix(80))")
    }
}

/// #642: a source scan, in a suite of its own that isn't `@MainActor`. In the suite above,
/// `nonisolated` didn't move it: Swift Testing ran the case on the main thread, and a scan held
/// main for a quarter second of a parallel run's start, where every `@MainActor` suite waits on it.
@Suite("Agent profiles (#465): source scan")
struct AgentProfileSourceScanTests {
    @Test("only the UI starts a conversation on a profile or clears one: no tool, job or event reaches either")
    func onlyTheUI() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/IrisKit")
        var starters: Set<String> = [], clearers: Set<String> = []
        for file in try FileManager.default.contentsOfDirectory(atPath: sources.path) where file.hasSuffix(".swift") {
            let text = try String(contentsOf: sources.appendingPathComponent(file), encoding: .utf8)
            for line in text.split(separator: "\n") {
                if line.contains("createNewConversation(") && line.contains("agentProfile:") { starters.insert(file) }
                if line.contains("clearAgentProfile(") && !line.contains("func clearAgentProfile") { clearers.insert(file) }
            }
        }
        #expect(starters == ["ChatView.swift"], "\(starters)")
        #expect(clearers == ["ChatView.swift"], "\(clearers)")
    }
}
