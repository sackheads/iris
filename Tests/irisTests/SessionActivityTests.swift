import Testing
import Foundation
@testable import iris

/// Pure mappings behind the session strip (#217 + #19): the tool-argument → activity-text
/// derivation and the token-count formatter. No SwiftUI here by design (AGENTS.md: no SwiftUI
/// unit tests) — everything the strip renders from is testable as plain functions.
@Suite("SessionActivity")
struct SessionActivityTests {
    @Test("run_command surfaces the command")
    func runCommand() {
        #expect(SessionActivity.detail(tool: "run_command", args: ["command": .string("swift test")]) == "swift test")
    }

    @Test("read_file surfaces the path's last two components")
    func readFile() {
        #expect(SessionActivity.detail(tool: "read_file", args: ["path": .string("Sources/iris/Foo.swift")]) == "iris/Foo.swift")
    }

    @Test("write_file surfaces the path's last two components")
    func writeFile() {
        #expect(SessionActivity.detail(tool: "write_file", args: ["path": .string("/a/b/c/d.txt")]) == "c/d.txt")
    }

    @Test("a path with one or two components is shown whole")
    func shortPath() {
        #expect(SessionActivity.detail(tool: "read_file", args: ["path": .string("foo.txt")]) == "foo.txt")
        #expect(SessionActivity.detail(tool: "read_file", args: ["path": .string("iris/foo.txt")]) == "iris/foo.txt")
    }

    @Test("search_memory surfaces the query")
    func searchMemory() {
        #expect(SessionActivity.detail(tool: "search_memory", args: ["query": .string("last deploy"), "scope": .string("all")]) == "last deploy")
    }

    @Test("subagent delegation tools surface the role")
    func delegation() {
        #expect(SessionActivity.detail(tool: "invoke_subagent", args: ["role": .string("code_reviewer"), "task": .string("review it")]) == "code_reviewer")
        #expect(SessionActivity.detail(tool: "delegate_milestone", args: ["role": .string("engineer")]) == "engineer")
    }

    @Test("an unrecognized tool falls back to the first string-valued argument, deterministically")
    func fallback() {
        #expect(SessionActivity.detail(tool: "some_new_tool", args: ["z_arg": .string("last"), "a_arg": .string("first")]) == "first")
    }

    @Test("a tool with no string argument has no detail")
    func noStringArg() {
        #expect(SessionActivity.detail(tool: "some_new_tool", args: ["count": .int(3)]) == nil)
        #expect(SessionActivity.detail(tool: "run_command", args: [:]) == nil)
    }

    @Test("detail is truncated to 60 characters")
    func truncation() {
        let long = String(repeating: "x", count: 90)
        let result = SessionActivity.detail(tool: "run_command", args: ["command": .string(long)])
        #expect(result?.count == 61)   // 60 chars + the ellipsis mark
        #expect(result?.hasSuffix("…") == true)
    }

    @Test("token count formatting")
    func tokenFormatting() {
        #expect(SessionActivity.formatTokenCount(0) == "0")
        #expect(SessionActivity.formatTokenCount(999) == "999")
        #expect(SessionActivity.formatTokenCount(4_200) == "4.2k")
        #expect(SessionActivity.formatTokenCount(210_900) == "210.9k")
        #expect(SessionActivity.formatTokenCount(1_300_000) == "1.3M")
    }
}

/// `AppState`'s session-tracking surface: `registerSubagent`, `updateSessionPhase`,
/// `finishSession`, and `visibleSessions`. Uses the isolated in-memory constructor (AGENTS.md
/// invariant 7) so nothing here touches `~/.iris`.
@MainActor
@Suite("AppState session tracking (#217 + #19)")
struct SessionTrackingTests {
    private func isolatedApp() -> AppState {
        AppState(store: try! ConversationStore.inMemory(), tier2Provisioning: .provisioned, tier3Provisioning: .provisioned)
    }

    @Test("registerSubagent adds a running session, defaulting to kind .subagent")
    func registerAdds() {
        let app = isolatedApp()
        let id = UUID()
        app.registerSubagent(id: id, role: "researcher")
        let session = app.sessions.first { $0.id == id }
        #expect(session?.kind == .subagent)
        #expect(session?.role == "researcher")
        #expect(session?.phase != nil)
        if case .finished = session?.phase { Issue.record("a freshly registered session must not start finished") }
    }

    @Test("registerSubagent(kind: .evaluator) is distinguishable from a plain subagent")
    func registerEvaluator() {
        let app = isolatedApp()
        let id = UUID()
        app.registerSubagent(id: id, role: "evaluator", kind: .evaluator)
        #expect(app.sessions.first { $0.id == id }?.kind == .evaluator)
    }

    @Test("updateSessionPhase changes the tracked phase and records lastActivity for .executing")
    func updatePhase() {
        let app = isolatedApp()
        let id = UUID()
        app.registerSubagent(id: id, role: "engineer")
        app.updateSessionPhase(id, .executing(tool: "run_command", detail: "swift build"))
        let session = app.sessions.first { $0.id == id }
        if case .executing(let tool, let detail) = session?.phase {
            #expect(tool == "run_command")
            #expect(detail == "swift build")
        } else {
            Issue.record("expected .executing")
        }
        #expect(session?.lastActivity == SessionSummary.LastActivity(tool: "run_command", detail: "swift build"))
    }

    @Test("finishSession marks the session finished with the given status and keeps it")
    func finish() {
        let app = isolatedApp()
        let id = UUID()
        app.registerSubagent(id: id, role: "engineer")
        app.finishSession(id: id, status: "completed")
        let session = app.sessions.first { $0.id == id }
        if case .finished(let status, _) = session?.phase {
            #expect(status == "completed")
        } else {
            Issue.record("expected .finished")
        }
    }

    @Test("visibleSessions puts the main session first and includes only subagent/evaluator kinds")
    func visibleSessionsOrdering() {
        let app = isolatedApp()
        let subagentId = UUID(), evaluatorId = UUID()
        app.registerSubagent(id: subagentId, role: "engineer")
        app.registerSubagent(id: evaluatorId, role: "evaluator", kind: .evaluator)
        let visible = app.visibleSessions
        #expect(visible.first?.kind == .main)
        #expect(visible.first?.role == "main")
        #expect(Set(visible.dropFirst().map(\.id)) == [subagentId, evaluatorId])
        #expect(visible.dropFirst().allSatisfy { $0.kind == .subagent || $0.kind == .evaluator })
    }
}

/// The linger sweep is a pure function over `[SessionSummary]` + `now` (AppState schedules it via
/// a `Task.sleep`, which is not itself worth testing) — this is what makes the 60s window testable
/// without sleeping in a test.
@Suite("SessionSummary.sweep")
struct SessionSweepTests {
    private func finished(_ at: Date) -> SessionSummary {
        SessionSummary(id: UUID(), kind: .subagent, role: "r", startTime: at, phase: .finished(status: "completed", at: at), lastActivity: nil)
    }
    private func running() -> SessionSummary {
        SessionSummary(id: UUID(), kind: .subagent, role: "r", startTime: Date(), phase: .thinking, lastActivity: nil)
    }

    @Test("drops a finished entry older than the linger window")
    func dropsOld() {
        let now = Date()
        let old = finished(now.addingTimeInterval(-61))
        let result = SessionSummary.sweep([old], now: now, lingerWindow: 60)
        #expect(result.isEmpty)
    }

    @Test("keeps a finished entry within the linger window")
    func keepsRecent() {
        let now = Date()
        let recent = finished(now.addingTimeInterval(-30))
        let result = SessionSummary.sweep([recent], now: now, lingerWindow: 60)
        #expect(result.count == 1)
    }

    @Test("never drops a running entry")
    func keepsRunning() {
        let now = Date()
        let result = SessionSummary.sweep([running()], now: now, lingerWindow: 60)
        #expect(result.count == 1)
    }
}

/// End-to-end through the engine: a scripted `run_command` call must leave the session's
/// `lastActivity` recording the tool and its detail. `lastActivity` (rather than asserting on
/// `phase` mid-call) is the seam #217/#19 needs, since by the time the turn returns the phase has
/// already moved on to `.thinking`/`.responding` for whatever round came after the tool call.
@MainActor
@Suite("executeToolWithHooks session activity (#217 + #19)")
struct ExecuteToolSessionActivityTests {
    private static func response(_ fc: FunctionCall?, text: String = "ok") -> GeminiResponse {
        let part = Part(text: fc == nil ? text : nil, functionCall: fc)
        return GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [part]))], usageMetadata: nil)
    }

    @Test("a scripted run_command call records lastActivity on the session")
    func recordsRunCommandActivity() async {
        let app = AppState(store: try! ConversationStore.inMemory(), tier2Provisioning: .provisioned, tier3Provisioning: .provisioned)
        app.autoApproveTools = true
        let id = UUID()
        app.createNewConversation(id: id, isSubagent: true)
        app.registerSubagent(id: id, role: "engineer")

        let call = FunctionCall(name: "run_command", args: ["command": .string("swift test")])
        let client = FakeLLMClient(responses: [Self.response(call), Self.response(nil)])
        let engine = IrisEngine(state: app, tier: .medium, principal: .subagent, client: client)
        await engine.processInput("go", source: "System", conversationId: id)

        let session = app.sessions.first { $0.id == id }
        #expect(session?.lastActivity == SessionSummary.LastActivity(tool: "run_command", detail: "swift test"))
    }
}
