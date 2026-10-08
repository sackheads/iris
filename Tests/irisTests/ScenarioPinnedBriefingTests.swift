// Tests/irisTests/ScenarioPinnedBriefingTests.swift
import Testing
import Foundation
@testable import IrisKit

/// 5b Task 7: the scenario fields that pin a run's conversation, write ledger rows before a turn
/// and deliver an event card mid-turn. Every run here uses its own in-memory store (the runner
/// mints one for such scenarios) and a scripted client; nothing touches a process-global.
@MainActor
@Suite("Scenario pin, ledger rows and mid-turn event cards (5b)")
struct ScenarioPinnedBriefingTests {
    /// Replays scripted responses in order and records every request, so a test can read what
    /// each round actually sent.
    private final class ScriptedRecorder: LLMClientProtocol, @unchecked Sendable {
        private let lock = NSLock()
        private var responses: [GeminiResponse]
        private(set) var requests: [GeminiRequest] = []
        init(_ responses: [Scenario.ScriptedResponse]) { self.responses = responses.map { $0.asGeminiResponse() } }
        func generateContent(request: GeminiRequest, tier: ModelTier) async throws -> GeminiResponse {
            lock.withLock {
                requests.append(request)
                return responses.count > 1 ? responses.removeFirst() : responses[0]
            }
        }
        var all: [GeminiRequest] { lock.withLock { requests } }
    }

    private static func text(_ s: String) -> Scenario.ScriptedResponse { .init(kind: .text, text: s, calls: nil) }
    private static let command = Scenario.ScriptedResponse(
        kind: .toolCalls, text: nil, calls: [.init(name: "run_command", args: ["command": .string("echo hi")])])

    /// The last user entry's text in a request: where the turn-context block rides.
    private static func turnContext(_ request: GeminiRequest) -> String? {
        let texts = request.contents.flatMap { $0.parts.compactMap(\.text) }
        return texts.last { $0.contains("<turn_context>") }
    }

    private static func allText(_ request: GeminiRequest) -> String {
        request.contents.flatMap { $0.parts.compactMap(\.text) }.joined(separator: "\n")
    }

    private static func pinnedScenario(pinned: Bool = true, cardOnToolTurn: Bool = true) -> Scenario {
        let card = Scenario.LedgerRun(name: "repo-watch", status: .completed, outcome: "3 files changed")
        return Scenario(name: "pinned", clientMode: .fake, turns: [
            .init(prompt: "one"),
            .init(prompt: "two", ledgerRuns: [.init(name: "nightly-backup", status: .completed)],
                  eventCard: cardOnToolTurn ? nil : card),
            .init(prompt: "three", ledgerRuns: [.init(name: "inbox-sweep", status: .failed)],
                  eventCard: cardOnToolTurn ? card : nil),
            .init(prompt: "four", ledgerRuns: [.init(name: "nightly-backup", status: .completed)]),
        ], seedFacts: ["QUILLBARROW keeps bees."], pinned: pinned)
    }

    private static let script = [text("a1"), text("a2"), command, text("a3"), text("a4")]

    @Test("pinned, ledgerRuns and eventCard decode; all default off when absent")
    func parsing() throws {
        let json = #"""
        { "name": "p", "pinned": true, "turns": [
            { "prompt": "a" },
            { "prompt": "b", "ledgerRuns": [{ "name": "j", "status": "failed" }],
              "eventCard": { "name": "w", "status": "completed", "outcome": "ok" } } ] }
        """#
        let s = try Scenario.decode(from: Data(json.utf8))
        #expect(s.pinned)
        #expect(s.usesOwnStore)
        #expect(s.turns[0].ledgerRuns == nil && s.turns[0].eventCard == nil)
        #expect(s.turns[1].ledgerRuns == [.init(name: "j", status: .failed)])
        #expect(s.turns[1].eventCard == .init(name: "w", status: .completed, outcome: "ok"))

        let plain = try Scenario.decode(from: Data(#"{ "name": "q", "turns": [{ "prompt": "a" }] }"#.utf8))
        #expect(!plain.pinned)
        #expect(!plain.usesOwnStore)
        #expect(throws: (any Error).self) {
            try Scenario.decode(from: Data(#"{ "name": "r", "turns": [{ "prompt": "a", "ledgerRuns": [{ "name": "j", "status": "bogus" }] }] }"#.utf8))
        }
    }

    @Test("a ledger row is a finished run of one disabled job per name, visible to the briefing's queries")
    func ledgerRowsApply() throws {
        let ledger = try ConversationStore.inMemory().ledger
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let a = try ScenarioLedgerSeed.write(.init(name: "nightly-backup", status: .completed), to: ledger, at: t0)
        let b = try ScenarioLedgerSeed.write(.init(name: "inbox-sweep", status: .failed), to: ledger, at: t0 + 1)
        let c = try ScenarioLedgerSeed.write(.init(name: "nightly-backup", status: .completed, outcome: "fine"), to: ledger, at: t0 + 2)

        let jobs = try ledger.jobs()
        #expect(jobs.map(\.name).sorted() == ["inbox-sweep", "nightly-backup"])
        #expect(jobs.allSatisfy { !$0.enabled })
        #expect(a.jobId == c.jobId)
        #expect(try ledger.recentRuns(limit: 10).map(\.id) == [c.id, b.id, a.id])
        #expect(try ledger.unacknowledgedFailures().map(\.id) == [b.id])
        #expect(try ledger.run(id: c.id)?.outcome == "fine")
        #expect(try ledger.run(id: c.id)?.finishedAt != nil)
    }

    @Test("pinned run: no briefing on a quiet turn 1, then a different briefing every turn; pinned-only tools declared")
    func briefingChangesEveryTurn() async throws {
        let client = ScriptedRecorder(Self.script)
        let result = await ScenarioRunner.run(Self.pinnedScenario(), guards: .off, clientOverride: client)
        #expect(result.turnErrors == [nil, nil, nil, nil])
        let requests = client.all
        try #require(requests.count == 5)   // turn 3 has two rounds
        let firstRounds = [requests[0], requests[1], requests[2], requests[4]]
        let briefings = firstRounds.map { Self.turnContext($0) ?? "" }
        #expect(!briefings[0].contains("Recent Activity"), "a quiet ledger adds nothing")
        for k in 1...3 { #expect(briefings[k].contains("# Recent Activity"), "turn \(k + 1)") }
        #expect(Set(briefings).count == 4, "the turn context changes on every turn")
        #expect(briefings[2].contains("inbox-sweep"))
        #expect(briefings[3].contains("repo-watch"), "the mid-turn card's row reaches turn 4's briefing")
        let declared = Set(requests[0].tools?.flatMap { $0.functionDeclarations.map(\.name) } ?? [])
        #expect(declared.contains("search_conversations"), "the conversation is the pinned one")
    }

    @Test("an event card on a two-round turn is drained into that turn's second round")
    func eventCardLandsMidTurn() async throws {
        let client = ScriptedRecorder(Self.script)
        let result = await ScenarioRunner.run(Self.pinnedScenario(), guards: .off, clientOverride: client)
        #expect(result.midTurnEventCards == [3])
        let requests = client.all
        try #require(requests.count == 5)
        #expect(!Self.allText(requests[2]).contains("[Event] job repo-watch"), "not in turn 3's first round")
        #expect(Self.allText(requests[3]).contains("[Event] job repo-watch"), "in turn 3's second round")
    }

    @Test("an event card on a one-round turn arrives after it, so the next turn reads it")
    func eventCardAfterOneRoundTurn() async throws {
        let client = ScriptedRecorder(Self.script)
        let result = await ScenarioRunner.run(Self.pinnedScenario(cardOnToolTurn: false), guards: .off, clientOverride: client)
        #expect(result.midTurnEventCards.isEmpty)
        let requests = client.all
        try #require(requests.count == 5)
        #expect(!Self.allText(requests[1]).contains("[Event] job repo-watch"))
        #expect(Self.allText(requests[2]).contains("[Event] job repo-watch"))
    }

    @Test("unpinned: the same ledger rows add no briefing and no pinned-only tools")
    func unpinnedHasNoBriefing() async throws {
        let client = ScriptedRecorder(Self.script)
        _ = await ScenarioRunner.run(Self.pinnedScenario(pinned: false), guards: .off, clientOverride: client)
        let requests = client.all
        try #require(!requests.isEmpty)
        #expect(requests.allSatisfy { !Self.allText($0).contains("Recent Activity") })
        let declared = Set(requests[0].tools?.flatMap { $0.functionDeclarations.map(\.name) } ?? [])
        #expect(!declared.contains("search_conversations"))
    }
}
