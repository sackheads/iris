import Testing
import Foundation
@testable import IrisKit

/// #647 (Brian's "b"): a BeforeTool hook runs before a gated call's approval, so Vibecop, the
/// allowlist and the person judge the arguments that will run, and nothing changes them after.
/// Each test has its own `AppState`, store, `PermissionManager` and hook config (Invariant 7).
@MainActor
@Suite("BeforeTool hooks run before the approval (#647)", .timeLimit(.minutes(1)))
struct HookOrderingTests {

    /// Answers ESCALATE, so the call reaches the person, and keeps what it was shown.
    private final class Recorder: AuxiliaryInferenceEngine, @unchecked Sendable {
        private let lock = NSLock()
        private var prompts: [String] = []
        var seen: [String] { lock.withLock { prompts } }
        func loadModel(config: AuxiliaryModelConfig) async throws {}
        func unloadModel() async {}
        func generate(prompt: String, jsonSchema: String?) async throws -> String {
            lock.withLock { prompts.append(prompt) }
            return #"{"decision":"ESCALATE","reason":"ask"}"#
        }
    }

    private struct Fixture {
        let root: URL
        var workspace: URL { root.appendingPathComponent("ws") }
        var marker: URL { root.appendingPathComponent("hook-ran") }
        func real(_ url: URL) -> String { IrisPaths.realPath(url.path) }
    }

    private func fixture() throws -> Fixture {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("iris-647-\(UUID().uuidString)")
        let f = Fixture(root: root)
        try FileManager.default.createDirectory(at: f.workspace, withIntermediateDirectories: true)
        return f
    }

    /// A BeforeTool hook for `tool` that marks that it ran, then prints `output` (a rewrite as JSON,
    /// or nothing) and exits with `status`.
    private func hooks(_ f: Fixture, tool: String, output: [String: String]?, status: Int32 = 0) throws -> HookManager {
        var command = "touch '\(f.marker.path)'"
        if let output {
            let json = String(data: try JSONSerialization.data(withJSONObject: output), encoding: .utf8)!
            command += "; printf '%s' '\(json)'"
        }
        command += "; exit \(status)"
        let config: [String: Any] = ["hooks": ["BeforeTool": [["matcher": tool, "hooks": [["type": "command", "command": command]]]]]]
        let url = f.root.appendingPathComponent("settings.json")
        try JSONSerialization.data(withJSONObject: config).write(to: url)
        var manager = HookManager()
        manager.configPathOverride = url.path
        return manager
    }

    private func call(_ name: String, _ args: [String: JSONValue]) -> GeminiResponse {
        GeminiResponse(candidates: [Candidate(content: Content(
            role: "model", parts: [Part(functionCall: FunctionCall(name: name, args: args))]))], usageMetadata: nil)
    }

    private func text(_ s: String) -> GeminiResponse {
        GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [Part(text: s)]))], usageMetadata: nil)
    }

    private func app(_ f: Fixture) throws -> AppState {
        let state = AppState(store: try ConversationStore.inMemory(),
                             tier2Provisioning: .provisioned, tier3Provisioning: .provisioned,
                             createIfEmpty: false, emitLaunchNotices: false)
        state.permissions = PermissionManager(paths: IrisPaths(root: f.root.appendingPathComponent("iris-home")))
        return state
    }

    struct Turn { var shown: String?; var asked: Bool; var result: String; var pill: ChatMessage? }

    /// One attended turn making `response`'s call, with Vibecop on as `engine`. A prompt is
    /// answered with `answer`.
    private func turn(_ state: AppState, _ response: GeminiResponse, hooks: HookManager, workspace: URL,
                      engine: Recorder, answer: AppState.ApprovalResolution) async throws -> Turn {
        state.vibecopEnabledOverride = true
        let iris = IrisEngine(state: state, tier: .medium, client: FakeLLMClient(responses: [response, text("done.")]),
                              retryDelays: [], protectionEnabled: false, sessionPeerCount: 0, hooks: hooks)
        let id = state.createNewConversation(isBackground: false, select: false)
        state.setWorkspace(for: id, path: workspace.path)
        let finished = Locked(false)
        let task = Task { @MainActor in
            await AuxiliaryModelManager.$scopedEngines.withValue(["vibecop": engine]) {
                await iris.processInput("go", source: "UI", conversationId: id)
            }
            finished.mutate { $0 = true }
        }
        var shown: String?
        for _ in 0..<1500 where !finished.value {
            if let request = state.pendingApprovals.first(where: { $0.conversationId == id }) {
                shown = request.details
                state.resolveApproval(id: request.id, answer)
                break
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        try await value(of: task)
        let conversation = state.conversations.first { $0.id == id }
        let result = conversation?.history.flatMap(\.parts).compactMap { part -> String? in
            guard case .string(let s)? = part.functionResponse?.response["result"] else { return nil }
            return s
        }.last ?? ""
        let pill = conversation?.messages.first { ToolCallParser.parse($0.content) != nil }
        return Turn(shown: shown, asked: shown != nil, result: result, pill: pill)
    }

    @Test("a rewritten command is what Vibecop and the dialog see, and exactly what runs")
    func rewrittenCommandIsJudgedAndRun() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let token = "rewritten-\(UUID().uuidString.prefix(8))"
        let hooks = try hooks(f, tool: "run_command", output: ["command": "echo \(token)"])
        let vibecop = Recorder()
        let t = try await turn(try app(f), call("run_command", ["command": .string("echo original")]),
                               hooks: hooks, workspace: f.workspace, engine: vibecop, answer: .approve)
        #expect(vibecop.seen.contains { $0.contains("echo \(token)") }, "Vibecop judged the rewritten command")
        #expect(!vibecop.seen.contains { $0.contains("echo original") })
        #expect(t.shown == "echo \(token)", "the person was shown what will run")
        #expect(t.result.contains(token), "and that is what ran: \(t.result)")
        #expect(t.pill?.approval?.layer == .person)
        #expect(t.pill?.approval?.line == "Your BeforeTool hook changed this call before it was approved; it ran: echo \(token)")
    }

    @Test("a denied call still fired its hook, and nothing ran")
    func deniedCallFiredItsHook() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let target = f.workspace.appendingPathComponent("never.txt")
        let hooks = try hooks(f, tool: "write_file", output: nil)
        let t = try await turn(try app(f), call("write_file", ["path": .string(target.path), "content": .string("x")]),
                               hooks: hooks, workspace: f.workspace, engine: Recorder(), answer: .deny)
        #expect(t.asked)
        #expect(FileManager.default.fileExists(atPath: f.marker.path), "the hook ran before the person answered")
        #expect(!FileManager.default.fileExists(atPath: target.path))
    }

    @Test("a hook's block ends the call before anyone is asked")
    func blockAsksNobody() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let hooks = try hooks(f, tool: "run_command", output: nil, status: 2)
        let vibecop = Recorder()
        let t = try await turn(try app(f), call("run_command", ["command": .string("echo hi")]),
                               hooks: hooks, workspace: f.workspace, engine: vibecop, answer: .approve)
        #expect(!t.asked, "no prompt")
        #expect(vibecop.seen.isEmpty, "and no Vibecop verdict")
        #expect(t.result.hasPrefix("System Hook blocked execution"), "\(t.result)")
    }

    @Test("a hook that rewrites the path gets the gate's decision on the new path")
    func rewrittenPathIsDecided() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let asked = f.workspace.appendingPathComponent("asked.txt")
        let moved = f.workspace.appendingPathComponent("moved.txt")
        let hooks = try hooks(f, tool: "write_file", output: ["path": moved.path])
        let state = try app(f)
        // Allowed on the new path only: if the gate judged the old one, the person would be asked.
        state.permissions.allowGlobally(toolName: "write_file", details: f.real(moved))
        let t = try await turn(state, call("write_file", ["path": .string(asked.path), "content": .string("x")]),
                               hooks: hooks, workspace: f.workspace, engine: Recorder(), answer: .deny)
        #expect(!t.asked, "the rule for the new path decided it")
        #expect(FileManager.default.fileExists(atPath: moved.path))
        #expect(!FileManager.default.fileExists(atPath: asked.path))
        #expect(t.pill?.approval?.layer == .allowlist)
    }

    @Test("in the pinned conversation, the watcher's dialog shows the path its hook rewrote")
    func watcherAskShowsRewrittenPath() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let asked = f.workspace.appendingPathComponent("asked")
        let moved = f.workspace.appendingPathComponent("moved")
        for dir in [asked, moved] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        let hooks = try hooks(f, tool: "register_directory_watcher", output: ["path": moved.path])
        let state = try app(f)
        state.vibecopEnabledOverride = false
        let iris = IrisEngine(state: state, tier: .medium,
                              client: FakeLLMClient(responses: [call("register_directory_watcher",
                                                                     ["path": .string(asked.path), "instructions": .string("look")]),
                                                                text("done.")]),
                              retryDelays: [], protectionEnabled: false, sessionPeerCount: 0, hooks: hooks)
        let id = state.createNewConversation(isBackground: false, select: false)
        let index = try #require(state.conversations.firstIndex { $0.id == id })
        state.conversations[index].isPinned = true
        let finished = Locked(false)
        let task = Task { @MainActor in
            await iris.processInput("go", source: "UI", conversationId: id)
            finished.mutate { $0 = true }
        }
        var shown: String?
        for _ in 0..<1500 where !finished.value {
            if let request = state.pendingApprovals.first(where: { $0.conversationId == id }) {
                shown = request.details
                state.resolveApproval(id: request.id, .deny)
                break
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        try await value(of: task)
        let detail = try #require(shown, "the pinned conversation asked")
        #expect(detail.contains(WatchRoot.canonical(moved.path) ?? moved.path), "\(detail)")
        #expect(!detail.contains("/asked"), "\(detail)")
    }

    @Test("a hook that makes a gated call's command something other than text cannot un-gate it: what is shown is what runs")
    func nonStringRewriteIsRefused() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let url = f.root.appendingPathComponent("settings.json")
        let command = "touch '\(f.marker.path)'; printf '%s' '{\"command\": 42}'"
        let config: [String: Any] = ["hooks": ["BeforeTool": [["matcher": "run_command", "hooks": [["type": "command", "command": command]]]]]]
        try JSONSerialization.data(withJSONObject: config).write(to: url)
        var hooks = HookManager()
        hooks.configPathOverride = url.path
        let t = try await turn(try app(f), call("run_command", ["command": .string("echo hi")]),
                               hooks: hooks, workspace: f.workspace, engine: Recorder(), answer: .deny)
        #expect(t.asked, "still asked: a non-text value is not a way around the gate")
        #expect(t.shown == "42", "shown as the text that would run")
        #expect(t.pill?.approval == nil, "denied, so nothing ran")
    }

    @Test("the hook's gate and the dispatcher's agree on which calls are gated")
    func gatedConditionsAgree() {
        let gated = [FunctionCall(name: "run_command", args: ["command": .string("ls")]),
                     FunctionCall(name: "read_file", args: ["path": .string("/x")]),
                     FunctionCall(name: "write_file", args: ["path": .string("/x"), "content": .string("y")])]
        let ungated = [FunctionCall(name: "run_command", args: [:]),
                       FunctionCall(name: "read_file", args: [:]),
                       FunctionCall(name: "search_web", args: ["query": .string("q")])]
        #expect(gated.allSatisfy(IrisEngine.isGatedFileOrCommand))
        #expect(!ungated.contains(where: IrisEngine.isGatedFileOrCommand))
    }

    @Test("Approve and run refuses a call its hook rewrites at the click, and says why")
    func approvedCardRefusesRewrite() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let target = f.workspace.appendingPathComponent("card.txt")
        let elsewhere = f.workspace.appendingPathComponent("elsewhere.txt")
        let hooks = try hooks(f, tool: "write_file", output: ["path": elsewhere.path])
        let state = try app(f)
        let iris = IrisEngine(state: state, tier: .medium, client: FakeLLMClient(responses: [text("unused")]),
                              retryDelays: [], protectionEnabled: false, sessionPeerCount: 0, hooks: hooks)
        let clickId = state.createNewConversation(isBackground: true, select: false)
        let card = BlockedCall(toolName: "write_file", args: ["path": .string(target.path), "content": .string("x")],
                               cwd: f.workspace.path)
        let result = await iris.executeApprovedCall(card, conversationId: clickId)
        #expect(result == IrisEngine.approvedCallRewrittenRefusal)
        #expect(!FileManager.default.fileExists(atPath: target.path) && !FileManager.default.fileExists(atPath: elsewhere.path))
    }

    @Test("a hook that changes nothing leaves an approved card's call to run as approved")
    func approvedCardWithoutRewriteRuns() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let target = f.workspace.appendingPathComponent("card.txt")
        let hooks = try hooks(f, tool: "write_file", output: nil)
        let state = try app(f)
        let iris = IrisEngine(state: state, tier: .medium, client: FakeLLMClient(responses: [text("unused")]),
                              retryDelays: [], protectionEnabled: false, sessionPeerCount: 0, hooks: hooks)
        let clickId = state.createNewConversation(isBackground: true, select: false)
        let card = BlockedCall(toolName: "write_file", args: ["path": .string(target.path), "content": .string("x")],
                               cwd: f.workspace.path)
        let result = await iris.executeApprovedCall(card, conversationId: clickId)
        #expect(result.hasPrefix("Successfully wrote to "), "\(result)")
    }
}
