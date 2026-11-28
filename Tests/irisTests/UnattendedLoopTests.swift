import Testing
import Foundation
@testable import IrisKit

/// #1425 slice A1: an unattended loop's turns that the person didn't type never show an approval dialog. The ladder
/// decides without anyone (no YOLO; prefix rules only while untainted), a call that needs a person is recorded once and
/// not run, and the person's own typed turns are unchanged.
@MainActor
@Suite("Unattended loops never stop on a dialog (#1425 A1)", .serialized, .timeLimit(.minutes(1)))
struct UnattendedLoopTests {
    // MARK: parsing

    @Test("--unattended starts a loop unattended; unattended on/off switches a running one")
    func parsing() {
        #expect(ConversationLoop.parse("--unattended 10m check the board") == .start(intervalSeconds: 600, prompt: "check the board", unattended: true))
        #expect(ConversationLoop.parse("--UNATTENDED check the board") == .startSelfPaced(prompt: "check the board", unattended: true))
        #expect(ConversationLoop.parse("10m check the board") == .start(intervalSeconds: 600, prompt: "check the board", unattended: false))
        #expect(ConversationLoop.parse("unattended on") == .setUnattended(true))
        #expect(ConversationLoop.parse("Unattended off") == .setUnattended(false))
        guard case .invalid = ConversationLoop.parse("--unattended") else { Issue.record("a bare flag starts nothing"); return }
        #expect(ConversationLoop.parse("unattended runs need care") == .startSelfPaced(prompt: "unattended runs need care", unattended: false),
                "only the two exact switches are commands")
    }

    @Test("a loop stored before #1425 reads as attended (Invariant 1)")
    func decodesOldLoops() throws {
        let old = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","prompt":"x","intervalSeconds":600,"ticksLeft":3,"cap":5,"paused":false,"selfPaced":false,"isAlarm":false}"#
        let loop = try JSONDecoder().decode(ConversationLoop.self, from: Data(old.utf8))
        #expect(!loop.unattended)
    }

    // MARK: the ladder

    private func setUp() throws -> (AppState, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("iris-1425a-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let state = AppState(store: try ConversationStore.inMemory(), tier2Provisioning: .provisioned, tier3Provisioning: .provisioned,
                             createIfEmpty: false, emitLaunchNotices: false)
        state.permissions = PermissionManager(paths: IrisPaths(root: root.appendingPathComponent("iris-home")))
        state.autoApproveTools = false
        state.vibecopEnabledOverride = false
        return (state, root)
    }

    private func looping(_ state: AppState, unattended: Bool = true, tainted: Bool = false) -> UUID {
        let id = state.createNewConversation(isBackground: false, select: false)
        let idx = state.conversations.firstIndex { $0.id == id }!
        state.conversations[idx].loop = ConversationLoop(prompt: "check the board", intervalSeconds: 600, cap: 5, unattended: unattended)
        state.conversations[idx].hasUntrustedToolOutput = tainted
        return id
    }

    private func ask(_ state: AppState, _ id: UUID, _ command: String, root: URL, tick: Bool = true,
                     humanOnly: Bool = false) async -> AppState.ApprovalSource? {
        await UnattendedLoop.$turn.withValue(tick) {
            await state.requestApprovalSource(toolName: "run_command", details: command, args: ["command": .string(command)],
                                              workspace: root.path, conversationId: id, humanOnly: humanOnly, isOwner: true)
        }
    }

    private func notices(_ state: AppState, _ id: UUID) -> [String] {
        state.conversations.first { $0.id == id }?.messages.filter { $0.content.hasPrefix("Not run (unattended loop)") }.map(\.content) ?? []
    }

    @Test("a call that needs a person isn't run and shows no dialog; it's recorded and noted once, however often it's asked")
    func needsPersonIsRecordedOnce() async throws {
        let (state, root) = try setUp(); defer { try? FileManager.default.removeItem(at: root) }
        let id = looping(state)
        for _ in 0..<3 {
            #expect(await ask(state, id, "git push origin pilot/x", root: root) == nil)
        }
        #expect(state.pendingApprovals.isEmpty, "no dialog")
        #expect(state.unattendedLoopDenials[id]?.calls.count == 1, "one record for the repeated call")
        #expect(notices(state, id).count == 1)
        #expect(notices(state, id).first?.contains("git push origin pilot/x") == true)
        _ = await ask(state, id, "git push origin pilot/y", root: root)
        #expect(state.unattendedLoopDenials[id]?.calls.count == 2, "another call is its own record")
    }

    @Test("an Always-allow prefix runs while the conversation is clean; once it has read outside text, only an exact rule does")
    func prefixRulesOnlyWhileUntainted() async throws {
        let (state, root) = try setUp(); defer { try? FileManager.default.removeItem(at: root) }
        state.permissions.allowGlobally([PermissionRule(toolName: "run_command", details: "swift test", match: .prefix),
                                         PermissionRule(toolName: "run_command", details: "swift build")])
        let clean = looping(state), tainted = looping(state, tainted: true)
        guard case .allowlist? = await ask(state, clean, "swift test --filter X", root: root) else {
            Issue.record("a clean loop's prefix rule should allow it"); return
        }
        #expect(await ask(state, tainted, "swift test --filter X", root: root) == nil, "tainted: the prefix no longer counts")
        guard case .allowlist? = await ask(state, tainted, "swift build", root: root) else {
            Issue.record("tainted: an exact rule still allows its exact call"); return
        }
        #expect(state.pendingApprovals.isEmpty)
    }

    @Test("YOLO doesn't approve for an unattended loop's turn, and a person-only call is recorded, not asked")
    func noYoloNoDialogForPersonOnly() async throws {
        let (state, root) = try setUp(); defer { try? FileManager.default.removeItem(at: root) }
        let id = looping(state)
        state.setYoloMode(true, for: id)
        #expect(state.isYoloMode(id), "control: YOLO is on for this conversation")
        #expect(await ask(state, id, "rm -rf build", root: root) == nil)
        #expect(await ask(state, id, "schedule it", root: root, humanOnly: true) == nil)
        #expect(state.pendingApprovals.isEmpty)
        #expect(state.unattendedLoopDenials[id]?.calls.count == 2)
    }

    @Test("the person's own typed turn in the same conversation still asks, as an attended turn does")
    func typedTurnStillAsks() async throws {
        let (state, root) = try setUp(); defer { try? FileManager.default.removeItem(at: root) }
        let id = looping(state)
        async let source = ask(state, id, "git push origin pilot/x", root: root, tick: false)
        for _ in 0..<80 where state.pendingApprovals.isEmpty { try? await Task.sleep(nanoseconds: 25_000_000) }
        #expect(state.pendingApprovals.count == 1, "the dialog appears")
        if let request = state.pendingApprovals.first { state.resolveApproval(id: request.id, .approve) }
        #expect(await source == .person)
        #expect(state.unattendedLoopDenials[id] == nil)
    }

    @Test("an attended loop's tick asks as before")
    func attendedLoopUnchanged() async throws {
        let (state, root) = try setUp(); defer { try? FileManager.default.removeItem(at: root) }
        let id = looping(state, unattended: false)
        // The mark is set only for an unattended loop, so an attended loop's tick runs with it off.
        async let source = ask(state, id, "git push origin pilot/x", root: root, tick: false)
        for _ in 0..<80 where state.pendingApprovals.isEmpty { try? await Task.sleep(nanoseconds: 25_000_000) }
        #expect(state.pendingApprovals.count == 1)
        if let request = state.pendingApprovals.first { state.resolveApproval(id: request.id, .deny) }
        #expect(await source == nil)
    }

    @Test("#1439's log labels a held call unattended-held, apart from a plain no")
    func heldIsLogged() async throws {
        let (state, root) = try setUp(); defer { try? FileManager.default.removeItem(at: root) }
        var records: [LoopApprovalRecord] = []
        state.loopApprovalSink = { records.append($0) }
        let id = looping(state)
        _ = await ask(state, id, "git push origin pilot/x", root: root)
        #expect(records.map(\.layer) == ["unattended-held"] && records.first?.asked == false && records.first?.tick == false,
                "\(records.map(\.layer))")
    }

    /// dev-1's #1447 review: a delegate's turn recomputed the mark from its own conversation (no loop) and showed dialogs.
    @Test("a subagent of an unattended tick asks nobody, and its call is held on the loop's conversation", arguments: [true, false])
    func delegateInheritsTheMark(parentTick: Bool) async throws {
        let (state, root) = try setUp(); defer { try? FileManager.default.removeItem(at: root) }
        let parent = looping(state)
        let child = state.createNewConversation(isBackground: false, select: false)
        state.linkDelegate(child, of: parent)
        let call = FunctionCall(name: "run_command", args: ["command": .string("git push origin pilot/x")], id: "c1")
        let client = FakeLLMClient(responses: [reply(Part(functionCall: call)), reply(Part(text: "done"))])
        // `.main`, not `.subagent`: what makes the child a delegate is its link, which is all the mark reads. A
        // `.subagent` engine's command resolves to the sandbox, and with no container runtime (CI's runner) it is
        // refused before any approval is asked, so the row would test the runtime, not the inheritance (#1447 CI).
        let engine = IrisEngine(state: state, tier: .medium, principal: .main, client: client, retryDelays: [],
                                protectionEnabled: false, sessionPeerCount: 0)
        state.setWorkspace(for: child, path: root.path)
        // The parent turn's mark, as a subagent's `Task` carries it from the tick (or from a typed turn).
        let run = Task { await UnattendedLoop.$turn.withValue(parentTick) {
            await engine.processInput("subtask", source: "System", conversationId: child)
        } }
        if parentTick {
            // Nothing can block an unattended turn, so the run finishes on its own: wait for it, not for a window.
            // CI's runner took ~15 s over this turn (#1447 run 46092000550), so no short poll.
            try await value(of: run, within: 45)
            #expect(state.pendingApprovals.isEmpty, "a subagent of an unattended tick shows no dialog")
            #expect(state.unattendedLoopDenials[parent]?.calls.count == 1, "held on the loop's conversation")
            #expect(notices(state, parent).count == 1)
        } else {
            let deadline = TestClock.deadline(45)
            while state.pendingApprovals.isEmpty, TestClock.now() < deadline { try? await Task.sleep(nanoseconds: 25_000_000) }
            #expect(state.pendingApprovals.count == 1, "a subagent of the person's typed turn still asks")
            state.denyPendingApprovals(for: child)
            try await value(of: run, within: 45)
        }
    }

    /// dev-3's #1447 review: the root half of the taint check had no row.
    @Test("a clean subagent of a tainted loop's tick gets exact rules only, as its root does")
    func delegateTaintFollowsRoot() async throws {
        let (state, root) = try setUp(); defer { try? FileManager.default.removeItem(at: root) }
        state.permissions.allowGlobally([PermissionRule(toolName: "run_command", details: "swift test", match: .prefix)])
        let parent = looping(state, tainted: true)
        let child = state.createNewConversation(isBackground: false, select: false)
        state.linkDelegate(child, of: parent)
        #expect(state.conversations.first { $0.id == child }?.hasUntrustedToolOutput == false, "control: the delegate itself is clean")
        #expect(await ask(state, child, "swift test --filter X", root: root) == nil, "the root read outside text, so the prefix doesn't count")
        #expect(state.unattendedLoopDenials[parent]?.calls.count == 1)
    }

    @Test("the dialog sink itself refuses on an unattended loop's turn, whatever gate asked")
    func dialogBackstop() async throws {
        let (state, root) = try setUp(); defer { try? FileManager.default.removeItem(at: root) }
        let id = looping(state)
        let shown = await UnattendedLoop.$turn.withValue(true) {
            await state.enqueueUserApproval(toolName: "read_file", details: "/etc/hosts", workspace: nil, conversationId: id, origin: "guard")
        }
        #expect(!shown && state.pendingApprovals.isEmpty)
    }

    // MARK: the turn

    private func reply(_ part: Part) -> GeminiResponse {
        GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [part]))], usageMetadata: nil)
    }

    @Test("an unattended loop's tick isn't offered job or workspace tools, keeps the session tools, and a typed turn keeps them all")
    func tickToolsStripped() async throws {
        let (state, root) = try setUp(); defer { try? FileManager.default.removeItem(at: root) }
        let id = looping(state)
        let tick = CapturingLLMClient(reply: "ok")
        let engine = IrisEngine(state: state, tier: .medium, principal: .main, client: tick, retryDelays: [],
                                protectionEnabled: false, sessionPeerCount: 1, declareStateGatedTools: true)
        await engine.processInput("tick", source: IrisEngine.loopSource, conversationId: id)
        let tickTools = Set(tick.requests.first?.tools?.flatMap(\.functionDeclarations).map(\.name) ?? [])
        #expect(tickTools.isDisjoint(with: UnattendedLoop.strippedTools), "\(tickTools.intersection(UnattendedLoop.strippedTools))")
        #expect(tickTools.contains("send_to_session"), "a fleet keeps its session tools")
        let typed = CapturingLLMClient(reply: "ok")
        let engine2 = IrisEngine(state: state, tier: .medium, principal: .main, client: typed, retryDelays: [],
                                 protectionEnabled: false, sessionPeerCount: 1, declareStateGatedTools: true)
        await engine2.processInput("hi", source: "UI", conversationId: id)
        let typedTools = Set(typed.requests.first?.tools?.flatMap(\.functionDeclarations).map(\.name) ?? [])
        #expect(typedTools.contains("schedule_job"), "control: the person's own turn is offered them")
    }

    @Test("the model is told the call wasn't run and not to retry or route around it")
    func tickDenialText() async throws {
        let (state, root) = try setUp(); defer { try? FileManager.default.removeItem(at: root) }
        let id = looping(state)
        state.setWorkspace(for: id, path: root.path)
        let call = FunctionCall(name: "run_command", args: ["command": .string("git push origin pilot/x")], id: "c1")
        let client = FakeLLMClient(responses: [reply(Part(functionCall: call)), reply(Part(text: "done"))])
        let engine = IrisEngine(state: state, tier: .medium, principal: .main, client: client, retryDelays: [],
                                protectionEnabled: false, sessionPeerCount: 0)
        await engine.processInput("tick", source: IrisEngine.loopSource, conversationId: id)
        let results = state.conversations.first { $0.id == id }?.history.flatMap(\.parts).compactMap { part -> String? in
            guard case .string(let s)? = part.functionResponse?.response["result"] else { return nil }
            return s
        } ?? []
        #expect(results.last == UnattendedLoop.deniedToolResult(tool: "run_command"), "\(results)")
        #expect(state.pendingApprovals.isEmpty)
        #expect(state.unattendedLoopDenials[id]?.calls.first?.args["command"] == .string("git push origin pilot/x"))
    }
}
