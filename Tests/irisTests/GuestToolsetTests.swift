import Testing
import Foundation
@testable import IrisKit

/// #1066 Phase 2, Task 2: a guest's whole tool surface is `send_to_session` and `list_sessions`,
/// and it holds on every path a tool can take: the request the model is sent, the hook that may
/// rewrite it, and the dispatcher that runs a call. These drive the real engine, not the list
/// builder alone: asserting against `guestToolDeclarations()` would pass whatever else
/// `buildRequest` appended after it.
@MainActor
@Suite("MCP guest tool floor (#1066)", .timeLimit(.minutes(2)))
struct GuestToolsetTests {
    private let floor: Set<String> = ["send_to_session", "list_sessions"]

    private func guestApp() -> (AppState, UUID) {
        let app = AppState(store: try! ConversationStore.inMemory(), createIfEmpty: false, emitLaunchNotices: false)
        let id = app.createNewConversation(isGuest: true, guestClientId: "dev-1", title: "guest")
        return (app, id)
    }

    /// A hook manager whose BeforeToolSelection returns `tools` (JSON) in place of the list.
    private func hooks(returning json: String) throws -> (HookManager, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("iris-1066-hook-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let config = dir.appendingPathComponent("settings.json")
        let command = "printf '%s' '\(json)'"
        let body = """
        {"hooks":{"BeforeToolSelection":[{"matcher":".*","hooks":[{"type":"command","command":\(String(data: try JSONEncoder().encode(command), encoding: .utf8)!)}]}]}}
        """
        try body.write(to: config, atomically: true, encoding: .utf8)
        var manager = HookManager()
        manager.configPathOverride = config.path
        return (manager, dir)
    }

    /// One turn on `principal`'s engine over `id`, every gate that can add a tool switched on:
    /// state-gated tools declared, peers present, a sticky set naming `run_command`. Returns the
    /// names the first request declared.
    private func declared(principal: Principal, app: AppState, id: UUID, hooks: HookManager = .shared) async -> [String] {
        app.stickyTools.record(["run_command", "send_to_session", "inbox_item"], for: id)
        let client = CapturingLLMClient(reply: "ok")
        let engine = IrisEngine(state: app, tier: .medium, principal: principal, client: client, retryDelays: [],
                                protectionEnabled: false, sessionPeerCount: 3, declareStateGatedTools: true,
                                stickyTools: true, hooks: hooks)
        await engine.processInput("hello", source: "UI", conversationId: id)
        return client.requests.first?.tools?.flatMap { $0.functionDeclarations.map(\.name) } ?? []
    }

    // MARK: the request

    @Test("the request a guest is sent declares exactly the two-tool floor, with every gate on")
    func requestDeclaresOnlyTheFloor() async {
        let (app, id) = guestApp()
        let names = await declared(principal: .mcpGuest, app: app, id: id)
        #expect(Set(names) == floor)
        #expect(names.count == 2, "each tool once")
    }

    @Test("the same setup on a main conversation still declares the full surface")
    func mainStillFull() async {
        let app = AppState(store: try! ConversationStore.inMemory(), createIfEmpty: false, emitLaunchNotices: false)
        let id = app.createNewConversation(title: "main")
        let names = Set(await declared(principal: .main, app: app, id: id))
        #expect(names.contains("run_command") && names.contains("read_file") && names.isSuperset(of: floor))
        #expect(names.count > 10, "a vacuous main list would make the guest assertion above meaningless")
    }

    /// A hook config that appends the event name and its stdin to one file for every event the
    /// manager can fire.
    private static let events = ["BeforeTool", "AfterTool", "BeforeAgent", "BeforeModel", "AfterModel",
                                 "BeforeToolSelection", "PreCompress", "Notification", "SessionStart", "AfterAgent"]

    private func recordingHooks() throws -> (HookManager, URL, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("iris-1066-hooks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let log = dir.appendingPathComponent("fired.log")
        let entries = try Self.events.map { event -> String in
            let command = "{ printf '%s ' '\(event)'; cat; echo; } >> '\(log.path)'; printf ''"
            let encoded = String(data: try JSONEncoder().encode(command), encoding: .utf8)!
            return "\"\(event)\":[{\"matcher\":\".*\",\"hooks\":[{\"type\":\"command\",\"command\":\(encoded)}]}]"
        }.joined(separator: ",")
        let config = dir.appendingPathComponent("settings.json")
        try "{\"hooks\":{\(entries)}}".write(to: config, atomically: true, encoding: .utf8)
        var manager = HookManager(); manager.configPathOverride = config.path
        return (manager, dir, log)
    }

    private func fired(_ log: URL) -> [String] {
        ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").compactMap { $0.split(separator: " ").first.map(String.init) }
    }

    @Test("the inert hook manager fires none of the ten events, and the same config fires them on a normal manager")
    func inertManagerFiresNothing() async throws {
        let (live, dir, log) = try recordingHooks()
        defer { try? FileManager.default.removeItem(at: dir) }
        var inert = HookManager.inert; inert.configPathOverride = live.configPathOverride

        func fireAll(_ m: HookManager) async {
            _ = await m.fireBeforeTool(toolName: "t", args: [:]); _ = await m.fireAfterTool(toolName: "t", result: "r")
            _ = await m.fireBeforeAgent(input: "i"); _ = await m.fireAfterAgent(output: "o")
            _ = await m.fireBeforeModel(request: GeminiRequest(contents: [], systemInstruction: nil, tools: nil))
            _ = await m.fireAfterModel(response: GeminiResponse(candidates: [], usageMetadata: nil))
            _ = await m.fireBeforeToolSelection(tools: []); _ = await m.firePreCompress(history: [])
            await m.fireNotification(title: "t", body: "b"); _ = await m.fireSessionStart(conversationId: UUID())
        }
        await fireAll(inert)
        #expect(fired(log).isEmpty, "inert manager ran \(fired(log))")
        await fireAll(live)
        #expect(Set(fired(log)) == Set(Self.events), "the fixture must fire every event on a live manager: \(fired(log))")
    }

    @Test("a guest turn fires none of the owner's hooks, even when the owner's manager is passed in; a main turn fires them")
    func guestTurnFiresNoHooks() async throws {
        let (manager, dir, log) = try recordingHooks()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (app, id) = guestApp()
        let names = await declared(principal: .mcpGuest, app: app, id: id, hooks: manager)
        #expect(fired(log).isEmpty, "the owner's hooks ran on a guest turn: \(fired(log))")
        #expect(Set(names) == floor)

        let mainApp = AppState(store: try ConversationStore.inMemory(), createIfEmpty: false, emitLaunchNotices: false)
        let mainId = mainApp.createNewConversation(title: "main")
        _ = await declared(principal: .main, app: mainApp, id: mainId, hooks: manager)
        #expect(fired(log).contains("BeforeAgent") && fired(log).contains("BeforeModel"), "fixture is real: \(fired(log))")
    }

    @Test("creating a guest conversation fires no SessionStart; creating a normal one does")
    func guestCreationFiresNoSessionStart() async throws {
        let (manager, dir, log) = try recordingHooks()
        defer { try? FileManager.default.removeItem(at: dir) }
        let app = AppState(store: try ConversationStore.inMemory(), createIfEmpty: false, emitLaunchNotices: false)
        app.sessionStartHooks = manager
        let guest = app.createNewConversation(isGuest: true, guestClientId: "dev-1", title: "guest")
        let normal = app.createNewConversation(title: "normal")
        // The normal conversation's SessionStart runs on a Task; wait for it (bounded): the guest's would have run by then too.
        let deadline = TestClock.deadline(10)
        while !((try? String(contentsOf: log, encoding: .utf8))?.contains(normal.uuidString) ?? false), TestClock.now() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        #expect(text.contains(normal.uuidString), "fixture is real")
        #expect(!text.contains(guest.uuidString), "SessionStart fired for a guest")
    }

    @Test("a guest's own declarations: role-only addressing, no attachments, and not the main path's schema")
    func declarationsAreTheGuests() {
        let guest = IrisEngine.guestToolDeclarations()
        #expect(guest.map(\.name) == ["list_sessions", "send_to_session"])
        let send = guest.first { $0.name == "send_to_session" }
        #expect(Set(send?.parameters?.properties?.keys.map { $0 } ?? []) == ["to", "message", "in_reply_to", "expects_reply"])
        #expect(send?.parameters?.properties?["attachments"] == nil, "a guest's model is never offered a file path to read")
        #expect(send?.parameters?.properties?["to"]?.description?.contains("role:<name>") == true)
        #expect(send?.parameters?.properties?["to"]?.description?.contains("session_id") == false)
        #expect(Set(GuestToolset.sendArguments) == Set(send?.parameters?.properties?.keys.map { $0 } ?? []),
                "the dispatch allowlist and the declared schema are the same set")
        #expect(GuestToolset.allowedNames == floor)
    }

    // MARK: dispatch

    private func result(of name: String, args: [String: JSONValue] = [:], guest: Bool = true) async -> (String, AppState) {
        let (app, id) = guestApp()
        let first = GeminiResponse(candidates: [Candidate(content: Content(
            role: "model", parts: [Part(functionCall: FunctionCall(name: name, args: args, id: "c1"))]))], usageMetadata: nil)
        let final = GeminiResponse(candidates: [Candidate(content: Content(
            role: "model", parts: [Part(text: "ok")]))], usageMetadata: nil)
        let engine = IrisEngine(state: app, tier: .medium, principal: .mcpGuest,
                                client: FakeLLMClient(responses: [first, final]), retryDelays: [],
                                protectionEnabled: false, sessionPeerCount: 0)
        await engine.processInput("go", source: "UI", conversationId: id)
        let history = app.conversations.first { $0.id == id }?.history ?? []
        let text = history.flatMap { $0.parts }.compactMap { part -> String? in
            guard case .string(let s)? = part.functionResponse?.response["result"] else { return nil }
            return s
        }.last ?? ""
        return (text, app)
    }

    @Test("a guest's call to any tool outside the floor is refused before a handler runs",
          arguments: ["run_command", "read_file", "write_file", "search_web", "inbox_item", "describe_session",
                      "invoke_subagent", "schedule_job", "register_directory_watcher", "manage_fact",
                      "set_workspace", "propose_goal_contract", "goal_complete", "set_alarm", "set_session_card",
                      "close_request", "list_jobs", "read_conversation", "search_conversations"])
    func outsideTheFloorRefused(name: String) async {
        let (text, _) = await result(of: name, args: ["command": .string("touch /tmp/iris-1066-should-not-exist"),
                                                      "path": .string("/tmp/iris-1066-nope"), "query": .string("x")])
        #expect(text == GuestToolset.refusal(for: name), "\(name): \(text)")
        #expect(!FileManager.default.fileExists(atPath: "/tmp/iris-1066-should-not-exist"))
    }

    @Test("a guest's send_to_session carrying attachments (or any argument its schema lacks) is refused before the handler")
    func guestSendArgumentsRefused() async throws {
        let secret = FileManager.default.temporaryDirectory.appendingPathComponent("iris-1066-secret-\(UUID().uuidString).txt")
        try "host secret".write(to: secret, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: secret) }
        let attachments = JSONValue.array([.object(["path": .string(secret.path)])])
        let (text, _) = await result(of: "send_to_session",
                                     args: ["to": .string("role:reviewer"), "message": .string("hi"), "attachments": attachments])
        #expect(text == GuestToolset.argumentRefusal("attachments"))
        let (other, _) = await result(of: "send_to_session",
                                      args: ["to": .string("role:reviewer"), "message": .string("hi"), "topic": .string("x")])
        #expect(other == GuestToolset.argumentRefusal("topic"))
    }

    @Test("a guest's floor tools are refused for now: no session is reachable until the role allowlist (Task 5)")
    func floorToolsReachNothingYet() async {
        for name in ["send_to_session", "list_sessions"] {
            let (text, app) = await result(of: name, args: ["to": .string("iris"), "message": .string("hi")])
            #expect(text.hasPrefix("Refused"), "\(name): \(text)")
            #expect(app.conversations.filter { !$0.isGuest }.allSatisfy { $0.messages.isEmpty }, "nothing was delivered anywhere")
        }
    }

    // MARK: the other principal branches

    @Test("a guest's sandbox decision is sandboxed whatever the other inputs say")
    func sandboxAlwaysSandboxed() {
        for pref in [nil, SandboxPref.host, .sandboxed] {
            for global in [SandboxPref.host, .sandboxed] {
                let d = SandboxPolicy.resolve(masterEnabled: true, principal: .mcpGuest, perConversation: pref,
                                              perWorkspace: pref, globalDefault: global, runtimeAvailable: true)
                #expect(d == .sandboxed)
            }
        }
    }

    @Test("an approval request from a guest conversation is denied with no dialog and no blocked-call record")
    func approvalDeniedSilently() async {
        let (app, id) = guestApp()
        // Auto-approve is on, so a request that reached the ladder would be granted: only the guest
        // refusal at its head can make this answer no.
        app.autoApproveTools = true
        let granted = await app.requestApproval(toolName: "run_command", details: "ls", conversationId: id, origin: "MCP guest")
        #expect(!granted)
        #expect(app.pendingApprovals.isEmpty, "no dialog was raised")
        #expect(app.conversations.first { $0.id == id }?.messages.isEmpty == true)
    }

    @Test("a guest never gets a prompt-cache hour, and a non-main principal keeps the standard TTL")
    func cachePolicyStandard() {
        let ttl = CacheTTLPolicy.resolve(isPinned: true, isUnattended: false, principal: .mcpGuest, backgroundFiresHourly: true)
        #expect(ttl == .standard)
    }
}
