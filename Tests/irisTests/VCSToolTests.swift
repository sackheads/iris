import Testing
import Foundation
@testable import IrisKit

/// #1435 slice 1: `vcs`, who may call it, what a role's session may open a PR from, the protected paths, and the
/// taint gate on its writes (planner's rulings on #1435).
@Suite("vcs tool (#1435 slice 1)")
struct VCSToolTests {
    // MARK: who calls

    @Test("a .main session with a role acts under its role; the owner's own attended turn under the owner policy; nobody else")
    func callers() {
        #expect(VCSTool.caller(principal: .main, guestOrigin: false, role: "pilot", ownerAttended: false) == .role("pilot"))
        #expect(VCSTool.caller(principal: .main, guestOrigin: false, role: "pilot", ownerAttended: true) == .role("pilot"))
        #expect(VCSTool.caller(principal: .main, guestOrigin: false, role: nil, ownerAttended: true) == .owner)
        #expect(VCSTool.caller(principal: .main, guestOrigin: false, role: nil, ownerAttended: false) == nil)
        #expect(VCSTool.caller(principal: .main, guestOrigin: false, role: "Not A Role!", ownerAttended: false) == nil,
                "a role that doesn't normalise is no role")
        #expect(VCSTool.caller(principal: .main, guestOrigin: true, role: "pilot", ownerAttended: true) == nil)
        for principal in [Principal.subagent, .evaluator, .mcpGuest, .broker] {
            #expect(VCSTool.caller(principal: principal, guestOrigin: false, role: "pilot", ownerAttended: true) == nil, "\(principal)")
        }
    }

    @Test("a role opens PRs only from its own prefix; the owner from anything but main", arguments: [
        ("agent/pilot/fix-1", true, true), ("agent/pilot/", false, false), ("agent/other/fix", false, true),
        ("feature-x", false, true), ("main", false, false), ("agent/pilot/a/b", true, true),
    ])
    func headRules(_ head: String, _ roleOK: Bool, _ ownerOK: Bool) {
        #expect((VCSTool.Caller.role("pilot").headRefusal(head) == nil) == roleOK, Comment(rawValue: head))
        #expect((VCSTool.Caller.owner.headRefusal(head) == nil) == ownerOK, Comment(rawValue: head))
    }

    @Test("a branch name is one plain spelling", arguments: [
        "-x", "/x", "x/", "a..b", "a//b", "x.lock", "x.", "a/.hidden", "a b", "a~1", "a^", "a:b", "a@{1}", "a\\b",
        "a\u{0}b", String(repeating: "a", count: 101), "",
    ])
    func badBranchNames(_ name: String) {
        #expect(!VCSTool.isBranchName(name), Comment(rawValue: name))
        #expect(VCSTool.Caller.owner.headRefusal(name) != nil)
    }

    // MARK: the taint gate (planner, #1435)

    @Test("a write on a tainted conversation runs only on the owner's attended turn; reads always run")
    func taintGate() {
        for action in VCSTool.Action.allCases {
            #expect(VCSTool.taintRefusal(action, tainted: false, ownerAttended: false) == nil, "\(action) clean, unattended")
            #expect(VCSTool.taintRefusal(action, tainted: true, ownerAttended: true) == nil, "\(action) tainted, attended")
            #expect((VCSTool.taintRefusal(action, tainted: true, ownerAttended: false) != nil) == action.writes, "\(action) tainted, unattended")
        }
    }

    /// The planner's placeholder: slice 2's `push` (and anything else added) is a write unless it is one of the
    /// known reads, so it can't ship outside the taint gate.
    @Test("every action but the known reads is a write")
    func everythingButReadsWrites() {
        let reads: Set<String> = ["pr_view", "pr_checks", "fetch"]
        for action in VCSTool.Action.allCases {
            #expect(action.writes == !reads.contains(action.rawValue), "\(action.rawValue)")
        }
        if let push = VCSTool.Action(rawValue: "push") { #expect(push.writes) }
    }

    @Test("a fetch taints when it brings someone else's code: another role's branch, a PR head, or any branch the owner fetches; main and a role's own don't (planner, #1435)")
    func fetchTaintTable() {
        let pilot = VCSTool.Caller.role("pilot")
        #expect(!VCSTool.fetchTaints(branch: nil, pr: nil, caller: pilot))
        #expect(!VCSTool.fetchTaints(branch: "main", pr: nil, caller: pilot))
        #expect(!VCSTool.fetchTaints(branch: "agent/pilot/x", pr: nil, caller: pilot))
        #expect(!VCSTool.fetchTaints(branch: "main", pr: nil, caller: .owner))
        for branch in ["agent/author/x", "feature", "agent/pilot", "dependabot/npm/x"] {
            #expect(VCSTool.fetchTaints(branch: branch, pr: nil, caller: pilot), Comment(rawValue: branch))
        }
        #expect(VCSTool.fetchTaints(branch: nil, pr: 7, caller: pilot) && VCSTool.fetchTaints(branch: nil, pr: 7, caller: .owner))
        #expect(VCSTool.fetchTaints(branch: "agent/pilot/x", pr: nil, caller: .owner), "the owner's fetch of any branch is someone else's")
    }

    @Test("a fetch from a repository off the allowlist sends nothing: the mirror isn't made")
    func refusedFetchRunsNothing() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("iris-vcsf-\(UUID().uuidString)")
        let mirror = VCSMirror(root: root, remoteURL: { _ in "/nonexistent" }, credentialConfig: [])
        let client = GitHubProxyClient(keychain: KeychainManager(serviceSuffix: ".test-\(UUID().uuidString)"), isRepoAllowed: { _ in false })
        let result = await VCSTool.$caller.withValue(.role("pilot")) {
            await VCSTool.execute(args: ["action": .string("fetch"), "repo": .string("a/b"), "branch": .string("agent/other/x")],
                                  client: client, workspace: NSTemporaryDirectory(), mirror: mirror)
        }
        #expect(result.contains("not allowed"), Comment(rawValue: result))
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test("only pr_view's and pr_checks' results taint; a write's and fetch's don't")
    func resultTaint() {
        for action in VCSTool.Action.allCases {
            let taints = IrisEngine.resultCarriesOutsideContent(VCSTool.name, args: ["action": .string(action.rawValue)])
            #expect(taints == ["pr_view", "pr_checks"].contains(action.rawValue), "\(action)")
        }
        #expect(IrisEngine.resultCarriesOutsideContent(VCSTool.name, args: [:]), "no action: taints, the safe side")
    }

    // MARK: the client, behind a recording transport

    final class Recorder: GitHubTransport, @unchecked Sendable {
        struct Sent { let method: String; let path: String; let body: [String: Any] }
        private let lock = NSLock()
        private var _sent: [Sent] = []
        var sent: [Sent] { lock.withLock { _sent } }
        let files: [[String: Any]]
        let draft: Bool
        init(files: [[String: Any]] = [["filename": "Sources/x.swift"]], draft: Bool = true) { self.files = files; self.draft = draft }
        func send(_ request: URLRequest, bearer: String) async throws -> (Data, HTTPURLResponse) {
            let body = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any] ?? [:]
            let path = request.url?.path ?? ""
            lock.withLock { _sent.append(Sent(method: request.httpMethod ?? "", path: path, body: body)) }
            let sha = String(repeating: "a", count: 40)
            let reply: [String: Any]
            if path.contains("/compare/") {
                reply = ["files": files]
            } else if path.hasSuffix("/check-runs") {
                reply = ["check-runs": [["name": "test", "status": "completed", "conclusion": "success"]]]
            } else if request.httpMethod == "GET" {
                reply = ["number": 9, "title": "A title", "state": "open", "draft": draft, "body": "line one\nline two",
                         "node_id": "PR_kwDOTest9",
                         "html_url": "https://github.com/sackheads/iris/pull/9",
                         "head": ["ref": "agent/pilot/x", "sha": sha], "base": ["ref": "main", "sha": sha]]
            } else {
                reply = ["number": 9, "html_url": "https://github.com/sackheads/iris/pull/9"]
            }
            let data = try JSONSerialization.data(withJSONObject: reply)
            return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
    }

    private func client(_ recorder: Recorder) -> GitHubProxyClient {
        let keychain = KeychainManager(serviceSuffix: ".test-\(UUID().uuidString)")
        keychain.replaceSecrets(["token": "ghp_TestToken1234567890abcdef"], service: KeychainManager.githubService)
        return GitHubProxyClient(keychain: keychain, isRepoAllowed: { $0 == "sackheads/iris" }, transport: recorder)
    }

    private func policy(_ contents: String?) throws -> VCSPolicyStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("iris-vcs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("vcs-policy.json")
        if let contents { try Data(contents.utf8).write(to: file) }
        return VCSPolicyStore(file: file)
    }

    private func create(_ caller: VCSTool.Caller?, head: String, base: String? = nil, recorder: Recorder,
                        policy: VCSPolicyStore) async -> String {
        var args: [String: JSONValue] = ["action": .string("pr_create"), "repo": .string("sackheads/iris"),
                                         "head": .string(head), "title": .string("t"), "body": .string("b")]
        if let base { args["base"] = .string(base) }
        let client = client(recorder)
        return await VCSTool.$caller.withValue(caller) { await VCSTool.execute(args: args, client: client, policy: policy) }
    }

    @Test("pr_create checks the branch's files first, then opens a draft into main")
    func createOpensADraftIntoMain() async throws {
        let recorder = Recorder()
        let result = await create(.role("pilot"), head: "agent/pilot/x", recorder: recorder, policy: try policy(nil))
        #expect(result.contains("#9"), Comment(rawValue: result))
        #expect(recorder.sent.map(\.method) == ["GET", "POST"])
        #expect(recorder.sent.first?.path == "/repos/sackheads/iris/compare/main...agent/pilot/x")
        let post = try #require(recorder.sent.last)
        #expect(post.path == "/repos/sackheads/iris/pulls")
        #expect(post.body["head"] as? String == "agent/pilot/x" && post.body["base"] as? String == "main")
        #expect(post.body["draft"] as? Bool == true)
    }

    @Test("a protected path in the branch, or a rename out of one, refuses the PR before it's opened", arguments: [
        ["filename": ".github/workflows/test.yml"], ["filename": ".github/actions/setup/action.yml"], ["filename": "CODEOWNERS"], ["filename": "docs/specs/x.md"],
        ["filename": ".GitHub/Workflows/x.yml"], ["filename": "docs/x.md", "previous_filename": "docs/plans/x.md"],
    ])
    func protectedPathRefuses(_ file: [String: String]) async throws {
        let recorder = Recorder(files: [["filename": "Sources/a.swift"], file])
        let result = await create(.owner, head: "feature", recorder: recorder, policy: try policy(nil))
        #expect(result.contains("protected path"), Comment(rawValue: result))
        #expect(!recorder.sent.contains { $0.method == "POST" })
    }

    @Test("nothing is sent for a head outside the role's prefix, a base that isn't main, no caller, or an unreadable policy",
          arguments: ["prefix", "base", "no caller", "policy"])
    func refusalsSendNothing(_ label: String) async throws {
        let recorder = Recorder()
        let result: String
        switch label {
        case "prefix": result = await create(.role("pilot"), head: "agent/other/x", recorder: recorder, policy: try policy(nil))
        case "base": result = await create(.owner, head: "feature", base: "release", recorder: recorder, policy: try policy(nil))
        case "no caller": result = await create(nil, head: "feature", recorder: recorder, policy: try policy(nil))
        default: result = await create(.owner, head: "feature", recorder: recorder, policy: try policy("{not json"))
        }
        #expect(result.hasPrefix("Refused") || result == VCSTool.noCallerRefusal, Comment(rawValue: result))
        #expect(recorder.sent.isEmpty, "\(label): \(recorder.sent.map(\.path))")
    }

    @Test("a policy file names its own protected paths; a missing one is the defaults")
    func policyFile() throws {
        guard case .policy(let defaults) = try policy(nil).load() else { Issue.record("missing file isn't the defaults"); return }
        #expect(defaults == .defaults && defaults.protects(".github/workflows/x.yml") && !defaults.protects("Sources/x.swift"))
        guard case .policy(let custom) = try policy(#"{"protectedPaths":["secret/"]}"#).load() else { Issue.record("didn't decode"); return }
        #expect(custom.protects("secret/a") && !custom.protects(".github/workflows/x.yml"))
        #expect(try policy(#"{"protectedPaths":"nope"}"#).load() == .unreadable)
    }

    @Test("pr_ready: a role never readies its own PR, by its head branch; it readies a peer's, and the owner any (Brian, #1435 F4)")
    func readyRule() {
        #expect(VCSTool.readyRefusal(head: "agent/pilot/x", caller: .role("pilot")) != nil)
        #expect(VCSTool.readyRefusal(head: "agent/author/x", caller: .role("pilot")) == nil)
        #expect(VCSTool.readyRefusal(head: "feature", caller: .role("pilot")) == nil)
        #expect(VCSTool.readyRefusal(head: "agent/pilot/x", caller: .owner) == nil)
    }

    private func ready(_ caller: VCSTool.Caller, recorder: Recorder) async -> String {
        let c = client(recorder)
        return await VCSTool.$caller.withValue(caller) {
            await VCSTool.execute(args: ["action": .string("pr_ready"), "repo": .string("sackheads/iris"), "pr": .int(9)], client: c)
        }
    }

    @Test("pr_ready on the session's own PR sends no write; on a peer's it marks it ready through GraphQL with the PR's id")
    func readyThroughTheClient() async throws {
        let own = Recorder()
        let refused = await ready(.role("pilot"), recorder: own)   // the stub PR's head is agent/pilot/x
        #expect(refused.contains("this session's own"), Comment(rawValue: refused))
        #expect(own.sent.allSatisfy { $0.method == "GET" })

        let peer = Recorder()
        let done = await ready(.role("reviewer"), recorder: peer)
        #expect(done.contains("ready for review"), Comment(rawValue: done))
        let post = try #require(peer.sent.last)
        #expect(post.method == "POST" && post.path == "/graphql")
        #expect((post.body["variables"] as? [String: Any])?["id"] as? String == "PR_kwDOTest9")
        #expect((post.body["query"] as? String)?.contains("markPullRequestReadyForReview") == true)
    }

    @Test("pr_ready on a PR that's already ready writes nothing")
    func readyAlready() async {
        let recorder = Recorder(draft: false)
        let result = await ready(.owner, recorder: recorder)
        #expect(result.contains("already ready"), Comment(rawValue: result))
        #expect(recorder.sent.allSatisfy { $0.method == "GET" })
    }

    @Test("pr_view shows the PR and its description; pr_checks one line per check")
    func viewAndChecks() async {
        let recorder = Recorder()
        let c = client(recorder)
        let view = await VCSTool.$caller.withValue(.role("pilot")) {
            await VCSTool.execute(args: ["action": .string("pr_view"), "repo": .string("sackheads/iris"), "pr": .int(9)], client: c)
        }
        #expect(view.contains("#9 A title [draft, open] agent/pilot/x -> main") && view.contains("line one\nline two"), Comment(rawValue: view))
        let checks = await VCSTool.$caller.withValue(.role("pilot")) {
            await VCSTool.execute(args: ["action": .string("pr_checks"), "repo": .string("sackheads/iris"), "pr": .int(9)], client: c)
        }
        #expect(checks.contains("test: success"), Comment(rawValue: checks))
        #expect(recorder.sent.allSatisfy { $0.method == "GET" })
    }
}

/// #1435: real turns through the dispatcher: who is offered `vcs`, and the planner's taint rows.
@MainActor
@Suite("vcs tool: dispatch (#1435 slice 1)", .timeLimit(.minutes(1)))
struct VCSToolDispatchTests {
    struct Shape {
        var role: String? = nil
        var background = false
        var tainted = false
        var peerInput = false
        var guestOrigin = false
        var principal: Principal = .main
        var source = "UI"
    }

    private func app(_ shape: Shape) -> (AppState, UUID) {
        let app = AppState()
        app.conversations.removeAll()
        let id = UUID()
        app.createNewConversation(id: id)
        if let idx = app.conversations.firstIndex(where: { $0.id == id }) {
            app.conversations[idx].role = shape.role
            app.conversations[idx].isBackground = shape.background
            app.conversations[idx].hasUntrustedToolOutput = shape.tainted
            app.conversations[idx].hasPeerInput = shape.peerInput
        }
        if shape.guestOrigin { app.markGuestOriginTurn(id) }
        return (app, id)
    }

    /// One turn where the model calls `vcs` with `action`, returning what the dispatcher gave it.
    private func dispatch(_ action: String, _ shape: Shape) async throws -> String {
        let (app, id) = app(shape)
        var args: [String: JSONValue] = ["action": .string(action), "repo": .string("sackheads/iris"), "pr": .int(5), "body": .string("hi")]
        if action == "pr_create" { args["head"] = .string("agent/pilot/x"); args["title"] = .string("t") }
        if action == "push" { args["branch"] = .string("agent/pilot/x") }
        let call = FunctionCall(name: VCSTool.name, args: args)
        let part = Part(text: nil, functionCall: call, functionResponse: nil, thought_signature: nil, thoughtSignature: nil)
        let client = FakeLLMClient(responses: [
            GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [part]))], usageMetadata: nil),
            GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [Part(text: "understood")]))], usageMetadata: nil),
        ])
        let engine = IrisEngine(state: app, tier: .medium, principal: shape.principal, client: client, retryDelays: [],
                                protectionEnabled: false, sessionPeerCount: 0, githubToolsEnabled: true)
        let turn = Task { await engine.processInput("go", source: shape.source, conversationId: id) }
        try await value(of: turn)
        let responses = app.conversations.first { $0.id == id }?.history.flatMap { $0.parts }.compactMap { $0.functionResponse } ?? []
        return responses.compactMap { $0.response["result"]?.stringValue }.joined(separator: "\n")
    }

    private func refusedForTaint(_ result: String) -> Bool { result.contains("has read outside text") }
    /// Got past every gate to the client, which refuses the repo: the test's allowlist is empty.
    private func reachedClient(_ result: String) -> Bool { result.contains("not allowed") }

    @Test("an unattended tainted pr_comment is refused; it says why and who can run it")
    func unattendedTaintedRefused() async throws {
        let result = try await dispatch("pr_comment", Shape(role: "pilot", background: true, tainted: true))
        #expect(refusedForTaint(result) && result.contains("needs the user"), Comment(rawValue: result))
    }

    @Test("the owner's own attended tainted pr_comment runs")
    func attendedTaintedRuns() async throws {
        let result = try await dispatch("pr_comment", Shape(tainted: true))
        #expect(!refusedForTaint(result) && reachedClient(result), Comment(rawValue: result))
    }

    @Test("an unattended clean pr_comment runs")
    func unattendedCleanRuns() async throws {
        let result = try await dispatch("pr_comment", Shape(role: "pilot", background: true))
        #expect(!refusedForTaint(result) && reachedClient(result), Comment(rawValue: result))
    }

    @Test("a peer-started turn in a tainted .main conversation is not the owner's: its pr_comment is refused")
    func peerStartedTaintedRefused() async throws {
        let result = try await dispatch("pr_comment", Shape(role: "pilot", tainted: true, peerInput: true))
        #expect(refusedForTaint(result), Comment(rawValue: result))
    }

    @Test("a loop tick, an alarm or an answer in a tainted conversation isn't the owner's turn: its writes are refused, in the owner's own conversation and in a role's (dev-2's and dev-3's reviews)",
          arguments: [IrisEngine.loopSource, IrisEngine.systemSource, IrisEngine.inboxAnswerSource], ["pr_comment", "pr_create"])
    func nonTypedTurnTaintedRefused(_ source: String, _ action: String) async throws {
        let result = try await dispatch(action, Shape(tainted: true, source: source))
        #expect(!reachedClient(result), Comment(rawValue: result))
        let roleResult = try await dispatch(action, Shape(role: "pilot", tainted: true, source: source))
        #expect(refusedForTaint(roleResult), Comment(rawValue: roleResult))
    }

    @Test("a tick in the owner's own clean conversation with no role has no caller: the owner policy is for typed turns")
    func tickHasNoOwnerCaller() async throws {
        let result = try await dispatch("pr_view", Shape(source: IrisEngine.loopSource))
        #expect(!reachedClient(result), Comment(rawValue: result))
        #expect(!(await offered(Shape(source: IrisEngine.loopSource))).contains(VCSTool.name))
        #expect(await offered(Shape(role: "pilot", source: IrisEngine.loopSource)).contains(VCSTool.name))
    }

    @Test("push is under the taint gate: refused unattended or peer-started on a tainted conversation, run on the owner's typed turn (planner, #1435 slice 2)")
    func pushUnderTaintGate() async throws {
        let unattended = try await dispatch("push", Shape(role: "pilot", background: true, tainted: true))
        #expect(refusedForTaint(unattended), Comment(rawValue: unattended))
        let peer = try await dispatch("push", Shape(role: "pilot", tainted: true, peerInput: true))
        #expect(refusedForTaint(peer), Comment(rawValue: peer))
        let tick = try await dispatch("push", Shape(role: "pilot", tainted: true, source: IrisEngine.loopSource))
        #expect(refusedForTaint(tick), Comment(rawValue: tick))
        let typed = try await dispatch("push", Shape(tainted: true))
        #expect(!refusedForTaint(typed) && reachedClient(typed), Comment(rawValue: typed))
    }

    @Test("an unattended tainted pr_view still runs: it's a read")
    func taintedReadRuns() async throws {
        let result = try await dispatch("pr_view", Shape(role: "pilot", background: true, tainted: true))
        #expect(!refusedForTaint(result) && reachedClient(result), Comment(rawValue: result))
    }

    @Test("a background run with no role has no caller")
    func noRoleUnattendedRefused() async throws {
        let result = try await dispatch("pr_view", Shape(background: true))
        #expect(!reachedClient(result), Comment(rawValue: result))
    }

    /// The tool names a real turn declares.
    private func offered(_ shape: Shape) async -> [String] {
        let (app, id) = app(shape)
        let client = CapturingLLMClient(reply: "ok")
        let engine = IrisEngine(state: app, tier: .medium, principal: shape.principal, client: client, retryDelays: [],
                                sessionPeerCount: 0, githubToolsEnabled: true)
        await engine.processInput("hello", source: shape.source, conversationId: id)
        return client.requests.first?.tools?.flatMap { $0.functionDeclarations.map(\.name) } ?? []
    }

    @Test("vcs is offered to a role's session, attended or not, and to the owner's attended turn; to nobody else")
    func whoIsOffered() async {
        #expect(await offered(Shape(role: "pilot", background: true)).contains(VCSTool.name))
        #expect(await offered(Shape(role: "pilot")).contains(VCSTool.name))
        #expect(await offered(Shape()).contains(VCSTool.name))
        for (label, shape) in [("background, no role", Shape(background: true)), ("guest-origin", Shape(role: "pilot", guestOrigin: true)),
                               ("peer-started, no role", Shape(peerInput: true)), ("subagent", Shape(role: "pilot", principal: .subagent))] {
            let names = await offered(shape)
            #expect(!names.contains(VCSTool.name), "\(label)")
            #expect(names.contains("run_command"), "\(label): the turn did declare tools")
        }
    }
}
