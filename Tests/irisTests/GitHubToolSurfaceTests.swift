import Testing
import Foundation
@testable import IrisKit

/// #966 Task 5: how the three `github_*` tools reach (and do not reach) the model. Declared only
/// when the `iris-main` token is present, to the attended main agent only, refused by the dispatcher
/// for every other caller, and outside the outbound-taint gate and a read-only job's allowlist.
@MainActor
@Suite("GitHub tool surface (#966 Task 5)", .timeLimit(.minutes(1)))
struct GitHubToolSurfaceTests {
    static let names = ["github_create_pr", "github_comment", "github_approve"]

    // MARK: declaration

    @Test("the three tools are declared only when the token is present")
    func gatedOnTheToken() async {
        let without = await ToolExecutor.shared.getTools(workspaceToolsEnabled: false, githubToolsEnabled: false).map(\.name)
        let with = await ToolExecutor.shared.getTools(workspaceToolsEnabled: false, githubToolsEnabled: true).map(\.name)
        for name in Self.names {
            #expect(!without.contains(name), Comment(rawValue: name))
            #expect(with.contains(name), Comment(rawValue: name))
        }
        #expect(without.contains("run_command") && with.contains("run_command"))
        #expect(Set(Self.names) == ToolExecutor.githubProxyTools)
    }

    @Test("a plain turn with no token carries none of them")
    func plainTurnCarriesNone() async {
        let app = AppState()
        let id = UUID()
        app.createNewConversation(id: id)
        let client = CapturingLLMClient(reply: "ok")
        let engine = IrisEngine(state: app, tier: .medium, principal: .main, client: client, retryDelays: [], sessionPeerCount: 0)
        await engine.processInput("hello", source: "UI", conversationId: id)
        let offered = client.requests.first?.tools?.flatMap { $0.functionDeclarations.map(\.name) } ?? []
        for name in Self.names { #expect(!offered.contains(name), Comment(rawValue: name)) }
    }

    @Test("an attended main turn keeps them; every other principal and an unattended turn lose them")
    func hardStripKeepsThemForAttendedMainOnly() async {
        let all = await ToolExecutor.shared.getTools(workspaceToolsEnabled: false, githubToolsEnabled: true)
        let kept = Set(IrisEngine.hardStrip(all, isUnattended: false, principal: .main).map(\.name))
        for name in Self.names { #expect(kept.contains(name), Comment(rawValue: name)) }
        for principal in [Principal.subagent, .evaluator, .mcpGuest] {
            let stripped = Set(IrisEngine.hardStrip(all, isUnattended: false, principal: principal).map(\.name))
            for name in Self.names { #expect(!stripped.contains(name), "\(name) for \(principal)") }
        }
        let unattended = Set(IrisEngine.hardStrip(all, isUnattended: true, principal: .main).map(\.name))
        for name in Self.names { #expect(!unattended.contains(name), "\(name) for an unattended turn") }
    }

    @Test("both gating sets name all three, so a sticky or stale declaration cannot offer them")
    func gatingSetsNameThem() {
        for name in Self.names {
            #expect(IrisEngine.mainOnlyDeclared.contains(name), Comment(rawValue: name))
            #expect(IrisEngine.unattendedNeverDeclared.contains(name), Comment(rawValue: name))
        }
    }

    // MARK: dispatch

    @Test("the dispatcher refuses every caller but an attended main turn", arguments: Self.names)
    func dispatchRefusalByPrincipal(_ name: String) {
        #expect(IrisEngine.githubDispatchRefusal(name, isUnattended: false, principal: .main) == nil)
        for principal in [Principal.subagent, .evaluator, .mcpGuest] {
            #expect(IrisEngine.githubDispatchRefusal(name, isUnattended: false, principal: principal) == IrisEngine.githubOffPrincipalRefusal)
        }
        #expect(IrisEngine.githubDispatchRefusal(name, isUnattended: true, principal: .main) == IrisEngine.githubOffPrincipalRefusal)
        #expect(IrisEngine.githubDispatchRefusal("run_command", isUnattended: true, principal: .subagent) == nil)
    }

    /// One turn in a conversation where the model calls `call`, returning what the dispatcher gave it.
    private func dispatchResult(for call: FunctionCall, principal: Principal, background: Bool) async throws -> String {
        let app = AppState()
        app.conversations.removeAll()
        let id = UUID()
        app.createNewConversation(id: id)
        if background, let idx = app.conversations.firstIndex(where: { $0.id == id }) {
            app.conversations[idx].isBackground = true
        }
        let part = Part(text: nil, functionCall: call, functionResponse: nil, thought_signature: nil, thoughtSignature: nil)
        let client = FakeLLMClient(responses: [
            GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [part]))], usageMetadata: nil),
            GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [Part(text: "understood")]))], usageMetadata: nil),
        ])
        let engine = IrisEngine(state: app, tier: .medium, principal: principal, client: client,
                                retryDelays: [], protectionEnabled: false, sessionPeerCount: 0)
        let turnTask = Task { await engine.processInput("go", source: "UI", conversationId: id) }
        let denyTask = Task {
            while !Task.isCancelled {
                if !app.pendingApprovals.isEmpty { app.denyPendingApprovals(for: id); break }
                try? await Task.sleep(nanoseconds: 25_000_000)
            }
        }
        try await value(of: turnTask)
        denyTask.cancel()
        let responses = app.conversations.first { $0.id == id }?.history.flatMap { $0.parts }.compactMap { $0.functionResponse } ?? []
        return responses.compactMap { $0.response["result"]?.stringValue }.joined(separator: "\n")
    }

    private func approveCall() -> FunctionCall {
        FunctionCall(name: "github_approve", args: ["repo": .string("sackheads/iris"), "pr": .int(5)])
    }

    @Test("a forged github_approve from a subagent is refused by the dispatcher")
    func subagentCallRefused() async throws {
        let result = try await dispatchResult(for: approveCall(), principal: .subagent, background: false)
        #expect(result.contains(IrisEngine.githubOffPrincipalRefusal))
    }

    @Test("a github_comment from an unattended (background) main turn is refused by the dispatcher")
    func unattendedCallRefused() async throws {
        let call = FunctionCall(name: "github_comment", args: ["repo": .string("sackheads/iris"), "pr": .int(5), "body": .string("hi")])
        let result = try await dispatchResult(for: call, principal: .main, background: true)
        #expect(result.contains(IrisEngine.githubOffPrincipalRefusal))
    }

    // MARK: outbound gate, read-only jobs

    @Test("they are not in OutboundTools.builtIn: the specific controls replace the taint gate", arguments: Self.names)
    func exemptFromTheOutboundGate(_ name: String) {
        #expect(!OutboundTools.isOutbound(name, readOnlyMCPTools: []))
        #expect(!OutboundTools.builtIn.contains(name))
    }

    @Test("a read-only job is denied all three", arguments: Self.names)
    func readOnlyJobDenied(_ name: String) {
        #expect(JobProfile.readOnlyDenies(name, sandboxedRunCommand: false, readOnlyMCPTools: []))
        #expect(JobProfile.readOnlyDenies(name, sandboxedRunCommand: true, readOnlyMCPTools: []))
    }

    // MARK: execute() wiring

    @Test("execute reaches the client, which refuses a repo that is not on the (empty) allowlist, before any network")
    func executeReachesTheClientAndItsAllowlist() async {
        let executor = ToolExecutor.shared
        let create = await executor.execute(name: "github_create_pr", args: [
            "repo": .string("sackheads/iris"), "head": .string("h"), "base": .string("main"),
            "title": .string("t"), "body": .string("b")])
        let comment = await executor.execute(name: "github_comment", args: [
            "repo": .string("sackheads/iris"), "pr": .int(7), "body": .string("b")])
        let approve = await executor.execute(name: "github_approve", args: ["repo": .string("sackheads/iris"), "pr": .int(7)])
        for result in [create, comment, approve] { #expect(result.contains("not allowed"), Comment(rawValue: result)) }
    }

    @Test("a pr number may arrive as an int, a whole double or a numeric string; anything else is an error",
          arguments: [(JSONValue.int(7), true), (.double(7), true), (.string("7"), true), (.string(" 7 "), true),
                      (.int(0), false), (.int(-2), false), (.double(7.5), false), (.string("seven"), false),
                      (.bool(true), false), (.null, false)])
    func prNumberForms(_ value: JSONValue, _ ok: Bool) async {
        let result = await ToolExecutor.shared.execute(name: "github_approve", args: ["repo": .string("sackheads/iris"), "pr": value])
        if ok { #expect(result.contains("not allowed")) } else { #expect(result.hasPrefix("Error:")) }
    }

    @Test("missing arguments are an error, not a request", arguments: [
        ("github_create_pr", ["repo": JSONValue.string("a/b")]),
        ("github_comment", ["pr": JSONValue.int(1)]),
        ("github_approve", ["pr": JSONValue.int(1)]),
    ])
    func missingArguments(_ name: String, _ args: [String: JSONValue]) async {
        let result = await ToolExecutor.shared.execute(name: name, args: args)
        #expect(result.hasPrefix("Error:"))
    }

    @Test("draft is true unless the model sends an explicit false",
          arguments: [(JSONValue?.none, true), (.some(.bool(true)), true), (.some(.bool(false)), false),
                      (.some(.string("false")), true), (.some(.null), true), (.some(.int(0)), true)])
    func draftDefaultsToTrue(_ value: JSONValue?, _ expected: Bool) {
        #expect(ToolExecutor.githubDraftFlag(value) == expected)
    }

    @Test("the declaration tells the model the default")
    func declarationNamesTheDraftDefault() {
        let create = ToolExecutor.githubToolDeclarations.first { $0.name == "github_create_pr" }
        #expect(create?.description.contains("draft true") == true)
    }
}
