import Testing
import AVFoundation
import Foundation
@testable import IrisKit

@MainActor
@Suite("YOLO mode (#1099)", .timeLimit(.minutes(1)))
struct YoloModeTests {

    private final class ExplodingVibecop: AuxiliaryInferenceEngine, @unchecked Sendable {
        var calls = 0
        func loadModel(config: AuxiliaryModelConfig) async throws {}
        func unloadModel() async {}
        func generate(prompt: String, jsonSchema: String?) async throws -> String {
            calls += 1
            return #"{"decision":"DENY","reason":"should never have been consulted in yolo mode"}"#
        }
    }

    private func home() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("iris-1099-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeState(_ root: URL) throws -> AppState {
        let state = AppState(store: try ConversationStore.inMemory(),
                             tier2Provisioning: .provisioned, tier3Provisioning: .provisioned,
                             createIfEmpty: false, emitLaunchNotices: false)
        state.permissions = PermissionManager(paths: IrisPaths(root: root.appendingPathComponent("iris-home")))
        return state
    }

    @Test("/yolo command shows status, toggles on and off, and plays jingles")
    func slashCommandTogglesAndPlaysJingles() throws {
        let root = try home(); defer { try? FileManager.default.removeItem(at: root) }
        let state = try makeState(root)
        let cid = state.createNewConversation(isBackground: false, select: true)

        var vengabusPlays = 0
        var powerDownPlays = 0
        state.yoloAudio = YoloAudioHooks(
            playOn: { vengabusPlays += 1 },
            playOff: { powerDownPlays += 1 }
        )

        #expect(!state.isYoloMode(cid))

        state.sendMessage("/yolo")
        #expect(state.conversations.first { $0.id == cid }?.messages.last?.content == "Yolo mode is off.")
        #expect(vengabusPlays == 0)
        #expect(powerDownPlays == 0)

        state.sendMessage("/yolo on")
        #expect(state.isYoloMode(cid))
        #expect(state.conversations.first { $0.id == cid }?.messages.last?.content == "Yolo mode is on.")
        #expect(vengabusPlays == 1)
        #expect(powerDownPlays == 0)

        state.sendMessage("/yolo")
        #expect(state.conversations.first { $0.id == cid }?.messages.last?.content == "Yolo mode is on.")

        state.sendMessage("/yolo off")
        #expect(!state.isYoloMode(cid))
        #expect(state.conversations.first { $0.id == cid }?.messages.last?.content == "Yolo mode is off.")
        #expect(vengabusPlays == 1)
        #expect(powerDownPlays == 1)

        state.sendMessage("/yolo maybe")
        #expect(state.conversations.first { $0.id == cid }?.messages.last?.content == "Usage: `/yolo [on|off]`")
    }

    @Test("SlashCommandItem includes /yolo")
    func slashCommandItemIncludesYolo() {
        let matches = SlashCommandItem.matches(for: "/yo")
        #expect(matches.count == 1)
        #expect(matches.first?.command == "/yolo")
        #expect(matches.first?.usage == "/yolo [on|off]")
    }

    @Test("YOLO mode is per-conversation and inherited by delegates")
    func perSessionAndInheritedByDelegates() throws {
        let root = try home(); defer { try? FileManager.default.removeItem(at: root) }
        let state = try makeState(root)
        let c1 = state.createNewConversation(isBackground: false, select: true)
        let c2 = state.createNewConversation(isBackground: false, select: false)
        let sub = state.createNewConversation(isSubagent: true, isBackground: false, select: false)
        state.linkDelegate(sub, of: c1)

        state.sendMessage("/yolo on")
        #expect(state.isYoloMode(c1))
        #expect(state.isYoloMode(sub))
        #expect(!state.isYoloMode(c2))
    }

    @Test("YOLO mode approves an ordinary command without Vibecop or user prompt")
    func approvesAllAttendedCallsWithoutVibecop() async throws {
        let root = try home(); defer { try? FileManager.default.removeItem(at: root) }
        let state = try makeState(root)
        let cid = state.createNewConversation(isBackground: false, select: true)
        state.setWorkspace(for: cid, path: root.path)
        state.sendMessage("/yolo on")

        let vibecop = ExplodingVibecop()
        let cmdSource = await AuxiliaryModelManager.$scopedEngines.withValue(["vibecop": vibecop]) {
            await state.requestApprovalSource(toolName: "run_command", details: "rm -rf build && make",
                                              workspace: root.path, conversationId: cid, vibecopEnabled: true, isOwner: true)
        }
        #expect(cmdSource == .yolo)
        #expect(vibecop.calls == 0)
        #expect(state.pendingApprovals.isEmpty)
        #expect(ToolApproval(try #require(cmdSource)).line == "Approved (YOLO mode).")
    }

    /// #1115: `humanOnly` and `irisWrite` (a workspace `.iris/` write, #617) are critical
    /// approvals Brian reserved for himself -- a standing session convenience like YOLO must
    /// never auto-approve either, even though YOLO does auto-approve an ordinary command above.
    @Test("YOLO mode never bypasses a .iris/ write or an explicit humanOnly call; both still prompt")
    func yoloNeverBypassesHumanOnlyOrIrisWrite() async throws {
        let root = try home(); defer { try? FileManager.default.removeItem(at: root) }
        let state = try makeState(root)
        let cid = state.createNewConversation(isBackground: false, select: true)
        state.setWorkspace(for: cid, path: root.path)
        state.sendMessage("/yolo on")

        // Workspace .iris/ write (irisWrite, #617): still asks under YOLO.
        let irisFile = root.appendingPathComponent(".iris/vibecop.md").path
        async let irisWriteSource = state.requestApprovalSource(toolName: "write_file", details: irisFile,
                                                                 workspace: root.path, conversationId: cid, vibecopEnabled: false, isOwner: true)
        for _ in 0..<40 where state.pendingApprovals.isEmpty {
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        #expect(state.pendingApprovals.count == 1, "an .iris/ write must reach the queue despite YOLO")
        if state.pendingApprovals.isEmpty {
            state.denyPendingApprovals(for: cid)
        } else {
            state.resolveApproval(id: state.pendingApprovals[0].id, .approve)
        }
        #expect(await irisWriteSource == .person)

        // Explicit humanOnly (e.g. job creation, outbound tool): still asks under YOLO.
        async let humanOnlySource = state.requestApprovalSource(toolName: "schedule_job", details: "name: test",
                                                                  workspace: root.path, conversationId: cid, humanOnly: true, isOwner: true)
        for _ in 0..<40 where state.pendingApprovals.isEmpty {
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        #expect(state.pendingApprovals.count == 1, "a humanOnly call must reach the queue despite YOLO")
        if state.pendingApprovals.isEmpty {
            state.denyPendingApprovals(for: cid)
        } else {
            state.resolveApproval(id: state.pendingApprovals[0].id, .approve)
        }
        #expect(await humanOnlySource == .person)

        // #1115 rebase-conflict fold: a host command writing an access-policy store (#974 Task
        // 9b F6, policyWrite) is the same class of Brian-reserved approval -- #1221 added it to
        // the single post-YOLO check that existed then; the #1115 rebase had to fold it into the
        // new pre-YOLO check too, or YOLO would bypass it exactly like it used to bypass
        // humanOnly/irisWrite.
        // The real Iris home (`makeState`'s `paths.root`), not `root` itself -- a path spelled
        // under `root` directly would also contain a literal ".iris"-looking component and get
        // caught by `irisWrite` too, making the probe ambiguous about which check is doing the
        // work.
        let profilePath = root.appendingPathComponent("iris-home/profiles/evil.json").path
        async let policyWriteSource = state.requestApprovalSource(toolName: "run_command",
                                                                    details: "echo x > \(profilePath)",
                                                                    workspace: root.path, conversationId: cid, isOwner: true)
        for _ in 0..<40 where state.pendingApprovals.isEmpty {
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        #expect(state.pendingApprovals.count == 1, "a policy-store write must reach the queue despite YOLO")
        if state.pendingApprovals.isEmpty {
            state.denyPendingApprovals(for: cid)
        } else {
            state.resolveApproval(id: state.pendingApprovals[0].id, .approve)
        }
        #expect(await policyWriteSource == .person)
    }

    @Test("Background job runs and MCP guests never get YOLO mode")
    func backgroundAndGuestNeverYolo() async throws {
        let root = try home(); defer { try? FileManager.default.removeItem(at: root) }
        let state = try makeState(root)
        let bg = state.createNewConversation(isBackground: true, select: false)
        let guest = state.createNewConversation(isGuest: true, guestClientId: "c1", select: false)

        // Even if someone calls setYoloMode directly on a background or guest conversation, it refuses
        state.setYoloMode(true, for: bg)
        state.setYoloMode(true, for: guest)
        #expect(!state.isYoloMode(bg))
        #expect(!state.isYoloMode(guest))

        let bgSource = await state.requestApprovalSource(toolName: "run_command", details: "ls",
                                                         workspace: root.path, conversationId: bg, isOwner: true)
        #expect(bgSource == nil)
        #expect(state.takeBackgroundDenials(for: bg).count == 1)

        let guestSource = await state.requestApprovalSource(toolName: "run_command", details: "ls",
                                                            workspace: root.path, conversationId: guest, isOwner: true)
        #expect(guestSource == nil)
    }

    // Layer 1 of isYoloMode (the named conversation's own isBackground/isGuest) is the only thing
    // standing here: the delegation root is a user-facing session with /yolo on, so layer 2 passes.
    @Test("A background or guest conversation linked under a YOLO session is still never YOLO (#1117)")
    func directCheckAloneExcludesBackgroundAndGuest() async throws {
        let root = try home(); defer { try? FileManager.default.removeItem(at: root) }
        let state = try makeState(root)
        let main = state.createNewConversation(isBackground: false, select: true)
        state.setYoloMode(true, for: main)
        let bg = state.createNewConversation(isBackground: true, select: false)
        let guest = state.createNewConversation(isGuest: true, guestClientId: "c1", select: false)
        let control = state.createNewConversation(isSubagent: true, isBackground: false, select: false)
        state.linkDelegate(bg, of: main)
        state.linkDelegate(guest, of: main)
        state.linkDelegate(control, of: main)

        #expect(state.delegationRoot(of: bg) == main)
        #expect(state.delegationRoot(of: guest) == main)
        #expect(state.isYoloMode(main))
        #expect(state.isYoloMode(control))   // the link alone grants YOLO to an ordinary delegate
        #expect(!state.isYoloMode(bg))
        #expect(!state.isYoloMode(guest))

        let bgSource = await state.requestApprovalSource(toolName: "run_command", details: "ls",
                                                         workspace: root.path, conversationId: bg, isOwner: true)
        #expect(bgSource == nil)
        let guestSource = await state.requestApprovalSource(toolName: "run_command", details: "ls",
                                                            workspace: root.path, conversationId: guest, isOwner: true)
        #expect(guestSource == nil)
    }

    @Test("Turning /yolo on resolves any pending approvals for that conversation and its delegates")
    func turningOnFlushesPendingApprovals() async throws {
        let root = try home(); defer { try? FileManager.default.removeItem(at: root) }
        let state = try makeState(root)
        let cid = state.createNewConversation(isBackground: false, select: true)
        let sub = state.createNewConversation(isSubagent: true, isBackground: false, select: false)
        state.linkDelegate(sub, of: cid)
        let other = state.createNewConversation(isBackground: false, select: false)

        let mainTask = Task { @MainActor in
            await state.enqueueUserApproval(toolName: "run_command", details: "echo 1", workspace: nil,
                                            conversationId: cid, origin: "Main agent")
        }
        let subTask = Task { @MainActor in
            await state.enqueueUserApproval(toolName: "write_file", details: "/tmp/a", workspace: nil,
                                            conversationId: sub, origin: "Subagent")
        }
        let otherTask = Task { @MainActor in
            await state.enqueueUserApproval(toolName: "run_command", details: "echo 2", workspace: nil,
                                            conversationId: other, origin: "Main agent")
        }

        for _ in 0..<200 where state.pendingApprovals.count < 3 {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        #expect(state.pendingApprovals.count == 3)

        state.sendMessage("/yolo on")
        #expect(try await value(of: mainTask) == true)
        #expect(try await value(of: subTask) == true)
        #expect(state.pendingApprovals.count == 1)
        #expect(state.pendingApprovals.first?.conversationId == other)

        state.denyPendingApprovals(for: other)
        _ = try await value(of: otherTask)
    }

    /// #1115 review: a humanOnly request already queued when `/yolo on` is clicked must stay
    /// queued, not be swept into the unfiltered `.approve` the flush used to apply to everything
    /// for the conversation and its delegates.
    @Test("Turning /yolo on does not flush a queued humanOnly request; an ordinary one still flushes")
    func turningOnDoesNotFlushHumanOnlyRequests() async throws {
        let root = try home(); defer { try? FileManager.default.removeItem(at: root) }
        let state = try makeState(root)
        let cid = state.createNewConversation(isBackground: false, select: true)
        let guestCid = state.createNewConversation(isSubagent: true, isBackground: false, select: false)
        state.linkDelegate(guestCid, of: cid)
        state.markGuestOriginTurn(guestCid)

        let ordinaryTask = Task { @MainActor in
            await state.enqueueUserApproval(toolName: "run_command", details: "echo 1", workspace: nil,
                                            conversationId: cid, origin: "Main agent")
        }
        let humanOnlyTask = Task { @MainActor in
            await state.enqueueUserApproval(toolName: "schedule_job", details: "name: test", workspace: nil,
                                            conversationId: cid, origin: "Main agent", humanOnly: true)
        }
        // #1115 review (dev-3 minor note): a queued #812 tainted-send request is ALSO humanOnly,
        // but carries offersConversationAllow, so it must flush unlike the plain humanOnly one
        // above -- pins the exception's own condition, not just `!req.humanOnly`.
        let taintedSendTask = Task { @MainActor in
            await state.enqueueUserApproval(toolName: "gmail_send_email", details: "to: a@b.com", workspace: nil,
                                            conversationId: cid, origin: "Main agent", humanOnly: true,
                                            offersConversationAllow: true)
        }
        // #1115 review (dev-2 non-blocking note): a queued request on a guest-origin turn is an
        // ordinary (not humanOnly) call, so only `isYoloMode(id)`'s own guest-origin check -- not
        // the humanOnly filter -- keeps it queued; without that check, this would flush like the
        // plain `cid` request above.
        let guestTask = Task { @MainActor in
            await state.enqueueUserApproval(toolName: "run_command", details: "echo 2", workspace: nil,
                                            conversationId: guestCid, origin: "Main agent")
        }
        for _ in 0..<200 where state.pendingApprovals.count < 4 {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        #expect(state.pendingApprovals.count == 4)

        state.sendMessage("/yolo on")
        #expect(try await value(of: ordinaryTask) == true, "the ordinary request still flushes")
        #expect(try await value(of: taintedSendTask) == true, "the #812 tainted-send exception still flushes")
        #expect(state.pendingApprovals.count == 2, "the humanOnly and guest-origin requests stay queued")
        #expect(state.pendingApprovals.contains { $0.humanOnly })
        #expect(state.pendingApprovals.contains { $0.conversationId == guestCid })

        for p in state.pendingApprovals { state.resolveApproval(id: p.id, .approve) }
        #expect(try await value(of: humanOnlyTask) == true)
        #expect(try await value(of: guestTask) == true)
    }

    /// #1232: #1228's reserved-gate tests (`yoloNeverBypassesHumanOnlyOrIrisWrite`) are all
    /// gate-function level -- a direct `state.requestApprovalSource(...)` call. This is the
    /// real-engine version: a YOLO-mode model turn whose tool call is a reserved write (a
    /// workspace `.iris/` write, #617) must still resolve through the person end to end -- the
    /// MODEL's call never auto-runs, the same way #1217's lesson says a direct-call test can pass
    /// while production serves the decision through a route the test never drove.
    @Test("a YOLO model turn's reserved write (.iris/) resolves through the person end to end, not auto-approved")
    func reservedWriteInAYoloModelTurnResolvesThroughThePerson() async throws {
        let root = try home(); defer { try? FileManager.default.removeItem(at: root) }
        let state = try makeState(root)
        let cid = state.createNewConversation(isBackground: false, select: true)
        state.setWorkspace(for: cid, path: root.path)
        state.sendMessage("/yolo on")

        let irisFile = root.appendingPathComponent(".iris/vibecop.md").path
        let callWrite = GeminiResponse(candidates: [Candidate(content: Content(
            role: "model", parts: [Part(functionCall: FunctionCall(
                name: "write_file", args: ["path": .string(irisFile), "content": .string("yolo write")], id: "c1"))]))], usageMetadata: nil)
        let doneText = GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [Part(text: "done")]))], usageMetadata: nil)
        let engine = IrisEngine(state: state, tier: .medium,
                                client: FakeLLMClient(responses: [callWrite, doneText]),
                                retryDelays: [], protectionEnabled: false, sessionPeerCount: 0)

        async let turn: Void = engine.processInput("update your vibecop notes", source: "UI", conversationId: cid)
        for _ in 0..<80 where state.pendingApprovals.isEmpty {
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        #expect(state.pendingApprovals.count == 1, "the model's .iris/ write must reach the queue despite YOLO")
        #expect(!FileManager.default.fileExists(atPath: irisFile), "must not run before the person decides")
        if let request = state.pendingApprovals.first {
            state.resolveApproval(id: request.id, .approve)
        }
        _ = await turn
        #expect(FileManager.default.fileExists(atPath: irisFile), "the approved click lets the write through")
        #expect((try? String(contentsOfFile: irisFile, encoding: .utf8)) == "yolo write")
    }

    /// dev-3 review of #1232/#1252: the `.iris/` case above only drives `irisWrite`. `policyWrite`
    /// and `humanOnly` are the OTHER two reserved classes in the same pre-YOLO check
    /// (`AppState.requestApprovalSource`), and dropping either from it is caught only by the old
    /// direct-gate test (#1228), not by the new engine-turn one -- each needs its own end-to-end
    /// drive, through the tool a model would actually call.
    @Test("a YOLO model turn's policy-store write (run_command) resolves through the person end to end")
    func policyWriteInAYoloModelTurnResolvesThroughThePerson() async throws {
        let root = try home(); defer { try? FileManager.default.removeItem(at: root) }
        let state = try makeState(root)
        let cid = state.createNewConversation(isBackground: false, select: true)
        state.setWorkspace(for: cid, path: root.path)
        state.sendMessage("/yolo on")

        // The real Iris home (`makeState`'s `paths.root`), not `root` itself -- a path spelled
        // under `root` directly also contains a literal ".iris"-looking component and would be
        // caught by `irisWrite` too, making the probe ambiguous about which check is doing the work.
        let profilePath = root.appendingPathComponent("iris-home/profiles/evil.json").path
        let callWrite = GeminiResponse(candidates: [Candidate(content: Content(
            role: "model", parts: [Part(functionCall: FunctionCall(
                name: "run_command", args: ["command": .string("echo x > \(profilePath)")], id: "c1"))]))], usageMetadata: nil)
        let doneText = GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [Part(text: "done")]))], usageMetadata: nil)
        let engine = IrisEngine(state: state, tier: .medium,
                                client: FakeLLMClient(responses: [callWrite, doneText]),
                                retryDelays: [], protectionEnabled: false, sessionPeerCount: 0)

        async let turn: Void = engine.processInput("plant a profile", source: "UI", conversationId: cid)
        for _ in 0..<80 where state.pendingApprovals.isEmpty {
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        #expect(state.pendingApprovals.count == 1, "the model's policy-store write must reach the queue despite YOLO")
        #expect(!FileManager.default.fileExists(atPath: profilePath), "must not run before the person decides")
        if let request = state.pendingApprovals.first {
            state.resolveApproval(id: request.id, .deny)
        }
        _ = await turn
        #expect(!FileManager.default.fileExists(atPath: profilePath), "a denied click never runs the write")
    }

    @Test("a YOLO model turn's job creation from Iris itself (schedule_job) resolves through the person end to end")
    func humanOnlyJobCreationInAYoloModelTurnResolvesThroughThePerson() async throws {
        let root = try home(); defer { try? FileManager.default.removeItem(at: root) }
        let state = try makeState(root)
        // #187 §7: an ordinary readOnly job from an ordinary conversation is NOT humanOnly at all
        // (JobToolsTests' own pinned/peer-touched/mutating conditions) -- the pinned "Iris"
        // conversation is the simplest of the three that makes schedule_job humanOnly.
        let cid = state.activityConversationId()
        state.setWorkspace(for: cid, path: root.path)
        // `sendMessage("/yolo on")` with no explicit target hits `selectedConversationId`, which
        // the pinned conversation is NOT by default -- turning YOLO on for the wrong conversation
        // made this test pass vacuously (the post-YOLO humanOnly check caught it regardless of
        // whether the pre-YOLO one did, since YOLO was never active for `cid` at all).
        state.selectedConversationId = cid
        state.sendMessage("/yolo on")

        let callSchedule = GeminiResponse(candidates: [Candidate(content: Content(
            role: "model", parts: [Part(functionCall: FunctionCall(
                name: "schedule_job", args: ["prompt": .string("sweep"), "intervalSeconds": .int(60)], id: "c1"))]))], usageMetadata: nil)
        let doneText = GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [Part(text: "done")]))], usageMetadata: nil)
        let engine = IrisEngine(state: state, tier: .medium,
                                client: FakeLLMClient(responses: [callSchedule, doneText]),
                                retryDelays: [], protectionEnabled: false, sessionPeerCount: 0)

        async let turn: Void = engine.processInput("schedule a sweep", source: "UI", conversationId: cid)
        for _ in 0..<80 where state.pendingApprovals.isEmpty {
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        #expect(state.pendingApprovals.count == 1, "the model's job creation must reach the queue despite YOLO")
        #expect(try state.store.ledger.jobs().isEmpty, "must not run before the person decides")
        if let request = state.pendingApprovals.first {
            state.resolveApproval(id: request.id, .approve)
        }
        _ = await turn
        #expect(try state.store.ledger.jobs().count == 1, "the approved click lets job creation through")
    }

    @Test("YOLO mode bypasses outboundGate and ContextHolds in tainted attended conversations")
    func bypassesOutboundGateAndContextHolds() async throws {
        let root = try home(); defer { try? FileManager.default.removeItem(at: root) }
        let state = try makeState(root)
        let cid = state.createNewConversation(isBackground: false, select: true)
        state.markConversationReadUntrusted(cid)
        state.sendMessage("/yolo on")

        let factStore = try FactStoreManager(inMemory: true)
        let callSaveFact = GeminiResponse(candidates: [Candidate(content: Content(
            role: "model", parts: [Part(functionCall: FunctionCall(name: "save_fact", args: ["content": .string("yolo fact")]))]))], usageMetadata: nil)
        let doneText = GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [Part(text: "done")]))], usageMetadata: nil)
        let engine = IrisEngine(state: state, tier: .medium,
                                client: FakeLLMClient(responses: [callSaveFact, doneText]),
                                retryDelays: [], factStore: factStore, protectionEnabled: false, sessionPeerCount: 0)

        // Outbound gate approves immediately with .yolo
        let outboundDecision = await engine.outboundGate(
            FunctionCall(name: "gmail_send_email", args: ["to": .string("a@b.com"), "subject": .string("hi"), "body": .string("yo")]),
            conversationId: cid, workspacePath: nil, isUnattended: false)
        #expect(outboundDecision == .approved(ToolApproval(layer: .yolo)))

        // ContextHolds does not hold save_fact in YOLO mode
        await engine.processInput("save it", source: "UI", conversationId: cid)
        #expect(state.pendingContextWrites.isEmpty)
        let saved = try factStore.search(query: "yolo")
        #expect(saved.count == 1)
    }

    /// #1115 review: the gate-script escalation is one of Brian's reserved humanOnly approvals,
    /// same class as `schedule_job` and a workspace `.iris/` write -- YOLO must still ask for it,
    /// not auto-approve it the way it auto-approves an ordinary command.
    @Test("GateScriptReview still asks in YOLO mode; approving the click still lets it through")
    func gateScriptReviewStillAsksInYolo() async throws {
        let root = try home(); defer { try? FileManager.default.removeItem(at: root) }
        let state = try makeState(root)
        let cid = state.createNewConversation(isBackground: false, select: true)
        state.sendMessage("/yolo on")

        let reviewer = IrisEngine.gateScriptReview(state: state, conversationId: cid, vibecopEnabled: false)
        async let outcome = reviewer.review(script: "echo CHANGED", mounts: [], timeoutSeconds: 10, network: false)
        for _ in 0..<40 where state.pendingApprovals.isEmpty {
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        #expect(state.pendingApprovals.count == 1, "the gate-script escalation must reach the queue despite YOLO")
        if state.pendingApprovals.isEmpty {
            state.denyPendingApprovals(for: cid)
        } else {
            state.resolveApproval(id: state.pendingApprovals[0].id, .approve)
        }
        switch await outcome {
        case .success: break
        case .failure(let msg): Issue.record("Expected the approved click to let the review through, got: \(msg.text)")
        }
    }

    @Test("YoloSynth generates stereo supersaw PCM buffers for Vengabus and power-down (#1104)")
    func synthGeneratesValidBuffers() {
        let vengabus = YoloSynth.makeVengabusBuffer()
        #expect(vengabus != nil)
        if let buffer = vengabus,
           let left = buffer.floatChannelData?[0],
           let right = buffer.floatChannelData?[1] {
            #expect(buffer.format.channelCount == 2)
            let count = Int(buffer.frameLength)
            #expect(count > 44100 * 3)
            var maxAmp: Float = 0
            var maxStereoDiff: Float = 0
            var allFinite = true
            for i in 0..<count {
                let l = left[i], r = right[i]
                if !l.isFinite || !r.isFinite { allFinite = false }
                maxAmp = max(maxAmp, max(abs(l), abs(r)))
                maxStereoDiff = max(maxStereoDiff, abs(l - r))
            }
            #expect(allFinite)
            #expect(maxAmp > 0.05 && maxAmp <= 0.26)
            #expect(maxStereoDiff > 0.02, "supersaw unison voices must spread across stereo L/R")
        }

        let powerDown = YoloSynth.makePowerDownBuffer()
        #expect(powerDown != nil)
        if let buffer = powerDown,
           let left = buffer.floatChannelData?[0],
           let right = buffer.floatChannelData?[1] {
            #expect(buffer.format.channelCount == 2)
            let count = Int(buffer.frameLength)
            #expect(count == Int(1.6 * 44100.0))
            var maxAmp: Float = 0
            var maxStereoDiff: Float = 0
            var allFinite = true
            for i in 0..<count {
                let l = left[i], r = right[i]
                if !l.isFinite || !r.isFinite { allFinite = false }
                maxAmp = max(maxAmp, max(abs(l), abs(r)))
                maxStereoDiff = max(maxStereoDiff, abs(l - r))
            }
            #expect(allFinite)
            #expect(maxAmp > 0.05 && maxAmp <= 0.36)
            #expect(maxStereoDiff > 0.02, "power-down chord brake must spread across stereo L/R")
        }
    }
}
