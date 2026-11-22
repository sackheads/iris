import Testing
import Foundation
@testable import IrisKit

/// #1115, Brian's rulings: "yes, yolo can ask about those sensitive writes. peers and guests should
/// not get access to yolo", and "yes" to job and watcher creation asking under YOLO too. Every case
/// is driven as a model turn through `engine.processInput`, so the dispatcher's real ladder decides,
/// with a YOLO control beside it that would pass vacuously if YOLO were not on at all.
@MainActor
@Suite("YOLO stays the owner's and never mints a grant (#1115)", .serialized, .timeLimit(.minutes(1)))
struct YoloOwnerOnlyTests {
    /// Gives no verdict, so a call that falls through to the ordinary ladder reaches the person
    /// rather than being decided by a local model the test does not have.
    private final class SilentVibecop: AuxiliaryInferenceEngine, @unchecked Sendable {
        func loadModel(config: AuxiliaryModelConfig) async throws {}
        func unloadModel() async {}
        func generate(prompt: String, jsonSchema: String?) async throws -> String { "" }
    }

    /// Answers each call from `script`; `beforeCall` runs before the answer at that index, so a
    /// test can land a peer message in the middle of a turn.
    private final class ScriptedClient: LLMClientProtocol, @unchecked Sendable {
        private let lock = NSLock()
        private var index = 0
        let script: [GeminiResponse]
        var beforeCall: [Int: @Sendable () async -> Void] = [:]
        init(_ script: [GeminiResponse]) { self.script = script }
        func generateContent(request: GeminiRequest, tier: ModelTier) async throws -> GeminiResponse {
            let i = lock.withLock { () -> Int in defer { index += 1 }; return index }
            if let hook = beforeCall[i] { await hook() }
            return script[min(i, script.count - 1)]
        }
    }

    private struct World {
        let root: URL
        let home: IrisPaths
        let state: AppState
        let cid: UUID
        func tearDown() { try? FileManager.default.removeItem(at: root) }
    }

    private func world() throws -> World {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("iris-1115-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("ws"), withIntermediateDirectories: true)
        let home = IrisPaths(root: root.appendingPathComponent("iris-home"))
        let state = AppState(store: try ConversationStore.inMemory(), tier2Provisioning: .provisioned, tier3Provisioning: .provisioned,
                             createIfEmpty: false, emitLaunchNotices: false)
        state.permissions = PermissionManager(paths: home)
        let cid = state.createNewConversation(isBackground: false, select: true)
        state.setWorkspace(for: cid, path: root.appendingPathComponent("ws").path)
        return World(root: root, home: home, state: state, cid: cid)
    }

    private static func call(_ name: String, _ args: [String: JSONValue], id: String = "c1") -> GeminiResponse {
        GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [Part(functionCall: FunctionCall(
            name: name, args: args, id: id))]))], usageMetadata: nil)
    }
    private static let done = GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [Part(text: "done")]))],
                                             usageMetadata: nil)

    private func engine(_ w: World, _ client: any LLMClientProtocol) -> IrisEngine {
        IrisEngine(state: w.state, tier: .medium, client: client, retryDelays: [], protectionEnabled: false, sessionPeerCount: 0,
                   accessProfileStore: AccessProfileStore(paths: w.home))
    }

    /// Runs one model turn that makes `call` and reports whether it reached the person, denying it
    /// there; `ran` is what the call would have left behind had it run unasked.
    private func asksThePerson(_ w: World, _ call: GeminiResponse, ran: () -> Bool,
                               client: ScriptedClient? = nil) async throws -> Bool {
        let client = client ?? ScriptedClient([call, Self.done])
        let engine = engine(w, client)
        return try await AuxiliaryModelManager.$scopedEngines.withValue(["vibecop": SilentVibecop()]) {
            let turn = Task { await engine.processInput("go", source: "UI", conversationId: w.cid) }
            let deadline = TestClock.deadline(5)
            while w.state.pendingApprovals.isEmpty, TestClock.now() < deadline, !turnEnded(w) {
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            let asked = !w.state.pendingApprovals.isEmpty
            #expect(!ran(), "nothing may run before the person decides")
            w.state.denyPendingApprovals(for: w.cid)
            _ = try await value(of: turn, within: 10)
            return asked
        }
    }

    private func eventually(_ seconds: Double = 5, _ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = TestClock.deadline(seconds)
        while TestClock.now() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }

    private func turnEnded(_ w: World) -> Bool {
        w.state.conversations.first { $0.id == w.cid }?.messages.contains { $0.role == .agent && $0.content == "done" } == true
    }

    // MARK: Sensitive writes

    @Test("under YOLO, a write into config/, plugins/, a workspace .git (nested, or through a link) asks the person")
    func grantMintingWritesAskUnderYolo() async throws {
        let targets: [(String, (World) throws -> String)] = [
            ("config/permissions.json", { $0.home.permissionsJSON.path }),
            ("config/vibecop.md", { $0.home.configDir.appendingPathComponent("vibecop.md").path }),
            ("plugins/", { $0.home.pluginsDir.appendingPathComponent("evil/plugin.json").path }),
            (".git/hooks/ (nested repo)", { w in
                let hooks = w.root.appendingPathComponent("ws/sub/.git/hooks")
                try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: true)
                return hooks.appendingPathComponent("pre-commit").path
            }),
            (".git through a link", { w in
                let git = w.root.appendingPathComponent("ws/.git/hooks")
                try FileManager.default.createDirectory(at: git, withIntermediateDirectories: true)
                let link = w.root.appendingPathComponent("ws/innocent")
                try FileManager.default.createSymbolicLink(at: link, withDestinationURL: git)
                return link.appendingPathComponent("post-checkout").path
            }),
        ]
        for (label, makeTarget) in targets {
            let w = try world(); defer { w.tearDown() }
            w.state.sendMessage("/yolo on")
            #expect(w.state.isYoloMode(w.cid))
            let target = try makeTarget(w)
            let asked = try await asksThePerson(w, Self.call("write_file", ["path": .string(target), "content": .string("x")]),
                                                ran: { FileManager.default.fileExists(atPath: target) })
            #expect(asked, "\(label): YOLO must not approve a write that grants permission")
        }
    }

    @Test("control: under YOLO an ordinary workspace write still runs unasked")
    func ordinaryWriteStillYolo() async throws {
        let w = try world(); defer { w.tearDown() }
        w.state.sendMessage("/yolo on")
        let target = w.root.appendingPathComponent("ws/notes.md").path
        let asked = try await asksThePerson(w, Self.call("write_file", ["path": .string(target), "content": .string("x")]),
                                            ran: { false })
        #expect(!asked)
        #expect(FileManager.default.fileExists(atPath: target), "YOLO approved it, so it ran")
    }

    @Test("under YOLO, a host command naming config/, plugins/ or exchange/ under Iris's home asks the person")
    func shellGrantMintingWritesAskUnderYolo() async throws {
        for dir in ["config", "plugins", "exchange"] {
            let w = try world(); defer { w.tearDown() }
            w.state.sendMessage("/yolo on")
            let target = w.home.root.appendingPathComponent("\(dir)/planted.json").path
            let asked = try await asksThePerson(w, Self.call("run_command", ["command": .string("printf x > '\(target)'")]),
                                                ran: { FileManager.default.fileExists(atPath: target) })
            #expect(asked, "\(dir)/: YOLO must not approve a shell write that grants permission")
        }
    }

    @Test("control: under YOLO an ordinary host command still runs unasked")
    func ordinaryCommandStillYolo() async throws {
        let w = try world(); defer { w.tearDown() }
        w.state.sendMessage("/yolo on")
        let target = w.root.appendingPathComponent("ws/out.txt").path
        let asked = try await asksThePerson(w, Self.call("run_command", ["command": .string("printf x > '\(target)'")]), ran: { false })
        #expect(!asked)
        #expect(FileManager.default.fileExists(atPath: target), "YOLO approved it, so it ran")
    }

    /// The widening on purpose (planner's R2): with YOLO off too, a shell write naming `config/` is a
    /// person's alone, so its card offers no Always Allow, as a `profiles/` write's already did.
    @Test("without YOLO, a host command naming config/ asks with no Always Allow")
    func shellConfigWriteOffersNoAlwaysAllow() async throws {
        let w = try world(); defer { w.tearDown() }
        let target = w.home.configDir.appendingPathComponent("permissions.json").path
        let engine = engine(w, ScriptedClient([Self.call("run_command", ["command": .string("printf x > '\(target)'")]), Self.done]))
        try await AuxiliaryModelManager.$scopedEngines.withValue(["vibecop": SilentVibecop()]) {
            let turn = Task { await engine.processInput("go", source: "UI", conversationId: w.cid) }
            _ = await eventually { !w.state.pendingApprovals.isEmpty }
            let request = try #require(w.state.pendingApprovals.first)
            #expect(!request.offersAlwaysAllow, "no standing rule may answer a write to Iris's own configuration")
            w.state.denyPendingApprovals(for: w.cid)
            _ = try await value(of: turn, within: 10)
        }
        #expect(!FileManager.default.fileExists(atPath: target))
    }

    // MARK: Non-owner bindings

    @Test("a guest-steered binding gets no YOLO even without the guest-origin turn mark")
    func nonOwnerBindingGetsNoYolo() async throws {
        let w = try world(); defer { w.tearDown() }
        w.state.sendMessage("/yolo on")
        // Only the binding stamp, not `markGuestOriginTurn`: `isYoloMode`'s guest check would catch
        // the pair, so this isolates the ladder's own owner check.
        w.state.markGuestSteeredBinding(AccessBinding(profile: AccessProfile(), principal: .mcpGuest, isOwner: false), for: w.cid)
        let target = w.root.appendingPathComponent("ws/notes.md").path
        let asked = try await asksThePerson(w, Self.call("write_file", ["path": .string(target), "content": .string("x")]),
                                            ran: { FileManager.default.fileExists(atPath: target) })
        #expect(asked, "a non-owner turn's call takes the ordinary ladder, not YOLO")
    }

    @Test("/yolo on in a session bound to an access profile says why and stays off")
    func boundSessionRefusesYolo() throws {
        let w = try world(); defer { w.tearDown() }
        let idx = try #require(w.state.conversations.firstIndex { $0.id == w.cid })
        w.state.conversations[idx].accessProfileId = "reviewer"
        w.state.sendMessage("/yolo on")
        #expect(!w.state.isYoloMode(w.cid))
        let said = w.state.conversations[idx].messages.map(\.content)
        #expect(said.contains(AppState.yoloRefusedForBoundSession), "\(said)")
    }

    // MARK: Peers

    private func envelope() -> PeerEnvelope {
        PeerEnvelope(msgId: UUID().uuidString, contextId: "ctx-\(UUID().uuidString)", depth: 1, expectsReply: false, replyTo: nil)
    }

    @Test("a peer message mid-turn ends YOLO from that call on, for good; the owner's next turn still asks")
    func peerSteerEndsYolo() async throws {
        let w = try world(); defer { w.tearDown() }
        w.state.sendMessage("/yolo on")
        let peer = w.state.createNewConversation(title: "peer", select: false)
        w.state.selectedConversationId = w.cid
        let first = w.root.appendingPathComponent("ws/a.md").path
        let second = w.root.appendingPathComponent("ws/b.md").path
        let client = ScriptedClient([
            Self.call("write_file", ["path": .string(first), "content": .string("a")], id: "c1"),
            Self.call("write_file", ["path": .string(second), "content": .string("b")], id: "c2"),
            Self.done,
        ])
        let eng = engine(w, client)
        let state = w.state, cid = w.cid, env = envelope()
        client.beforeCall[1] = {
            let outcome = await eng.deliverPeerMessage("also do this", from: peer, senderName: "peer", to: cid, envelope: env)
            await MainActor.run { #expect(outcome == .queued, "busy target: the peer's text lands as a steer") }
            _ = state
        }
        let asked = try await AuxiliaryModelManager.$scopedEngines.withValue(["vibecop": SilentVibecop()]) { () async throws -> Bool in
            let turn = Task { await eng.processInput("go", source: "UI", conversationId: cid) }
            let deadline = TestClock.deadline(5)
            while state.pendingApprovals.isEmpty, TestClock.now() < deadline {
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            let asked = !state.pendingApprovals.isEmpty
            state.denyPendingApprovals(for: cid)
            _ = try await value(of: turn, within: 10)
            return asked
        }
        #expect(FileManager.default.fileExists(atPath: first), "the call before the peer's message ran under YOLO")
        #expect(asked, "the call after it asked")
        #expect(!FileManager.default.fileExists(atPath: second))
        #expect(!w.state.isYoloMode(w.cid), "and YOLO stays off")
        #expect(w.state.conversations.first { $0.id == w.cid }?.hasPeerInput == true)
    }

    @Test("a background subagent's post-back leaves YOLO on")
    func subagentPostBackKeepsYolo() async throws {
        let w = try world(); defer { w.tearDown() }
        w.state.sendMessage("/yolo on")
        let eng = engine(w, ScriptedClient([Self.done]))
        await eng.handleSystemEvent("Background subagent result: built", source: "SubagentManager", conversationId: w.cid)
        #expect(w.state.conversations.first { $0.id == w.cid }?.hasUnattendedInput == true, "it did arrive unattended")
        #expect(w.state.conversations.first { $0.id == w.cid }?.hasPeerInput == false)
        #expect(w.state.isYoloMode(w.cid))
    }

    @Test("/yolo on after a peer message says why and stays off")
    func peerTouchedSessionRefusesYolo() async throws {
        let w = try world(); defer { w.tearDown() }
        let peer = w.state.createNewConversation(title: "peer", select: false)
        w.state.selectedConversationId = w.cid
        let eng = engine(w, ScriptedClient([Self.done]))
        _ = await eng.deliverPeerMessage("hi", from: peer, senderName: "peer", to: w.cid, envelope: envelope())
        _ = await eventually { !w.state.hasTurnInFlight(for: w.cid) }
        w.state.sendMessage("/yolo on")
        #expect(!w.state.isYoloMode(w.cid))
        let said = w.state.conversations.first { $0.id == w.cid }?.messages.map(\.content) ?? []
        #expect(said.contains(AppState.yoloRefusedForPeerInput), "\(said)")
    }

    @Test("hasPeerInput round-trips through the real store on INSERT and UPDATE, and an absent key reads false")
    func flagPersists() throws {
        let store = try ConversationStore.inMemory()
        var c = ConversationStoreTests.sample()
        c.hasPeerInput = true
        try store.apply([ConversationStoreTests.created(c)])
        #expect(try #require(try store.loadAll().conversations.first).hasPeerInput == true, "INSERT path")

        var other = ConversationStoreTests.sample()
        try store.apply([ConversationStoreTests.created(other)])
        #expect(try store.loadAll().conversations.first { $0.id == other.id }?.hasPeerInput == false, "default is false")
        other.hasPeerInput = true
        var change = ChangeSet(); change.add(.metadata)
        try store.apply([ConversationWrite(id: other.id, snapshot: other, changes: change)])
        #expect(try store.loadAll().conversations.first { $0.id == other.id }?.hasPeerInput == true, "UPDATE path")

        let coded = try JSONDecoder().decode(Conversation.self, from: JSONEncoder().encode(c))
        #expect(coded.hasPeerInput == true, "the Codable route keeps it too")
        let json = "{\"id\":\"\(UUID().uuidString)\",\"title\":\"legacy\"}"
        #expect(try JSONDecoder().decode(Conversation.self, from: Data(json.utf8)).hasPeerInput == false, "Invariant 1")
    }
}

/// Only the person can turn YOLO on: the composer is the one caller of `sendMessage`, and
/// `handleYoloCommand` the one caller of `setYoloMode(true`. A peer, guest or tool route that
/// reached either would let someone else switch it on.
@Suite("only the composer turns YOLO on (#1115)")
struct YoloEnableRouteSourceScanTests {
    @Test("sendMessage is called only from ChatView, and setYoloMode(true only from handleYoloCommand")
    func onlyTheComposerEnablesYolo() throws {
        let sources = PerfPaths.repoRoot().appendingPathComponent("Sources/IrisKit")
        let files = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        #expect(files.count > 50, "the scan must see the product sources")
        var senders: [String] = [], enablers = 0
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            if text.contains(".sendMessage(") { senders.append(file.lastPathComponent) }
            enablers += text.components(separatedBy: "setYoloMode(true").count - 1
        }
        #expect(senders == ["ChatView.swift"], "\(senders)")
        #expect(enablers == 1, "the one in handleYoloCommand")
        let app = try String(contentsOf: sources.appendingPathComponent("AppState.swift"), encoding: .utf8)
        let handler = try #require(app.range(of: "private func handleYoloCommand"))
        #expect(app[handler.lowerBound...].contains("setYoloMode(true"), "the enabler lives in the command handler")
    }
}
