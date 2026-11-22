import Testing
import Foundation
@testable import IrisKit

/// #1268 (Brian: "a"): when the guard shows the model an altered USER.md or workspace AGENTS.md, the
/// person gets one plain line in the chat, once per change of the file, not once per turn. Driven
/// through real `.main` engine turns and read off the conversation's own messages.
@MainActor
@Suite("the person is told once per change when the model saw a cleaned file (#1268)", .serialized, .timeLimit(.minutes(2)))
struct OwnerAlteredFileNoticeTests {
    private struct Fixture {
        let root: URL
        let paths: IrisPaths
        let workspace: URL
        let app: AppState
        let engine: IrisEngine
        let conversation: UUID
        func turn() async { await engine.processInput("hi", source: "UI", conversationId: conversation) }
        @MainActor func notices(_ file: String) -> [String] {
            (app.conversations.first { $0.id == conversation }?.messages ?? [])
                .filter { $0.role == .system && $0.content.hasPrefix("The injection guard ") && $0.content.contains(file) }
                .map(\.content)
        }
        func tearDown() { try? FileManager.default.removeItem(at: root) }
    }

    private func fixture(user: String, agents: String) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("iris-1268-\(UUID().uuidString)")
        let paths = IrisPaths(root: root)
        try FileManager.default.createDirectory(at: paths.memoryDir, withIntermediateDirectories: true)
        try user.write(to: paths.userMd, atomically: true, encoding: .utf8)
        let workspace = root.appendingPathComponent("ws")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try agents.write(to: workspace.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)
        let app = AppState(store: try ConversationStore.inMemory(), createIfEmpty: false, emitLaunchNotices: false)
        let conversation = app.createNewConversation(select: false)
        app.setWorkspace(for: conversation, path: workspace.path)
        let engine = IrisEngine(state: app, client: CapturingLLMClient(reply: "ok"), retryDelays: [], protectionEnabled: false,
                                sessionPeerCount: 0, memory: MemoryManager(paths: paths))
        return Fixture(root: root, paths: paths, workspace: workspace, app: app, engine: engine, conversation: conversation)
    }

    /// Rewrites `url` with a modification date a few seconds on, so the stamp changes even within one second.
    private func rewrite(_ url: URL, _ text: String, ahead seconds: TimeInterval) throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(seconds)], ofItemAtPath: url.path)
    }

    @Test("a marker stripped from USER.md: one line for two turns, a new one after the file changes")
    func userProfileOncePerChange() async throws {
        let f = try fixture(user: "model: gpt-x\nlikes tea", agents: "use tabs"); defer { f.tearDown() }
        await f.turn()
        await f.turn()
        #expect(f.notices("USER.md") == [IrisEngine.alteredFileNotice(file: "USER.md", stripped: true)], "once for an unchanged file")
        try rewrite(f.paths.userMd, "model: gpt-y\nlikes coffee", ahead: 5)
        await f.turn()
        #expect(f.notices("USER.md").count == 2, "the changed file is announced again")
        #expect(f.notices("AGENTS.md").isEmpty, "a clean file is never announced")
    }

    @Test("a marker stripped from the workspace AGENTS.md names that file")
    func workspaceRules() async throws {
        let f = try fixture(user: "likes tea", agents: "model: gpt-x\nuse tabs"); defer { f.tearDown() }
        await f.turn()
        await f.turn()
        let notices = f.notices("AGENTS.md")
        #expect(notices.count == 1, "\(notices)")
        let path = (f.workspace.appendingPathComponent("AGENTS.md").path as NSString).abbreviatingWithTildeInPath
        #expect(notices.first == IrisEngine.alteredFileNotice(file: path, stripped: true))
        #expect(f.notices("USER.md").isEmpty)
    }

    @Test("clean files: no line")
    func cleanFilesSayNothing() async throws {
        let f = try fixture(user: "likes tea", agents: "use tabs"); defer { f.tearDown() }
        await f.turn()
        #expect(f.notices("").isEmpty)
    }

    @Test("the line says which file, and that the model saw a cleaned version")
    func wording() {
        let stripped = IrisEngine.alteredFileNotice(file: "USER.md", stripped: true)
        #expect(stripped.contains("USER.md") && stripped.contains("cleaned version") && stripped.contains("unchanged"))
        #expect(!stripped.contains("\n"), "one line")
        #expect(IrisEngine.alteredFileNotice(file: "USER.md", stripped: false).contains("changed how some lines look"))
    }
}
