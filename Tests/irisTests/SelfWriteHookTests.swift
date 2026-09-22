import Testing
import Foundation
@testable import iris

/// The choke point that feeds `RecentWrites` (#187 deliverable 4, spec §4, ruling R-D4-1): the
/// tool dispatcher records what a tool wrote, and only when the conversation it ran in was
/// unattended. An attended write is a human-driven action a watch is expected to notice, so it is
/// deliberately not remembered.
///
/// Every test injects its own registry and writes into a temp directory of its own (invariant 7):
/// `RecentWrites.shared` is never reached here, and nothing lands in the machine's `~/.iris`.
@MainActor
@Suite("Unattended file-tool writes are recorded (#187)")
struct SelfWriteHookTests {

    // MARK: fixtures

    private func textResponse(_ text: String) -> GeminiResponse {
        GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [Part(text: text)]))],
                       usageMetadata: nil)
    }

    private func callResponse(_ name: String, _ args: [String: JSONValue]) -> GeminiResponse {
        GeminiResponse(candidates: [Candidate(content: Content(
            role: "model", parts: [Part(functionCall: FunctionCall(name: name, args: args))]))],
                       usageMetadata: nil)
    }

    private func tempDirectory(_ label: String) throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("iris-\(label)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// `JobAdmissionTests.harness(client:)`'s shape with the registry injected: an in-memory store,
    /// an `AppState` of this test's own, and an engine over both.
    private func harness(client: any LLMClientProtocol, recentWrites: RecentWrites)
        throws -> (ConversationStore, AppState, IrisEngine) {
        let store = try ConversationStore.inMemory()
        let state = AppState(store: store, tier2Provisioning: .provisioned, tier3Provisioning: .provisioned)
        state.conversations.removeAll()
        state.autoApproveTools = true
        let engine = IrisEngine(state: state, tier: .medium, client: client, retryDelays: [],
                                protectionEnabled: false, sessionPeerCount: 0,
                                recentWrites: recentWrites)
        return (store, state, engine)
    }

    /// The allowlist entry that lets an unattended `write_file` through. A background conversation
    /// fails closed on approval by design (#187), and the deterministic allowlist is the one door
    /// left open to it — so this is how a real mutating job writes, and the only way to drive the
    /// hook through the whole dispatcher. The rules live under a temp home, never the real one.
    private func permit(_ state: AppState, write path: String, home: URL) {
        let permissions = PermissionManager(paths: IrisPaths(root: home))
        permissions.allowGlobally(toolName: "write_file", details: path)
        state.permissions = permissions
    }

    /// One turn in `conversation` with the model writing `target`, and what the registry holds
    /// afterwards.
    private func write(into target: String, background: Bool, registry: RecentWrites) async throws {
        let home = try tempDirectory("selfwrite-home")
        defer { try? FileManager.default.removeItem(at: home) }
        let (_, state, engine) = try harness(client: FakeLLMClient(responses: [
            callResponse("write_file", ["path": .string(target), "content": .string("hello")]),
            textResponse("written."),
        ]), recentWrites: registry)
        let id = state.createNewConversation(isBackground: background, select: false)
        permit(state, write: target, home: home)

        await engine.processInput("go", source: background ? "job:test" : "UI", conversationId: id)
        #expect(FileManager.default.fileExists(atPath: target), "precondition: the tool actually ran")
    }

    // MARK: R-D4-1 — only unattended writes

    @Test("a background run's write is remembered, in its canonical spelling")
    func anUnattendedWriteIsRecorded() async throws {
        let dir = try tempDirectory("selfwrite-bg")
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appendingPathComponent("note.md").path
        let registry = RecentWrites()

        try await write(into: target, background: true, registry: registry)

        #expect(await registry.count == 1)
        #expect(await registry.isOwn(target, within: 5),
                "the temp directory is already the resolved spelling, so this is the canonical form")
        #expect(await registry.isOwn(dir.path, within: 5), "and the directory event the write produces")
    }

    @Test("the same write from the user's own conversation is not remembered (R-D4-1)")
    func anAttendedWriteIsNotRecorded() async throws {
        let dir = try tempDirectory("selfwrite-fg")
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appendingPathComponent("note.md").path
        let registry = RecentWrites()

        try await write(into: target, background: false, registry: registry)

        #expect(await registry.count == 0,
                "a watch is expected to notice the note the user just asked Iris to write")
    }

    // MARK: the skill tools, which name no path in their arguments

    /// Every sentence `writtenPaths` reads is pinned against the tool that produces it — a
    /// re-worded result and the recording move together, or this fails. Without that,
    /// `"Successfully updated skill '"` could be rewritten and two of the four filtered tools
    /// would quietly stop being recorded with the whole suite green, which is exactly the loop
    /// this deliverable exists to break.
    @Test("a skill write records both the folder and the file inside it")
    func skillWritesRecordFolderAndFile() async throws {
        let home = try tempDirectory("selfwrite-skills")
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = IrisPaths(root: home)
        try paths.ensureDirectories()
        let args: [String: JSONValue] = ["name": .string("Watch Notes"),
                                         "description": .string("d"), "body": .string("b")]
        // The real result sentence: the recompute reads the skill's name out of the arguments and
        // has to agree with what the tool actually created.
        let result = await ToolExecutor.shared.createSkill(name: "Watch Notes", description: "d",
                                                           body: "b", paths: paths)

        let written = IrisEngine.writtenPaths(tool: "create_skill", args: args, cwd: nil,
                                              result: result, paths: paths)
        let folder = paths.skillsDir.appendingPathComponent("watch-notes")
        #expect(written == [folder.path, folder.appendingPathComponent("SKILL.md").path])

        let registry = RecentWrites()
        for p in written { await registry.record(p) }
        #expect(await registry.count == 2)
        #expect(await registry.isOwn(folder.appendingPathComponent("SKILL.md").path, within: 5))

        // A result that did not say it succeeded records nothing.
        #expect(IrisEngine.writtenPaths(tool: "create_skill", args: args, cwd: nil,
                                        result: "Error saving skill 'watch-notes': disk full",
                                        paths: paths).isEmpty)

        // The other two sentences, from the tools that actually write them.
        let updated = await ToolExecutor.shared.updateSkill(name: "Watch Notes", description: "d2",
                                                            body: "b2", paths: paths)
        #expect(IrisEngine.writtenPaths(tool: "update_skill", args: args, cwd: nil,
                                        result: updated, paths: paths)
                == [folder.path, folder.appendingPathComponent("SKILL.md").path])

        let deleted = await ToolExecutor.shared.deleteSkill(name: "Watch Notes", paths: paths)
        #expect(IrisEngine.writtenPaths(tool: "delete_skill",
                                        args: ["name": .string("Watch Notes")], cwd: nil,
                                        result: deleted, paths: paths) == [folder.path])
        #expect(!FileManager.default.fileExists(atPath: folder.path),
                "precondition: the delete really happened, so its sentence is the real one")
    }

    // MARK: the pin

    @Test("every declared tool is classified as writing a path or not writing one")
    func everyDeclaredToolIsClassified() async {
        // Pinned against the live declarations, so a tool added later without a classification
        // fails this suite rather than quietly going unrecorded. MCP tools are excluded: they are
        // a user's servers, not a declaration in this repo, and §4 does not feed them. So are the
        // tools `buildRequest` declares inline (memory, identity, sessions, goals, delegation):
        // they return from `executeFunctionCall` directly and never reach the choke point at all,
        // so calling them "writes no path" would be a claim in the one direction that matters.
        let mcp = Set(await MCPManager.shared.getGeminiTools().map(\.name))
        let declared = Set(await ToolExecutor.shared.getTools(workspaceToolsEnabled: true).map(\.name))
            .subtracting(mcp)
            .union(IrisEngine.jobToolDeclarations(isPinned: true).map(\.name))

        #expect(declared.contains("write_file"), "precondition: the declarations were readable")
        // Both directions: a name left behind after its tool is deleted, or a typo in either set,
        // fails here too — not just a new tool nobody classified.
        #expect(IrisEngine.pathWritingTools.union(IrisEngine.toolsThatWriteNoPath) == declared)
        for name in declared {
            let writes = IrisEngine.pathWritingTools.contains(name)
            let doesNot = IrisEngine.toolsThatWriteNoPath.contains(name)
            #expect(writes != doesNot,
                    Comment(rawValue: "\(name) must be in exactly one of the two sets"))
        }
    }

    // MARK: the registry reaches what a run delegates into

    @Test("a subagent of an unattended run writes into the registry it was given")
    func subagentEngineSharesTheRegistry() async throws {
        let dir = try tempDirectory("selfwrite-subagent")
        defer { try? FileManager.default.removeItem(at: dir) }
        let home = try tempDirectory("selfwrite-subagent-home")
        defer { try? FileManager.default.removeItem(at: home) }
        let target = dir.appendingPathComponent("delegated.md").path
        let registry = RecentWrites()

        let app = AppState()
        app.conversations.removeAll()
        let parent = app.createNewConversation(isBackground: true, select: false)
        permit(app, write: target, home: home)
        let client = FakeLLMClient(responses: [
            callResponse("write_file", ["path": .string(target), "content": .string("delegated")]),
            callResponse("goal_complete", ["summary": .string("wrote it")]),
        ])

        _ = await SubagentManager.shared.runSubagent(
            role: "worker", task: "write the file", effort: "easy",
            parentConversationId: parent, client: client, appState: app,
            recentWrites: registry)

        #expect(FileManager.default.fileExists(atPath: target), "precondition: the subagent wrote it")
        #expect(await registry.count == 1,
                "the engine the manager builds must share the run's registry, not `.shared`")
        #expect(await registry.isOwn(target, within: 5))
    }
}
