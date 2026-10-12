import Testing
import Foundation
@testable import IrisKit

/// #489: a skill write tells the engine that made it, through `onSkillsChanged`, and never
/// `AppState.shared`. Inside `--run-job`, `.shared` built a second `AppState` over the store.
/// The no-`.shared` half is pinned in a process of its own by Task 8's exit test, where the trap
/// is armed.
@Suite("Skill writes invalidate their own engine (#489)", .timeLimit(.minutes(1)))
struct SkillInvalidationTests {
    private func tempHome() throws -> (IrisPaths, () -> Void) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("iris-489-\(UUID().uuidString)")
        let paths = IrisPaths(root: root)
        try paths.ensureDirectories()
        return (paths, { try? FileManager.default.removeItem(at: root) })
    }

    final class Count: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func bump() { lock.withLock { n += 1 } }
        var value: Int { lock.withLock { n } }
    }

    @Test("create, update and delete each call onSkillsChanged once")
    func crudCallsTheHook() async throws {
        let (paths, cleanup) = try tempHome(); defer { cleanup() }
        let count = Count()
        var executor = ToolExecutor()
        executor.onSkillsChanged = { count.bump() }
        let body = String(repeating: "A procedure step. ", count: 4)
        #expect(await executor.createSkill(name: "probe", description: "d", body: body, paths: paths).hasPrefix("Successfully"))
        #expect(await executor.updateSkill(name: "probe", description: "e", body: nil, paths: paths).hasPrefix("Successfully"))
        #expect(await executor.deleteSkill(name: "probe", paths: paths).hasPrefix("Successfully"))
        #expect(count.value == 3)
    }

    @Test("write_file onto a skill's SKILL.md calls onSkillsChanged once, through execute")
    func writeFileOntoASkillCallsTheHook() async throws {
        let (paths, cleanup) = try tempHome(); defer { cleanup() }
        let count = Count()
        var executor = ToolExecutor()
        executor.irisPaths = paths   // the temp home, never the process's test home
        executor.onSkillsChanged = { count.bump() }
        let file = paths.skillsDir.appendingPathComponent("probe/SKILL.md")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let body = String(repeating: "A procedure step. ", count: 4)
        let result = await executor.execute(name: "write_file", args: [
            "path": .string(file.path), "content": .string("---\nname: probe\ndescription: d\n---\n\(body)"),
        ])
        #expect(result.hasPrefix("Successfully wrote to"))
        #expect(count.value == 1)
        let elsewhere = paths.root.appendingPathComponent("notes.txt")
        _ = await executor.execute(name: "write_file", args: ["path": .string(elsewhere.path), "content": .string("x")])
        #expect(count.value == 1, "a file outside the skills tree is not a skill write")
    }

    @Test("an executor with no hook writes skills and invalidates nothing")
    func noHookIsANoOp() async throws {
        let (paths, cleanup) = try tempHome(); defer { cleanup() }
        let body = String(repeating: "A procedure step. ", count: 4)
        #expect(await ToolExecutor().createSkill(name: "probe", description: "d", body: body, paths: paths).hasPrefix("Successfully"))
    }

    @Test("the curator calls onSkillsChanged when it prunes, and not otherwise")
    func curatorCallsTheHookOnPrune() async throws {
        let (paths, cleanup) = try tempHome(); defer { cleanup() }
        let count = Count()
        _ = await SkillCurator.shared.curateSkills(paths: paths, onSkillsChanged: { count.bump() })
        #expect(count.value == 0, "nothing to prune")
        try FileManager.default.createDirectory(at: paths.skillsDir.appendingPathComponent("empty"), withIntermediateDirectories: true)
        _ = await SkillCurator.shared.curateSkills(paths: paths, onSkillsChanged: { count.bump() })
        #expect(count.value == 1)
    }

    @MainActor
    @Test("plan note 14: a delegate engine's skill write invalidates the owner's main engine too")
    func delegateWriteInvalidatesTheOwner() async throws {
        let (paths, cleanup) = try tempHome(); defer { cleanup() }
        let state = AppState(store: try ConversationStore.inMemory(), createIfEmpty: false, emitLaunchNotices: false)
        let main: IrisEngine = state.engine
        // A delegate over the same state, built the way `SubagentManager` builds one.
        let delegate = IrisEngine(state: state, client: FakeLLMClient(responses: []), protectionEnabled: false)
        await main.setSystemPrompt(text: "main, primed")
        await delegate.setSystemPrompt(text: "delegate, primed")
        let executor = await delegate.executor
        let body = String(repeating: "A procedure step. ", count: 4)
        #expect(await executor.createSkill(name: "probe", description: "d", body: body, paths: paths).hasPrefix("Successfully"))
        #expect(await delegate.systemPrompt == nil)
        #expect(await main.systemPrompt == nil, "the main chat sees the delegate's skill on its next turn, not after a restart")
    }

    @MainActor
    @Test("an engine's executor invalidates that engine's prompt")
    func engineExecutorInvalidatesItsOwnEngine() async throws {
        let (paths, cleanup) = try tempHome(); defer { cleanup() }
        let state = AppState(store: try ConversationStore.inMemory(), createIfEmpty: false, emitLaunchNotices: false)
        let engine: IrisEngine = state.engine
        await engine.setSystemPrompt(text: "primed")
        let executor = await engine.executor
        let body = String(repeating: "A procedure step. ", count: 4)
        #expect(await executor.createSkill(name: "probe", description: "d", body: body, paths: paths).hasPrefix("Successfully"))
        #expect(await engine.systemPrompt == nil)
    }
}
