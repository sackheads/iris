import Foundation
import Testing
@testable import IrisKit

/// #1146 (#1057 PR B): the conversation-scoped Diagnostics view's figures, per model and per turn,
/// built from the stored ledger and turn list and never from today's price list.
@MainActor
@Suite("Conversation cost report (#1146)", .timeLimit(.minutes(1)))
struct ConversationCostReportTests {
    private let book = PriceBook.snapshotOnly
    // Snapshot: haiku-5-5 $0.10 in / $0.50 out per MTok; sonnet-5-5 $2 in / $10 out.
    private func rate(_ model: String) -> ResolvedRate { book.resolve(family: "anthropic", model: model, side: .primary) }
    private func call(_ prompt: Int, _ output: Int = 0) -> UsageMetadata {
        UsageMetadata(promptTokenCount: prompt, candidatesTokenCount: output, totalTokenCount: prompt + output)
    }
    private func spend(_ u: inout TokenUsage, _ c: UsageMetadata, model: String = "claude-haiku-5-5", turn: Int?) {
        u.add(c)
        u.record(c, provider: "Anthropic", model: model, rate: rate(model), turn: turn)
    }
    private func report(_ u: TokenUsage, model: String = "claude-sonnet-5-5") -> ConversationCostReport {
        let cost = ConversationCost.estimate(usage: u, provider: "Anthropic", model: model, book: book)
        return ConversationCostReport.make(usage: u, cost: cost)
    }

    @Test("per-model rows and per-turn rows both add up to the figure")
    func reconciles() {
        var u = TokenUsage()
        u.add(call(1_000_000))                                                    // no model: $2.00 at the current model
        spend(&u, call(1_000_000, 200_000), turn: 1)                              // haiku 0.10 + 0.10
        spend(&u, call(1_000_000, 100_000), model: "claude-sonnet-5-5", turn: 2)  // sonnet 2.00 + 1.00
        let r = report(u)
        #expect(r.models.map(\.model) == ["claude-haiku-5-5", "claude-sonnet-5-5", "Not attributed to a model"])
        #expect(abs(r.models[0].dollars - 0.2) < 1e-9 && abs(r.models[1].dollars - 3.0) < 1e-9 && abs(r.models[2].dollars - 2.0) < 1e-9)
        #expect(abs(r.models.reduce(0) { $0 + $1.dollars } - r.total) < 1e-9)
        #expect(abs(r.turns.reduce(0) { $0 + $1.dollars } + r.notShown - r.total) < 1e-9)
        #expect(r.turns.map(\.turn) == [1, 2])
    }

    @Test("a model's tokens are the sum of what its rows bill")
    func modelTokens() {
        var u = TokenUsage()
        spend(&u, call(100, 10), turn: 1)
        spend(&u, call(200, 20), turn: 2)
        #expect(report(u).models.first?.tokens == 330)
    }

    @Test("a conversation with no ledger shows no rows and says why, at the current model")
    func noLedger() {
        var u = TokenUsage()
        u.add(call(1_000_000))
        let r = report(u)
        #expect(r.models.isEmpty && r.turns.isEmpty)
        #expect(abs(r.total - 2.0) < 1e-9)
        #expect(r.notes.contains { $0.contains("no per-model record") && $0.contains("claude-sonnet-5-5") })
    }

    @Test("turns the cap dropped are named in a note, with the dollars they hold")
    func capNote() {
        var u = TokenUsage()
        for t in 1...(TokenUsage.maxTurns + 5) { spend(&u, call(1_000_000), turn: t) }
        let r = report(u, model: "claude-haiku-5-5")
        #expect(r.turns.count == TokenUsage.maxTurns)
        #expect(abs(r.notShown - 0.5) < 1e-9)
        #expect(r.notes.contains { $0.contains("$0.5000") && $0.contains("\(TokenUsage.maxTurns)") })
    }

    @Test("a ledger with no turn entries says turns were not recorded, rather than showing an empty list silently")
    func ledgerWithoutTurns() {
        var u = TokenUsage()
        let c = call(1_000_000)
        u.add(c)
        u.record(c, provider: "Anthropic", model: "claude-haiku-5-5", rate: rate("claude-haiku-5-5"), turn: nil)
        let r = report(u, model: "claude-haiku-5-5")
        #expect(r.turns.isEmpty && r.models.count == 1)
        #expect(r.notes.contains { $0.contains("not recorded per turn") })
    }

    @Test("nothing to note when every dollar is on a shown turn")
    func quietWhenComplete() {
        var u = TokenUsage()
        spend(&u, call(100, 10), turn: 1)
        #expect(report(u, model: "claude-haiku-5-5").notes.isEmpty)
    }

    @Test("a stored rate is kept when the price list moves")
    func storedRate() {
        var u = TokenUsage()
        let spentAt = ResolvedRate(rates: TokenRates(input: 1e-6, output: 2e-6, cacheRead: 0), source: .settings, asOf: nil, estimated: false)
        let c = call(1_000_000)
        u.add(c)
        u.record(c, provider: "Anthropic", model: "claude-haiku-5-5", rate: spentAt, turn: 1)
        let r = report(u, model: "claude-haiku-5-5")
        #expect(abs(r.models[0].dollars - 1.0) < 1e-9 && abs(r.turns[0].dollars - 1.0) < 1e-9)
    }
}

/// The wiring a unit test cannot drive: the popover's button reaches the Diagnostics window's mode.
/// Source scans, in a suite that is not `@MainActor` (a scan is heavy synchronous work).
@Suite("Conversation cost Diagnostics wiring (#1146)", .timeLimit(.minutes(1)))
struct ConversationCostWiringTests {
    private func source(_ name: String) throws -> String {
        let url = PerfPaths.repoRoot().appendingPathComponent("Sources/IrisKit/\(name)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test("the cost popover names its conversation, counts the ask and opens the Diagnostics window")
    func popoverOpensConversationMode() throws {
        let chat = try source("ChatView.swift")
        let at = try #require(chat.range(of: "Per-turn view in Diagnostics"))
        let block = String(chat[at.lowerBound...].prefix(400))
        #expect(block.contains("state.diagnosticsConversationId = conv.id"))
        #expect(block.contains("state.diagnosticsRequest += 1"))
        #expect(block.contains("openWindow(id: \"diagnostics\")"))
    }

    @Test("the Diagnostics window has the mode, switches to it on an ask, and takes the request once")
    func windowTakesTheRequest() throws {
        let view = try source("DiagnosticsView.swift")
        #expect(view.contains("case conversation = \"Conversation\""))
        #expect(view.contains("ConversationCostDiagnosticsView(state: state, conversationId: conversationId)"))
        #expect(view.contains(".onAppear(perform: takeConversationRequest)"))
        #expect(view.contains(".onChange(of: state?.diagnosticsRequest)"))
        let take = try #require(view.range(of: "private func takeConversationRequest()"))
        let body = String(view[take.lowerBound...].prefix(300))
        #expect(body.contains("state.diagnosticsConversationId = nil"), "a later plain open must not land on a stale conversation")
    }

    @Test("the shared AppState is read only once the launch gate is open, so the ungated window cannot trap (#463 decision 14)")
    func sharedStateIsReadOnlyBehindTheGate() throws {
        let view = try source("DiagnosticsView.swift")
        #expect(view.contains("private var state: AppState? { gate.isOpen ? stateProvider() : nil }"))
        // Spelled in two pieces: the trap suite scans test files for the literal too.
        let shared = "AppState" + ".shared"
        #expect(!view.contains(shared), "the view must not name the shared state itself")
        let app = try source("IrisApp.swift")
        let at = try #require(app.range(of: "Window(\"Diagnostics\", id: \"diagnostics\")"))
        let block = String(app[at.lowerBound...].prefix(250))
        #expect(block.contains("DiagnosticsView(gate: LaunchGate.shared, stateProvider: { \(shared) })"),
                "a closure: evaluated only when the gate is open, never while the scene is built")
    }

    @Test("the request fields are transient: AppState is not Codable and they are not on a persisted type")
    func requestIsTransient() throws {
        let app = try source("AppState.swift")
        #expect(app.contains("var diagnosticsConversationId: UUID?"))
        let conv = try #require(app.range(of: "struct Conversation: Identifiable, Codable"))
        let convBody = String(app[conv.lowerBound...].prefix(20_000))
        #expect(!convBody.contains("diagnosticsConversationId") && !convBody.contains("diagnosticsRequest"))
    }
}
