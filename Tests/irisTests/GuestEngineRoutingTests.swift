import Testing
import Foundation
@testable import IrisKit

/// Polls on the main actor until `condition` holds, bounded on a clock that pauses with the Mac's sleep.
@MainActor
private func waitUntil(_ seconds: Double = 10, _ condition: @MainActor () -> Bool) async -> Bool {
    let deadline = TestClock.deadline(seconds)
    while !condition(), TestClock.now() < deadline { try? await Task.sleep(for: .milliseconds(10)) }
    return condition()
}

/// #1066 Phase 2, Task 3: a turn runs on the engine for its TARGET conversation, and no engine runs a
/// turn whose conversation disagrees with its principal. Before this, a peer message ran on the
/// SENDER's engine, so a role's reply to a guest would have run the guest's conversation under
/// `.main`, which is a way out of the guest's two-tool floor.
@MainActor
@Suite("Guest engine routing and the principal agreement check (#1066)", .timeLimit(.minutes(2)))
struct GuestEngineRoutingTests {
    /// An app with a main engine (`mainClient`), a role session, and a guest conversation with its
    /// own `.mcpGuest` engine (`guestClient`) registered for it.
    struct Fixture {
        let app: AppState
        let main: IrisEngine
        let guest: IrisEngine
        let mainClient: CapturingLLMClient
        let guestClient: CapturingLLMClient
        let roleId: UUID
        let guestId: UUID
    }

    private func fixture() -> Fixture {
        let app = AppState(store: try! ConversationStore.inMemory(), createIfEmpty: false, emitLaunchNotices: false)
        let mainClient = CapturingLLMClient(reply: "main")
        let guestClient = CapturingLLMClient(reply: "guest")
        let main = IrisEngine(state: app, tier: .medium, principal: .main, client: mainClient, retryDelays: [],
                              protectionEnabled: false, sessionPeerCount: 0)
        let guest = IrisEngine(state: app, tier: .medium, principal: .mcpGuest, client: guestClient, retryDelays: [],
                               protectionEnabled: false, sessionPeerCount: 0)
        app.installEngine(main)
        let roleId = app.createNewConversation(title: "role", select: false)
        let guestId = app.createNewConversation(isGuest: true, guestClientId: "dev-1", title: "guest")
        app.register(guestEngine: guest, for: guestId)
        return Fixture(app: app, main: main, guest: guest, mainClient: mainClient, guestClient: guestClient,
                       roleId: roleId, guestId: guestId)
    }

    private func envelope(_ id: String) -> PeerEnvelope {
        PeerEnvelope(msgId: id, contextId: "ctx-\(id)", depth: 1, expectsReply: false, replyTo: nil)
    }

    private func blockedLines(_ app: AppState, _ id: UUID) -> [String] {
        app.conversations.first { $0.id == id }?.messages.filter { $0.role == .system && $0.content.hasPrefix("[blocked]") }.map(\.content) ?? []
    }

    // MARK: the agreement check

    @Test("the check at the head of processInput refuses a disagreeing engine, in both directions, before any model call")
    func agreementRefuses() async {
        let f = fixture()
        await f.main.processInput("hi", source: "UI", conversationId: f.guestId)
        #expect(f.mainClient.requests.isEmpty, "a main engine ran a guest conversation")
        #expect(blockedLines(f.app, f.guestId).first?.contains(IrisEngine.principalMismatchRefusal) == true)

        await f.guest.processInput("hi", source: "UI", conversationId: f.roleId)
        #expect(f.guestClient.requests.isEmpty, "a guest engine ran a role's conversation")
        #expect(blockedLines(f.app, f.roleId).first?.contains(IrisEngine.principalMismatchRefusal) == true)

        await f.guest.processInput("hi", source: "UI", conversationId: UUID())
        #expect(f.guestClient.requests.isEmpty, "a guest engine runs no turn on a conversation that does not exist")
    }

    @Test("agreeing pairs run: a guest engine on a guest conversation, a main engine on a main one")
    func agreementAllowsAgreeing() async {
        let f = fixture()
        await f.guest.processInput("hi", source: "UI", conversationId: f.guestId)
        await f.main.processInput("hi", source: "UI", conversationId: f.roleId)
        #expect(f.guestClient.requests.count == 1)
        #expect(f.mainClient.requests.count == 1)
    }

    // MARK: routing: idle path

    @Test("a role's reply to an idle guest runs on the guest's engine, not the sender's")
    func roleToGuestIdle() async {
        let f = fixture()
        let outcome = await f.main.deliverPeerMessage("an answer", from: f.roleId, senderName: "role", to: f.guestId, envelope: envelope("aaaa0001"))
        #expect(outcome == .delivered)
        #expect(await waitUntil { f.guestClient.requests.count == 1 })
        #expect(f.mainClient.requests.isEmpty, "the sender's engine ran the guest's turn")
        #expect(blockedLines(f.app, f.guestId).isEmpty)
    }

    @Test("a guest's message to an idle role session runs the role's turn on the main engine")
    func guestToRoleIdle() async {
        let f = fixture()
        let outcome = await f.guest.deliverPeerMessage("a question", from: f.guestId, senderName: "guest", to: f.roleId, envelope: envelope("aaaa0002"))
        #expect(outcome == .delivered)
        #expect(await waitUntil { f.mainClient.requests.count == 1 })
        #expect(f.guestClient.requests.isEmpty, "the guest's engine ran a role session's turn")
        #expect(blockedLines(f.app, f.roleId).isEmpty)
    }

    // MARK: routing: busy path and the stored engine

    @Test("busy path: a queued arrival for a guest is run by the guest's engine when its turn ends; for a role, by main")
    func busyPathRouting() async {
        let f = fixture()
        f.app.beginEngineTurn(for: f.guestId)
        let queued = await f.main.deliverPeerMessage("late answer", from: f.roleId, senderName: "role", to: f.guestId, envelope: envelope("bbbb0001"))
        #expect(queued == .queued)
        f.app.endEngineTurn(for: f.guestId)
        #expect(await waitUntil { f.guestClient.requests.count == 1 })
        #expect(f.mainClient.requests.isEmpty)

        f.app.beginEngineTurn(for: f.roleId)
        let queued2 = await f.guest.deliverPeerMessage("late question", from: f.guestId, senderName: "guest", to: f.roleId, envelope: envelope("bbbb0002"))
        #expect(queued2 == .queued)
        f.app.endEngineTurn(for: f.roleId)
        #expect(await waitUntil { f.mainClient.requests.count == 1 })
        #expect(f.guestClient.requests.count == 1, "unchanged: the guest's engine did not run the role's turn")
    }

    @Test("the stored-engine site: a system event queued with the SENDER's engine runs on the target's engine")
    func storedEngineOverridden() async {
        let f = fixture()
        // From a main engine to a guest target.
        f.app.beginEngineTurn(for: f.guestId)
        f.app.enqueuePendingSystemEvent("event for the guest", source: "Test", for: f.guestId, engine: f.main)
        f.app.endEngineTurn(for: f.guestId)
        #expect(await waitUntil { f.guestClient.requests.count == 1 })
        #expect(f.mainClient.requests.isEmpty)

        // From a guest engine to a role target.
        f.app.beginEngineTurn(for: f.roleId)
        f.app.enqueuePendingSystemEvent("event for the role", source: "Test", for: f.roleId, engine: f.guest)
        f.app.endEngineTurn(for: f.roleId)
        #expect(await waitUntil { f.mainClient.requests.count == 1 })
        #expect(f.guestClient.requests.count == 1)
    }

    @Test("a guest conversation with no registered engine runs no turn, and says so, rather than falling back to main")
    func noEngineNoTurn() async {
        let f = fixture()
        f.app.unregisterGuestEngine(for: f.guestId)
        #expect(f.app.engine(forTurnOn: f.guestId, caller: f.main) == nil)
        let outcome = await f.main.deliverPeerMessage("an answer", from: f.roleId, senderName: "role", to: f.guestId, envelope: envelope("cccc0001"))
        #expect(outcome == .delivered)
        #expect(await waitUntil { !blockedLines(f.app, f.guestId).isEmpty })
        #expect(f.mainClient.requests.isEmpty && f.guestClient.requests.isEmpty)
    }

    @Test("a guest conversation never reflects or auto-renames from the composer's counters")
    func guestNeverReflects() async {
        let f = fixture()
        if let idx = f.app.conversations.firstIndex(where: { $0.id == f.guestId }) {
            f.app.conversations[idx].messageCountSinceReflection = 29
        }
        f.app.beginEngineTurn(for: f.guestId)
        _ = await f.main.deliverPeerMessage("an answer", from: f.roleId, senderName: "role", to: f.guestId, envelope: envelope("dddd0001"))
        f.app.endEngineTurn(for: f.guestId)
        #expect(await waitUntil { f.guestClient.requests.count == 1 })
        #expect(f.app.conversations.first { $0.id == f.guestId }?.messageCountSinceReflection == 30,
                "reached the reflection threshold without resetting it: no reflection ran")
    }

    // MARK: behaviour preserved for everything that is not a guest

    @Test("non-guest delivery is unchanged: the caller's own engine runs the target's turn; no caller means the main engine")
    func nonGuestIdentity() {
        let f = fixture()
        let other = IrisEngine(state: f.app, tier: .medium, principal: .main, client: CapturingLLMClient(), retryDelays: [],
                               protectionEnabled: false, sessionPeerCount: 0)
        #expect(f.app.engine(forTurnOn: f.roleId, caller: other) === other)
        #expect(f.app.engine(forTurnOn: f.roleId, caller: f.main) === f.main)
        #expect(f.app.engine(forTurnOn: f.roleId, caller: nil) === f.main)
        let sub = IrisEngine(state: f.app, tier: .medium, principal: .subagent, client: CapturingLLMClient(), retryDelays: [])
        #expect(f.app.engine(forTurnOn: f.roleId, caller: sub) === sub, "a subagent caller is not rerouted")
        #expect(f.app.engine(forTurnOn: f.guestId, caller: nil) === f.guest)
        #expect(f.app.engine(forTurnOn: f.roleId, caller: f.guest) === f.main)
    }

    @Test("role-to-role peer delivery runs on the sender's engine, exactly as before")
    func roleToRoleUnchanged() async {
        let f = fixture()
        let second = CapturingLLMClient(reply: "second")
        let secondEngine = IrisEngine(state: f.app, tier: .medium, principal: .main, client: second, retryDelays: [],
                                      protectionEnabled: false, sessionPeerCount: 0)
        let target = f.app.createNewConversation(title: "other role", select: false)
        let outcome = await secondEngine.deliverPeerMessage("hello", from: f.roleId, senderName: "role", to: target, envelope: envelope("eeee0001"))
        #expect(outcome == .delivered)
        #expect(await waitUntil { second.requests.count == 1 })
        #expect(f.mainClient.requests.isEmpty, "the sender's own engine ran it, as it always did")
    }

    @Test("a user-typed turn runs on the main engine")
    func userTypedUnchanged() async {
        let f = fixture()
        f.app.selectedConversationId = f.roleId
        f.app.sendMessage("hello there")
        #expect(await waitUntil { f.mainClient.requests.count >= 1 })
        #expect(f.guestClient.requests.isEmpty)
    }

    @Test("a guest inherits no /yolo from the host session: its own conversation is never YOLO and its approvals are denied")
    func guestGetsNoYolo() async {
        let f = fixture()
        f.app.setYoloMode(true, for: f.roleId)
        #expect(f.app.isYoloMode(f.roleId), "the fixture is real: the host session has YOLO on")
        #expect(!f.app.isYoloMode(f.guestId))
        // A guest cannot be switched on either: YOLO is for a user-facing session.
        f.app.setYoloMode(true, for: f.guestId)
        #expect(!f.app.isYoloMode(f.guestId))
        // And an approval asked for from the guest's conversation is refused, not waved through.
        let granted = await f.app.requestApproval(toolName: "run_command", details: "ls", conversationId: f.guestId, origin: "MCP guest")
        #expect(!granted)
        // The routed turn runs on the guest engine, which has none of the host's approval state.
        _ = await f.main.deliverPeerMessage("an answer", from: f.roleId, senderName: "role", to: f.guestId, envelope: envelope("ffff0001"))
        #expect(await waitUntil { f.guestClient.requests.count == 1 })
        let names = f.guestClient.requests.first?.tools?.flatMap { $0.functionDeclarations.map(\.name) } ?? []
        #expect(Set(names) == ["send_to_session", "list_sessions"], "the guest floor, with the host in YOLO")
    }

    @Test("deleting a guest conversation drops its engine registration")
    func deleteDropsRegistration() {
        let f = fixture()
        #expect(f.app.guestEngines[f.guestId] != nil)
        f.app.deleteConversation(f.guestId)
        #expect(f.app.guestEngines[f.guestId] == nil)
    }
}

/// Not `@MainActor`: a scan of the sources is heavy synchronous work (AGENTS.md).
@Suite("Every turn entry point is pinned (#1066)")
struct ProcessInputCallSitesTests {
    private static let sources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources")

    /// Non-comment lines in `Sources/` that mention `name` as a whole word (so `processInput` is not
    /// matched inside `processInputBody`), excluding its declaration, by file. Deliberately not
    /// "name followed by an open paren": an alias (`let run = engine.processInput`) or a call split
    /// before the paren would hide from that.
    private func sites(_ name: String, declaration: String) throws -> [String: Int] {
        let word = try NSRegularExpression(pattern: "\\b\(NSRegularExpression.escapedPattern(for: name))\\b")
        var counts: [String: Int] = [:]
        let files = FileManager.default.enumerator(at: Self.sources, includingPropertiesForKeys: nil)!
        for case let url as URL in files where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                let string = String(line)
                if trimmed.hasPrefix("//") || line.contains(declaration) { continue }
                if word.firstMatch(in: string, range: NSRange(string.startIndex..., in: string)) == nil { continue }
                counts[url.lastPathComponent, default: 0] += 1
            }
        }
        return counts
    }

    /// The reviewed list. Each is a way a turn starts, and why it cannot start one a guest's engine
    /// or a guest's conversation should not: `IrisEngine.processInput` checks principal against
    /// conversation at its head, so a site that reaches the wrong engine is refused there; and the
    /// peer-delivery and drain sites route by the target (`AppState.engine(forTurnOn:caller:)`).
    /// Adding a call site fails this test on purpose: decide how it is routed, then update it.
    @Test("the production call sites of processInput are exactly the reviewed ones")
    func processInputCallSites() throws {
        let expected: [String: Int] = [
            "AppState.swift": 11,           // drain (system event), startTurn x3, goal reprompt/kickoff/skill check, /init, /new, rename, draft
            "ConversationRotation.swift": 1, // reflection: on a user conversation, main engine
            "GoalEvaluator.swift": 1,        // a fresh evaluator engine on its own evaluator conversation
            "JobRunner.swift": 1,            // a job run's own conversation, main engine
            "ScenarioRunner.swift": 1,       // headless scenarios
            "SubagentManager.swift": 1,      // a subagent engine on its own conversation
            "iris.swift": 5,                 // deliverSanitizedSystemEvent (routed), budget stop, skill check, reprompt, loop tick (own conversation)
        ]
        #expect(try sites("processInput", declaration: "func processInput(") == expected)
    }

    @Test("the stored-engine site: enqueuePendingSystemEvent callers are exactly the two reviewed ones")
    func enqueueSystemEventCallSites() throws {
        #expect(try sites("enqueuePendingSystemEvent", declaration: "func enqueuePendingSystemEvent(") == ["iris.swift": 2])
    }

    @Test("processInputBody has exactly one caller: processInput itself")
    func processInputBodyHasOneCaller() throws {
        #expect(try sites("processInputBody", declaration: "func processInputBody(") == ["iris.swift": 1])
    }
}
