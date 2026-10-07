import Testing
import Foundation
@testable import iris

/// Spec §2.1, PRs 1-2: within one turn, each request's messages extend the last request's,
/// ignoring `cache_control`. Bodies come from `AnthropicClient.makeURLRequest`, the RequestDump
/// path; replies carry fake signed blocks, which no signature check reads here.
@MainActor
@Suite("Append-only requests within a turn (#314)", .timeLimit(.minutes(1)))
struct AppendOnlyRequestTests {
    private func expectPrefixChain(_ h: ThinkingHarness, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let bodies = try h.client.requests.map { try ThinkingFixtures.messagesIgnoringCacheControl(try ThinkingFixtures.body($0)) }
        for n in bodies.indices.dropLast() {
            #expect(Array(bodies[n + 1].prefix(bodies[n].count)) == bodies[n],
                    "request \(n + 2) does not extend request \(n + 1)", sourceLocation: sourceLocation)
        }
    }

    @Test("each request of a four-round turn extends the one before")
    func prefixChain() async throws {
        let dir = try ThinkingFixtures.tempDirectory("chain")
        defer { try? FileManager.default.removeItem(at: dir) }
        let h = try ThinkingHarness.make(ThinkingFixtures.fourRounds(), hooks: try ThinkingFixtures.hooks(in: dir),
                                         earlierTurn: true)
        await h.run()
        try #require(h.client.requests.count == 4)
        try expectPrefixChain(h)
    }

    @Test("replies that did not think keep the chain too")
    func prefixChainUnthought() async throws {
        let dir = try ThinkingFixtures.tempDirectory("chain-unthought")
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = [ThinkingFixtures.unthought(1, toolCall: true), ThinkingFixtures.reply(2, toolCall: true),
                      ThinkingFixtures.unthought(3, toolCall: false)]
        let h = try ThinkingHarness.make(script, hooks: try ThinkingFixtures.hooks(in: dir))
        await h.run()
        try #require(h.client.requests.count == 3)
        try expectPrefixChain(h)
    }

    @Test("no beta header reaches an unknown id; a check model gets it on every request")
    func headerPerModel() async throws {
        let dir = try ThinkingFixtures.tempDirectory("header")
        defer { try? FileManager.default.removeItem(at: dir) }
        let h = try ThinkingHarness.make(ThinkingFixtures.fourRounds(), hooks: try ThinkingFixtures.hooks(in: dir))
        await h.run()
        for request in h.client.requests {
            #expect(try ThinkingFixtures.urlRequest(request, model: "claude-made-up-9").value(forHTTPHeaderField: "anthropic-beta") == nil)
            #expect(try ThinkingFixtures.urlRequest(request).value(forHTTPHeaderField: "anthropic-beta") == AnthropicCapabilities.bindingBeta)
        }
    }

    private static let produced: [String?] = ["sig-1", "sig-2", "sig-3", "sig-4"]
    /// Removes every `anthropicBlocks` member from a hook's JSON, wherever it sits in its object.
    private static let stripBlocksExpr = #"s/,"anthropicBlocks":"([^"\\]|\\.)*"//g; s/"anthropicBlocks":"([^"\\]|\\.)*",//g"#

    /// One harness, one turn per input, every request of the script answered. Hook scripts get the
    /// test's temp dir (for counter files); `roundStart` gets a handle on the harness's history.
    private func run(_ label: String, hooks scripts: [String: (URL) -> String] = [:],
                     script: [GeminiResponse] = ThinkingFixtures.fourRounds(),
                     inputs: [String] = ["Tell me about Seattle"],
                     seedFact: Bool = false, earlierTurn: Bool = true, budget: TurnBudget? = nil,
                     roundStart: ((ThinkingHarness.Edit) -> @Sendable (Int) async -> Void)? = nil) async throws -> ThinkingHarness {
        let dir = try ThinkingFixtures.tempDirectory(label)
        defer { try? FileManager.default.removeItem(at: dir) }
        let hooks = try ThinkingFixtures.hooks(in: dir, scripts.mapValues { $0(dir) })
        let edit = ThinkingHarness.Edit()
        let h = try ThinkingHarness.make(script, hooks: hooks, seedFact: seedFact, earlierTurn: earlierTurn,
                                         roundStart: roundStart?(edit))
        edit.bind(h)
        for input in inputs {
            if let budget {
                await h.engine.processInput(input, source: "UI", conversationId: h.id, turnBudget: budget)
            } else {
                await h.run(input)
            }
        }
        try #require(h.client.requests.count == script.count)
        return h
    }

    @Test("baseline: each request sends this turn's blocks, oldest first, verbatim; never an older turn's")
    func baselineReplay() async throws {
        let h = try await run("baseline")
        let sent = try h.sentSignatures()
        #expect(sent == [[], ["sig-1"], ["sig-1", "sig-2"], ["sig-1", "sig-2", "sig-3"]])
        #expect(!sent.joined().contains("sig-0"), "the earlier turn's reply never sends its block")
        #expect(try ThinkingFixtures.bodyText(h.client.requests[1]).contains(#"{"query": "Seattle 1"}"#))
        ThinkingFixtures.expectFrontDroppedWindows(sent, produced: Self.produced)
        try expectPrefixChain(h)
    }

    @Test("a reply that did not think leaves no gap: the window skips it")
    func unthoughtReplyInTheMiddle() async throws {
        let script = [ThinkingFixtures.reply(1, toolCall: true), ThinkingFixtures.unthought(2, toolCall: true),
                      ThinkingFixtures.reply(3, toolCall: true), ThinkingFixtures.reply(4, toolCall: false)]
        let h = try await run("unthought", script: script)
        let sent = try h.sentSignatures()
        #expect(sent == [[], ["sig-1"], ["sig-1"], ["sig-1", "sig-3"]])
        ThinkingFixtures.expectFrontDroppedWindows(sent, produced: ["sig-1", nil, "sig-3", "sig-4"])
    }

    @Test("pass-through hooks on every event keep the baseline (Review Focus 2)")
    func passThroughHooksKeepReplay() async throws {
        let h = try await run("passthrough", hooks: ["BeforeModel": { _ in "cat" }, "PreCompress": { _ in "cat" },
                                                     "AfterModel": { _ in "cat" }])
        #expect(try h.sentSignatures() == [[], ["sig-1"], ["sig-1", "sig-2"], ["sig-1", "sig-2", "sig-3"]])
    }

    @Test("check case: an AfterModel rewrite of round two stops replay through round two")
    func afterModelRewrite() async throws {
        let h = try await run("aftermodel", hooks: ["AfterModel": { dir in
            ThinkingFixtures.onCall(2, sed: "s/Seattle 2/Seattle two/g", counter: dir.appendingPathComponent("n")) }])
        let sent = try h.sentSignatures()
        #expect(sent == [[], ["sig-1"], [], ["sig-3"]])
        ThinkingFixtures.expectFrontDroppedWindows(sent, produced: ["sig-1", nil, "sig-3", "sig-4"])
    }

    @Test("check case: the reply is recorded as received; a hook's blockless rewrite, stored as is, still diverges")
    func afterModelRewriteRecordedAsReceived() async throws {
        let h = try await run("aftermodel-received", hooks: ["AfterModel": { dir in
            ThinkingFixtures.onCall(2, sed: "s/Seattle 2/Seattle two/g; \(Self.stripBlocksExpr)",
                                    counter: dir.appendingPathComponent("n")) }])
        #expect(h.history.contains { $0.parts.contains { $0.functionCall?.args["query"] == .string("Seattle two") } },
                "precondition: the hook's reply is what history stored")
        let sent = try h.sentSignatures()
        #expect(sent == [[], ["sig-1"], [], ["sig-3"]], "request three's reply two is not what the model sent")
    }

    @Test("check case: a UI edit of the turn's entry (5a's firstDrop) stops replay of everything before it")
    func uiEditOfTheEntry() async throws {
        let h = try await run("firstdrop", seedFact: true, earlierTurn: false, roundStart: { edit in
            { round in if round == 1 { await edit.replaceText(of: 0, with: "Tell me about Portland") } } })
        let sent = try h.sentSignatures()
        #expect(sent == [[], ["sig-1"], [], ["sig-3"]])
        ThinkingFixtures.expectFrontDroppedWindows(sent, produced: Self.produced)
    }

    @Test("check case: a UI edit of an older message on a turn with no context (5a misses it)")
    func uiEditWithoutContext() async throws {
        let h = try await run("edit-nocontext", roundStart: { edit in
            { round in if round == 1 { await edit.replaceText(of: 0, with: "earlier question, edited") } } })
        let sent = try h.sentSignatures()
        #expect(sent == [[], ["sig-1"], [], ["sig-3"]])
        ThinkingFixtures.expectFrontDroppedWindows(sent, produced: Self.produced)
    }

    @Test("check case: a UI deletion of an older message mid-turn; no older block replays")
    func uiDeletion() async throws {
        let h = try await run("delete", roundStart: { edit in
            { round in if round == 1 { await edit.remove(at: 0) } } })
        #expect(h.client.requests[2].contents.count == h.client.requests[1].contents.count + 1,
                "precondition: request three lost one message and gained two")
        let sent = try h.sentSignatures()
        #expect(sent == [[], ["sig-1"], [], ["sig-3"]])
        ThinkingFixtures.expectFrontDroppedWindows(sent, produced: Self.produced)
    }

    @Test("check case: a PreCompress hook that modified history; the break falls at round two")
    func preCompressModified() async throws {
        let h = try await run("precompress", hooks: ["PreCompress": { _ in "sed 's/earlier question/EARLIER question/'" }])
        let sent = try h.sentSignatures()
        #expect(sent == [[], [], ["sig-2"], ["sig-2", "sig-3"]])
        ThinkingFixtures.expectFrontDroppedWindows(sent, produced: Self.produced)
    }

    @Test("a PreCompress hook that prepends never makes round one send an older turn's block (Review Focus 5)")
    func preCompressPrependSendsNoOldBlocks() async throws {
        let prepend = #"sed '1s/^\[/[{"role":"user","parts":[{"text":"s1"}]},{"role":"model","parts":[{"text":"s2"}]},/'"#
        let h = try await run("prepend", hooks: ["PreCompress": { _ in prepend }])
        #expect(try ThinkingFixtures.signatures(ThinkingFixtures.body(h.client.requests[0])).isEmpty)
        #expect(h.client.requests[0].contents.count == 5, "precondition: the hook's list reached round one")
    }

    @Test("check case: a BeforeModel rewrite of request two strips its blocks from the hook's output, and the next request too")
    func beforeModelRewriteOnce() async throws {
        let h = try await run("beforemodel-once", hooks: ["BeforeModel": { dir in
            ThinkingFixtures.onCall(2, sed: "s/Tell me about Seattle/TELL me about Seattle/", counter: dir.appendingPathComponent("n")) }])
        let sent = try h.sentSignatures()
        #expect(try ThinkingFixtures.bodyText(h.client.requests[1]).contains("TELL me about Seattle"),
                "precondition: request two is the hook's output")
        #expect(try !ThinkingFixtures.bodyText(h.client.requests[2]).contains("TELL me"),
                "precondition: request three is not")
        #expect(sent[1].isEmpty, "request two itself carries no block (work's note on #384)")
        #expect(sent[2].isEmpty, "request three restores the prefix request two's reply was bound to")
        #expect(sent == [[], [], [], ["sig-3"]])
        ThinkingFixtures.expectFrontDroppedWindows(sent, produced: Self.produced)
    }

    @Test("check case: a BeforeModel edit of an earlier reply's tool argument reaches the wire, not the stored bytes")
    func beforeModelEditsReplyArgument() async throws {
        let h = try await run("beforemodel-arg", hooks: ["BeforeModel": { dir in
            ThinkingFixtures.onCall(3, sed: #"s/"query":"Seattle 2"/"query":"Seattle TWO"/"#,
                                    counter: dir.appendingPathComponent("n")) }])
        let text = try ThinkingFixtures.bodyText(h.client.requests[2])
        #expect(text.contains(#""input":{"query":"Seattle TWO"}"#), "the hook's edit goes out")
        #expect(!text.contains(#"{"query": "Seattle 2"}"#), "reply two's stored bytes stay out")
        #expect(!text.contains(#""query":"Seattle 2""#))
        let sent = try h.sentSignatures()
        #expect(sent[2].isEmpty, "request three echoes no reply: its own edit went out as parts")
        #expect(sent == [[], ["sig-1"], [], []], "request four undoes the edit reply three was bound to")
        ThinkingFixtures.expectFrontDroppedWindows(sent, produced: Self.produced)
    }

    @Test("check case: a one-off BeforeModel hook that drops anthropicBlocks stops replay from that request")
    func beforeModelDropsBlocks() async throws {
        let h = try await run("beforemodel-strip", hooks: ["BeforeModel": { dir in
            ThinkingFixtures.onCall(2, sed: Self.stripBlocksExpr, counter: dir.appendingPathComponent("n")) }])
        #expect(h.client.requests[1].contents.allSatisfy { $0.anthropicBlocks == nil },
                "precondition: request two is the hook's blockless output")
        let sent = try h.sentSignatures()
        #expect(sent == [[], [], ["sig-2"], ["sig-2", "sig-3"]])
        ThinkingFixtures.expectFrontDroppedWindows(sent, produced: Self.produced)
    }

    // `[^}]*` cannot cross the system Content's own fields whatever their key order: no `}` comes
    // before its first text.
    private static let systemExpr = #"s/("systemInstruction":\{[^}]*"text":")/\1HOOKED /"#
    private static let toolsExpr = #"s/("functionDeclarations":\[)/\1{"name":"hook_added","description":"x"},/"#

    @Test("check case: a one-off BeforeModel rewrite of the system instruction, then its undoing (work's review on #388)")
    func beforeModelSystemOnce() async throws {
        let h = try await run("system-once", hooks: ["BeforeModel": { dir in
            ThinkingFixtures.onCall(3, sed: Self.systemExpr, counter: dir.appendingPathComponent("n")) }])
        #expect(try ThinkingFixtures.bodyText(h.client.requests[2]).contains("HOOKED "), "precondition: request three's system is the hook's")
        #expect(try !ThinkingFixtures.bodyText(h.client.requests[3]).contains("HOOKED "), "precondition: request four's is not")
        let sent = try h.sentSignatures()
        #expect(sent == [[], ["sig-1"], [], []], "request four restores the system reply three was bound to")
        ThinkingFixtures.expectFrontDroppedWindows(sent, produced: Self.produced)
    }

    @Test("check case: a one-off BeforeModel rewrite of the tools, then its undoing")
    func beforeModelToolsOnce() async throws {
        let h = try await run("tools-once", hooks: ["BeforeModel": { dir in
            ThinkingFixtures.onCall(3, sed: Self.toolsExpr, counter: dir.appendingPathComponent("n")) }])
        #expect(try ThinkingFixtures.bodyText(h.client.requests[2]).contains("hook_added"), "precondition: request three's tools are the hook's")
        #expect(try !ThinkingFixtures.bodyText(h.client.requests[3]).contains("hook_added"))
        #expect(try h.sentSignatures() == [[], ["sig-1"], [], []])
    }

    @Test("a hook that rewrites the system identically every round keeps replay (amends decision 2)")
    func steadyRewriteKeepsReplay() async throws {
        let h = try await run("system-steady", hooks: ["BeforeModel": { _ in "sed -E '\(Self.systemExpr)'" }])
        #expect(try h.client.requests.allSatisfy { try ThinkingFixtures.bodyText($0).contains("HOOKED ") })
        #expect(try h.sentSignatures() == [[], ["sig-1"], ["sig-1", "sig-2"], ["sig-1", "sig-2", "sig-3"]])
    }

    @Test("#385's budget cap reaches every request's max_tokens through a rewriting hook and replay")
    func budgetCapSurvivesReplay() async throws {
        let budget = TurnBudget(maxTokens: 20_000, deadline: Date().addingTimeInterval(600),
                                provider: LLMProvider.anthropic.rawValue)
        let h = try await run("budget", hooks: ["BeforeModel": { _ in "sed -E '\(Self.systemExpr)'" }], budget: budget)
        #expect(try h.sentSignatures() == [[], ["sig-1"], ["sig-1", "sig-2"], ["sig-1", "sig-2", "sig-3"]],
                "precondition: replay is on")
        for request in h.client.requests {
            #expect(request.maxOutputTokens == 4000)
            #expect(try ThinkingFixtures.body(request)["max_tokens"] as? Int == 4000)
        }
    }

    @Test("the next turn starts again from its own replies")
    func nextTurnStartsFresh() async throws {
        let h = try await run("nextturn",
                              script: ThinkingFixtures.fourRounds() + [ThinkingFixtures.reply(5, toolCall: true),
                                                                       ThinkingFixtures.reply(6, toolCall: false)],
                              inputs: ["Tell me about Seattle", "And Portland?"])
        let sent = try h.sentSignatures()
        #expect(Array(sent.suffix(2)) == [[], ["sig-5"]], "turn two sends none of turn one's blocks")
    }
}
