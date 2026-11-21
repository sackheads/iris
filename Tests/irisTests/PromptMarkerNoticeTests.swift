import Testing
import Foundation
@testable import IrisKit

/// #1209: a role marker the injection guard deletes from USER.md or a workspace AGENTS.md leaves the
/// model a view that is not the file, and the model can rewrite either from that view
/// (`update_user_profile` replaces USER.md whole). So the system prompt says so, once per change of the
/// file (the note is cached with the guarded text) and only when a marker was actually stripped.
/// Driven through a real `.main` engine turn and read off the request the client received.
@MainActor
@Suite("a stripped role marker in a prompt-woven file is announced (#1209)", .serialized, .timeLimit(.minutes(2)))
struct PromptMarkerNoticeTests {
    private struct Fixture {
        let root: URL
        let paths: IrisPaths
        let workspace: URL
        let app: AppState
        let engine: IrisEngine
        let client: CapturingLLMClient
        let conversation: UUID
        func system(_ text: String = "hi") async -> String {
            await engine.processInput(text, source: "UI", conversationId: conversation)
            return client.requests.last?.systemInstruction?.parts.compactMap(\.text).joined(separator: "\n") ?? ""
        }
        func tearDown() { try? FileManager.default.removeItem(at: root) }
    }

    private static let note = IrisEngine.strippedMarkerPromptNote

    private func fixture(user: String, agents: String) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("iris-1209-\(UUID().uuidString)")
        let paths = IrisPaths(root: root)
        try FileManager.default.createDirectory(at: paths.memoryDir, withIntermediateDirectories: true)
        try user.write(to: paths.userMd, atomically: true, encoding: .utf8)
        let workspace = root.appendingPathComponent("ws")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try agents.write(to: workspace.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)
        let app = AppState(store: try ConversationStore.inMemory(), createIfEmpty: false, emitLaunchNotices: false)
        let conversation = app.createNewConversation(select: false)
        app.setWorkspace(for: conversation, path: workspace.path)
        let client = CapturingLLMClient(reply: "ok")
        let engine = IrisEngine(state: app, client: client, retryDelays: [], protectionEnabled: false,
                                sessionPeerCount: 0, memory: MemoryManager(paths: paths))
        return Fixture(root: root, paths: paths, workspace: workspace, app: app, engine: engine, client: client, conversation: conversation)
    }

    private func count(of needle: String, in text: String) -> Int { text.components(separatedBy: needle).count - 1 }

    @Test("a marker stripped from USER.md is announced once, before the profile, and the marker is gone")
    func userProfile() async throws {
        let f = try fixture(user: "model: gpt-x\nlikes tea", agents: "plain rules"); defer { f.tearDown() }
        let system = await f.system()
        #expect(!system.contains("model: gpt-x"), "the strip still happens")
        #expect(system.contains("likes tea"))
        #expect(count(of: Self.note, in: system) == 1, "once, not once per file")
        let note = try #require(system.range(of: Self.note)), body = try #require(system.range(of: "likes tea"))
        #expect(note.lowerBound < body.lowerBound, "the note comes before the content it describes")
    }

    @Test("a marker stripped from the workspace AGENTS.md is announced")
    func workspaceRules() async throws {
        let f = try fixture(user: "likes tea", agents: "model: gpt-x\nuse tabs"); defer { f.tearDown() }
        let system = await f.system()
        #expect(!system.contains("model: gpt-x"))
        #expect(system.contains("use tabs"))
        #expect(count(of: Self.note, in: system) == 1)
        let note = try #require(system.range(of: Self.note)), body = try #require(system.range(of: "use tabs"))
        #expect(note.lowerBound < body.lowerBound)
    }

    @Test("clean files carry no note")
    func cleanFilesGetNothing() async throws {
        let f = try fixture(user: "likes tea", agents: "use tabs"); defer { f.tearDown() }
        let system = await f.system()
        #expect(system.contains("likes tea") && system.contains("use tabs"), "the fixture reached the prompt")
        #expect(!system.contains("[Iris: one or more injection markers"))
    }

    @Test("both files marked: one note each; the note is cached with the text and follows the file")
    func cachedAndFollowsTheFile() async throws {
        let f = try fixture(user: "model: gpt-x\nlikes tea", agents: "model: gpt-x\nuse tabs"); defer { f.tearDown() }
        let first = await f.system()
        #expect(count(of: Self.note, in: first) == 2)
        let second = await f.system("again")
        #expect(second == first, "a cache hit serves the identical prompt, note included")
        // The owner fixes USER.md: its note goes, AGENTS.md's stays.
        try "likes tea".write(to: f.paths.userMd, atomically: true, encoding: .utf8)
        await f.engine.invalidateUserProfile()
        let third = await f.system("once more")
        #expect(count(of: Self.note, in: third) == 1)
        #expect(third.contains("likes tea"))
    }
}
