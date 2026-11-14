import Testing
import Foundation
@testable import IrisKit

/// #920 Task 2: `inbox_item`, the emit tool. Open emit — any attended main session may raise one —
/// with the inbox's own anti-flood (rate limit, dedup-by-thread) as the whole defense, not a
/// curation gate in code (design spec "the firehose, precisely").
@MainActor
@Suite("Inbox emit tool (#920)", .timeLimit(.minutes(1)))
struct InboxEmitTests {
    private func toolResultText(_ app: AppState, conversationId: UUID) -> String {
        (app.conversations.first { $0.id == conversationId }?.history ?? []).flatMap(\.parts)
            .compactMap { $0.functionResponse?.response["result"]?.stringValue }
            .last ?? ""
    }

    private func runToolCall(_ call: FunctionCall, on app: AppState, as conversationId: UUID,
                             principal: Principal = .main, protectionEnabled: Bool = false) async -> String {
        let first = GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [Part(functionCall: call)]))], usageMetadata: nil)
        let final = GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [Part(text: "ok")]))], usageMetadata: nil)
        let client = FakeLLMClient(responses: [first, final])
        let engine = IrisEngine(state: app, tier: .medium, principal: principal, client: client,
                                retryDelays: [], protectionEnabled: protectionEnabled, sessionPeerCount: 0)
        await engine.processInput("go", source: "UI", conversationId: conversationId)
        return toolResultText(app, conversationId: conversationId)
    }

    private func toolNames(conversationId: UUID, on app: AppState, principal: Principal = .main) async -> [String] {
        let client = CapturingLLMClient(reply: "ok")
        let engine = IrisEngine(state: app, tier: .medium, principal: principal, client: client,
                                retryDelays: [], sessionPeerCount: 0)
        await engine.processInput("hello", source: "UI", conversationId: conversationId)
        return client.requests.first?.tools?.flatMap { $0.functionDeclarations.map(\.name) } ?? []
    }

    private func app() -> (AppState, UUID) {
        let app = AppState(); app.conversations.removeAll()
        let id = app.createNewConversation(select: false)
        return (app, id)
    }

    private func emitCall(title: String = "Ship it?", situation: String = "Here is the context.",
                          responseMode: String = "optionsAndFreeform", options: [JSONValue] = [],
                          threadId: String? = nil, deadline: String? = nil, vetoDefault: String? = nil) -> FunctionCall {
        var args: [String: JSONValue] = ["title": .string(title), "situation": .string(situation),
                                          "response_mode": .string(responseMode)]
        if !options.isEmpty { args["options"] = .array(options) }
        if let threadId { args["thread_id"] = .string(threadId) }
        if let deadline { args["deadline"] = .string(deadline) }
        if let vetoDefault { args["veto_default"] = .string(vetoDefault) }
        return FunctionCall(name: "inbox_item", args: args, id: "c1")
    }

    @Test("inbox_item is declared on an attended main turn, and absent for a background one")
    func emitDeclaredOnlyOnAttendedMainTurn() async {
        let (app, id) = app()
        let attended = await toolNames(conversationId: id, on: app)
        #expect(attended.contains("inbox_item"))

        let bgApp = AppState(); bgApp.conversations.removeAll()
        let bgId = bgApp.createNewConversation(isBackground: true, select: false)
        let background = await toolNames(conversationId: bgId, on: bgApp)
        #expect(!background.contains("inbox_item"))
    }

    @Test("a subagent's forged inbox_item call is refused, never offered")
    func emitFromSubagentRefused() async {
        let app = AppState(); app.conversations.removeAll()
        let sub = app.createNewConversation(isSubagent: true, select: false)
        let result = await runToolCall(emitCall(), on: app, as: sub, principal: .subagent)
        #expect(result.contains(IrisEngine.notOfferedRefusal("inbox_item")), Comment(rawValue: result))
    }

    @Test("a valid emit creates one open item with the given fields")
    func emitCreatesItem() async throws {
        let (app, id) = app()
        let options: [JSONValue] = [.object(["label": .string("Ship it"), "pros": .array([.string("fast")]),
                                              "cons": .array([.string("risky")])])]
        let before = app.inboxRevision
        let result = await runToolCall(emitCall(title: "Ship the thing?", situation: "Full context here.",
                                                options: options), on: app, as: id)
        #expect(result.contains("Recorded #"), Comment(rawValue: result))
        // #943 shipped the mailbox: the model must not be told to hide that it raised something
        // (#920 review: the old "do not tell him" wording survived the mailbox landing).
        #expect(!result.contains("do not tell him"), Comment(rawValue: result))

        let items = try app.store.inbox.openItems()
        #expect(items.count == 1)
        let item = items[0]
        #expect(item.title == "Ship the thing?")
        #expect(item.situation == "Full context here.")
        #expect(item.options.map(\.label) == ["Ship it"])
        #expect(item.state == .open)
        #expect(item.emitter == id)
        // A first raise, not just a followup or an answer, must also bump the revision, or the
        // badge/list stays stale until some other re-render happens to re-run the query
        // (dev-3's #943 review finding 1).
        #expect(app.inboxRevision > before)
    }

    /// #1026: pins the bug itself, not just the classifier. Before this fix, `inbox_item` was
    /// missing from `resultIsIrisOwnWords`, so the main-turn dispatch (`iris.swift:3890`) tainted
    /// the conversation on its first ever tool call — before any outside content existed to taint
    /// it with. Driven through the real dispatch (`runToolCall`/`processInput`), not the classifier
    /// directly, so a regression in how the dispatcher calls the predicate would also be caught.
    @Test("a successful emit, as the session's first tool call, does not set hasUntrustedToolOutput (dev-3's #1047 review finding 2)")
    func emitDoesNotTaintTheConversation() async {
        let (app, id) = app()
        let result = await runToolCall(emitCall(), on: app, as: id)
        #expect(result.contains("Recorded #"), Comment(rawValue: result))
        #expect(app.conversations.first { $0.id == id }?.hasUntrustedToolOutput == false)
    }

    @Test("a guard-blocked emit fails closed: nothing stored, and the rate token is refunded")
    func guardBlockedEmitFailsClosed() async throws {
        let (app, id) = app()
        let budgetBefore = PeerRateLimiter.capacity
        let result = await CoreMLEvaluator.$scopedModel.withValue(.init(nil)) {
            await AuxiliaryModelManager.$scopedEngines.withValue(["canary": MockInferenceEngine(shouldHijack: true)]) {
                await runToolCall(emitCall(), on: app, as: id, protectionEnabled: true)
            }
        }
        #expect(result.contains("Not raised"), Comment(rawValue: result))
        #expect(try app.store.inbox.openItems().isEmpty)
        // Refunded: the full budget is still available, so this many more emits all succeed.
        for _ in 0..<budgetBefore {
            let r = await runToolCall(emitCall(), on: app, as: id)
            #expect(!r.contains("rate limit"), Comment(rawValue: r))
        }
    }

    @Test("after the rate budget is spent, the next emit is refused with the wait message")
    func emitRateLimitExhausted() async throws {
        let (app, id) = app()
        for _ in 0..<PeerRateLimiter.capacity {
            _ = await runToolCall(emitCall(), on: app, as: id)
        }
        let result = await runToolCall(emitCall(), on: app, as: id)
        #expect(result.contains("rate limit"), Comment(rawValue: result))
    }

    @Test("an emitter with untrusted tool output produces a tainted item")
    func emitTaintedMarksItem() async throws {
        let (app, id) = app()
        app.conversations[app.conversations.firstIndex { $0.id == id }!].hasUntrustedToolOutput = true
        _ = await runToolCall(emitCall(), on: app, as: id)
        let items = try app.store.inbox.openItems()
        #expect(items.first?.emitterTainted == true)
    }

    @Test("an emit carrying an existing thread_id from the owning chain appends and reopens")
    func emitWithThreadIdAppends() async throws {
        let (app, id) = app()
        _ = await runToolCall(emitCall(title: "First", situation: "original"), on: app, as: id)
        let item = try #require(try app.store.inbox.openItems().first)
        _ = try app.store.inbox.recordAnswer(itemId: item.id, answer: InboxAnswer(chosenOptionId: nil, freeText: "go ahead", at: Date()))

        let result = await runToolCall(emitCall(situation: "actually, hold on", threadId: item.threadId), on: app, as: id)
        #expect(result.contains("Follow-up recorded on #\(item.id)"), Comment(rawValue: result))
        let reopened = try #require(try app.store.inbox.item(id: item.id))
        #expect(reopened.state == .open)
        let thread = try app.store.inbox.thread(itemId: item.id)
        #expect(thread.map(\.kind) == ["question", "answer", "followup"])
    }

    private func option(_ id: String, _ label: String) -> JSONValue {
        .object(["id": .string(id), "label": .string(label)])
    }

    @Test("a followup replaces the answered item's title, situation and options and clears the old answer (#1024)")
    func followupReplacesTheAsk() async throws {
        let (app, id) = app()
        _ = await runToolCall(emitCall(title: "Which animal?", situation: "pick one", options: [option("a", "honk"), option("b", "moo")]),
                              on: app, as: id)
        let item = try #require(try app.store.inbox.openItems().first)
        _ = try app.store.inbox.submitAnswer(itemId: item.id, answer: InboxAnswer(chosenOptionId: "a", freeText: nil, at: Date()),
                                              pendingTargets: [])

        let result = await runToolCall(emitCall(title: "And the colour?", situation: "now pick a colour",
                                                options: [option("c", "red"), option("d", "blue"), option("e", "green")],
                                                threadId: item.threadId), on: app, as: id)
        #expect(result.contains("#\(item.id)"), Comment(rawValue: result))

        let read = try #require(try app.store.inbox.item(id: item.id))
        #expect(read.state == .open)
        #expect(read.title == "And the colour?" && read.situation == "now pick a colour")
        #expect(read.options.map(\.label) == ["red", "blue", "green"], "the follow-up's options are stored, not dropped")
        #expect(read.answer == nil, "the old answer is cleared so the item can be answered again")
        #expect(try app.store.inbox.openItems().map(\.id) == [item.id], "and it is in the open list Brian sees")

        let thread = try app.store.inbox.thread(itemId: item.id)
        #expect(thread.map(\.kind) == ["question", "answer", "followup"])
        #expect(thread[1].body == "honk", "the history names the option he chose by label")
    }

    @Test("a followup can be answered again, and a second answer is delivered like the first (#1024)")
    func followupIsAnswerable() async throws {
        let (app, id) = app()
        _ = await runToolCall(emitCall(options: [option("a", "yes")]), on: app, as: id)
        let item = try #require(try app.store.inbox.openItems().first)
        _ = try app.store.inbox.submitAnswer(itemId: item.id, answer: InboxAnswer(chosenOptionId: "a", freeText: nil, at: Date()),
                                              pendingTargets: [])
        _ = await runToolCall(emitCall(options: [option("z", "again")], threadId: item.threadId), on: app, as: id)

        let second = try app.store.inbox.submitAnswer(itemId: item.id, answer: InboxAnswer(chosenOptionId: "z", freeText: nil, at: Date()),
                                                       pendingTargets: [])
        guard case .success = second else { Issue.record("expected success, got \(second)"); return }
        #expect(try app.store.inbox.item(id: item.id)?.answer?.chosenOptionId == "z")
    }

    @Test("a followup that turns the item into a timedVeto needs a future deadline and an option id, like a new item (#1024)")
    func followupTimedVetoValidated() async throws {
        let (app, id) = app()
        _ = await runToolCall(emitCall(), on: app, as: id)
        let item = try #require(try app.store.inbox.openItems().first)
        let before = try app.store.inbox.thread(itemId: item.id).count

        let refused = await runToolCall(emitCall(responseMode: "timedVeto", options: [option("a", "go")], threadId: item.threadId,
                                                 deadline: "2001-01-01T00:00:00Z", vetoDefault: "a"), on: app, as: id)
        #expect(refused.contains("needs a deadline"), Comment(rawValue: refused))
        #expect(try app.store.inbox.thread(itemId: item.id).count == before, "a refused follow-up appends nothing")

        let future = ISO8601DateFormatter().string(from: Date().addingTimeInterval(3600))
        let ok = await runToolCall(emitCall(responseMode: "timedVeto", options: [option("a", "go")], threadId: item.threadId,
                                            deadline: future, vetoDefault: "a"), on: app, as: id)
        #expect(ok.contains("Follow-up recorded"), Comment(rawValue: ok))
        let read = try #require(try app.store.inbox.item(id: item.id))
        #expect(read.responseMode == .timedVeto && read.vetoDefaultOptionId == "a" && read.deadline != nil)
    }

    @Test("a followup while Brian's answer is still awaiting delivery is refused, and the answer stays queued (#1028 review)")
    func followupRefusedWhileAwaitingDelivery() async throws {
        let (app, id) = app()
        _ = await runToolCall(emitCall(options: [option("a", "go")]), on: app, as: id)
        let item = try #require(try app.store.inbox.openItems().first)
        _ = try app.store.inbox.submitAnswer(itemId: item.id, answer: InboxAnswer(chosenOptionId: "a", freeText: nil, at: Date()),
                                              pendingTargets: ["role:reviewer"])
        #expect(try app.store.inbox.awaitingDeliveryItems().count == 1)

        let result = await runToolCall(emitCall(options: [option("z", "new")], threadId: item.threadId), on: app, as: id)
        #expect(result.contains("has not reached its recipients"), Comment(rawValue: result))
        let after = try #require(try app.store.inbox.item(id: item.id))
        #expect(after.state == .awaitingDelivery && after.pendingTargets == ["role:reviewer"] && after.answer != nil)
        #expect(try app.store.inbox.awaitingDeliveryItems().count == 1, "still in redeliverAwaitingInbox's queue")
        #expect(try app.store.inbox.thread(itemId: item.id).map(\.kind) == ["question", "answer"], "nothing appended")
    }

    @Test("a followup that turns a timedVeto into a plain item clears its deadline and default (#1028 review)")
    func followupClearsTimedVeto() async throws {
        let (app, id) = app()
        let future = ISO8601DateFormatter().string(from: Date().addingTimeInterval(3600))
        _ = await runToolCall(emitCall(responseMode: "timedVeto", options: [option("a", "go")], deadline: future, vetoDefault: "a"),
                              on: app, as: id)
        let item = try #require(try app.store.inbox.openItems().first)
        #expect(item.deadline != nil && item.vetoDefaultOptionId == "a")

        _ = await runToolCall(emitCall(responseMode: "freeform", threadId: item.threadId, deadline: future, vetoDefault: "a"), on: app, as: id)
        let read = try #require(try app.store.inbox.item(id: item.id))
        #expect(read.responseMode == .freeform && read.deadline == nil && read.vetoDefaultOptionId == nil)
        #expect(try app.store.inbox.dueVetoItems(now: Date().addingTimeInterval(86_400 * 365)).isEmpty,
                "nothing is left for the veto timer to fire")
    }

    @Test("the inbox_item schema offers an option id, so timedVeto is usable by an agent that follows it (#1024)")
    func optionIdIsInTheSchema() async {
        let (app, id) = app()
        let client = CapturingLLMClient(reply: "ok")
        let engine = IrisEngine(state: app, tier: .medium, principal: .main, client: client, retryDelays: [], sessionPeerCount: 0)
        await engine.processInput("hello", source: "UI", conversationId: id)
        let decl = client.requests.first?.tools?.flatMap { $0.functionDeclarations }.first { $0.name == "inbox_item" }
        let optionProps = decl?.parameters?.properties?["options"]?.items?.properties
        #expect(optionProps?["id"] != nil, "options declare id, label, pros and cons")
        #expect(decl?.parameters?.properties?["veto_default"]?.description?.contains("id") == true)
    }

    @Test("a followup to another chain's thread_id is refused, never takes it over")
    func emitWithForeignThreadIdRefused() async throws {
        let (appA, a) = app()
        _ = await runToolCall(emitCall(), on: appA, as: a)
        let item = try #require(try appA.store.inbox.openItems().first)

        let b = appA.createNewConversation(select: false)
        let result = await runToolCall(emitCall(situation: "I'll take this one", threadId: item.threadId), on: appA, as: b)
        #expect(result.contains("Not raised"), Comment(rawValue: result))
        #expect(try appA.store.inbox.item(id: item.id)?.ownerChain != nil)
    }

    @Test("ownership never derives from a card name: a dead emitter's archived name is free to take, but its thread is not (dev-3 #929 review finding 1)")
    func archivedEmitterNameIsNotOwnership() async throws {
        let app = AppState(); app.conversations.removeAll()
        let a = app.createNewConversation(select: false)
        app.setSessionCard(for: a, SessionCard(name: "scout", description: "x"))
        _ = await runToolCall(emitCall(), on: app, as: a)
        let item = try #require(try app.store.inbox.openItems().first)

        app.conversations[app.conversations.firstIndex { $0.id == a }!].isArchived = true
        let b = app.createNewConversation(select: false)
        app.setSessionCard(for: b, SessionCard(name: "scout", description: "y"))

        let result = await runToolCall(emitCall(situation: "I'll take this one", threadId: item.threadId), on: app, as: b)
        #expect(result.contains("Not raised"), Comment(rawValue: result))
        #expect(try app.store.inbox.item(id: item.id)?.state == .open)
    }

    @Test("a followup from a session with untrusted tool output taints the item, even if it was created clean")
    func followupTaintsItem() async throws {
        let (app, id) = app()
        _ = await runToolCall(emitCall(), on: app, as: id)
        let item = try #require(try app.store.inbox.openItems().first)
        #expect(item.emitterTainted == false)

        app.conversations[app.conversations.firstIndex { $0.id == id }!].hasUntrustedToolOutput = true
        _ = await runToolCall(emitCall(situation: "a followup", threadId: item.threadId), on: app, as: id)
        #expect(try app.store.inbox.item(id: item.id)?.emitterTainted == true)
    }

    @Test("timedVeto with no deadline, a past deadline, or an unknown veto_default is refused")
    func timedVetoValidatesDeadlineAndDefault() async throws {
        let (app, id) = app()
        let options: [JSONValue] = [.object(["id": .string("a"), "label": .string("Ship it")])]
        let future = ISO8601DateFormatter().string(from: Date().addingTimeInterval(3600))
        let past = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-3600))

        let noDeadline = await runToolCall(emitCall(responseMode: "timedVeto", options: options, vetoDefault: "a"), on: app, as: id)
        #expect(noDeadline.contains("deadline"), Comment(rawValue: noDeadline))

        let pastDeadline = await runToolCall(emitCall(responseMode: "timedVeto", options: options, deadline: past, vetoDefault: "a"), on: app, as: id)
        #expect(pastDeadline.contains("deadline"), Comment(rawValue: pastDeadline))

        let unknownDefault = await runToolCall(emitCall(responseMode: "timedVeto", options: options, deadline: future, vetoDefault: "nope"), on: app, as: id)
        #expect(unknownDefault.contains("veto_default"), Comment(rawValue: unknownDefault))

        #expect(try app.store.inbox.openItems().isEmpty, "none of the malformed emits should have stored anything")

        let ok = await runToolCall(emitCall(responseMode: "timedVeto", options: options, deadline: future, vetoDefault: "a"), on: app, as: id)
        #expect(ok.contains("Recorded #"), Comment(rawValue: ok))
    }

    @Test("options with duplicate ids are refused")
    func duplicateOptionIdsRefused() async throws {
        let (app, id) = app()
        let options: [JSONValue] = [.object(["id": .string("a"), "label": .string("One")]),
                                    .object(["id": .string("a"), "label": .string("Two")])]
        let result = await runToolCall(emitCall(options: options), on: app, as: id)
        #expect(result.contains("distinct ids"), Comment(rawValue: result))
        #expect(try app.store.inbox.openItems().isEmpty)
    }

    @Test("route_back and notify may name only the emitter or roles: another session is refused and nothing is stored")
    func emitRefusesArbitrarySessionTargets() async throws {
        let (app, id) = app()
        let victim = app.createNewConversation(select: false)
        for bad in [victim.uuidString, "name:someone", "iris", "dev-1", ""] {
            for key in ["route_back", "notify"] {
                var call = emitCall()
                call.args[key] = .array([.string(bad)])
                let result = await runToolCall(call, on: app, as: id)
                #expect(result.contains("may name only role"), Comment(rawValue: "\(key)=\(bad): \(result)"))
            }
        }
        #expect(try app.store.inbox.openItems().isEmpty)
        // Roles and itself are fine, and the refusals above spent no rate token.
        var ok = emitCall()
        ok.args["route_back"] = .array([.string("role:planner"), .string(id.uuidString)])
        ok.args["notify"] = .array([.string("role:overseer")])
        let result = await runToolCall(ok, on: app, as: id)
        #expect(result.contains("Recorded"), Comment(rawValue: result))
        #expect(try app.store.inbox.openItems().first?.routeBack == ["role:planner", id.uuidString])
    }


    @Test("relative deadlines (+30m, +2h, +1d, +90s) and fractional-seconds ISO 8601 resolve and echo in the result (#1094)")
    func relativeAndFractionalDeadlinesResolveAndEcho() async throws {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(IrisEngine.parseInboxDeadline("+30m", now: base) == base.addingTimeInterval(1800))
        #expect(IrisEngine.parseInboxDeadline("45m", now: base) == base.addingTimeInterval(2700))
        #expect(IrisEngine.parseInboxDeadline("+2h", now: base) == base.addingTimeInterval(7200))
        #expect(IrisEngine.parseInboxDeadline("+1d", now: base) == base.addingTimeInterval(86_400))
        #expect(IrisEngine.parseInboxDeadline("+90s", now: base) == base.addingTimeInterval(90))
        #expect(IrisEngine.parseInboxDeadline("2030-01-02T03:04:05.678Z", now: base) != nil)

        let (app, id) = app()
        let options: [JSONValue] = [option("a", "Proceed"), option("b", "Hold")]
        let before = Date()
        let result = await runToolCall(
            emitCall(responseMode: "timedVeto", options: options, deadline: "+30m", vetoDefault: "a"),
            on: app, as: id
        )
        #expect(result.contains("Recorded #"), Comment(rawValue: result))
        #expect(result.contains("(deadline "), Comment(rawValue: result))

        let item = try #require(try app.store.inbox.openItems().first)
        let storedDeadline = try #require(item.deadline)
        #expect(storedDeadline >= before.addingTimeInterval(1795) && storedDeadline <= Date().addingTimeInterval(1805))
        #expect(result.contains(IrisEngine.formatInboxDeadline(storedDeadline)), Comment(rawValue: result))
    }

    @Test("unparseable deadlines are refused with Not raised and never silently dropped (#1094)")
    func unparseableDeadlinesRefused() async throws {
        let (app, id) = app()
        let options: [JSONValue] = [option("a", "Proceed")]
        for bad in ["tomorrow", "2026-99-99T00:00:00Z", "+0m", "-10m", "30weeks"] {
            let result = await runToolCall(
                emitCall(responseMode: "timedVeto", options: options, deadline: bad, vetoDefault: "a"),
                on: app, as: id
            )
            #expect(result.hasPrefix("Not raised:"), Comment(rawValue: "\(bad): \(result)"))
            #expect(result.contains("needs a deadline"), Comment(rawValue: "\(bad): \(result)"))
        }
        #expect(try app.store.inbox.openItems().isEmpty)
    }

    @Test("a timedVeto raised from a session with outside content warns at filing that the default will be held (#1095)")
    func taintedTimedVetoWarnsAtFiling() async throws {
        let (app, id) = app()
        app.conversations[app.conversations.firstIndex { $0.id == id }!].hasUntrustedToolOutput = true
        let options: [JSONValue] = [option("a", "Proceed")]
        let result = await runToolCall(
            emitCall(responseMode: "timedVeto", options: options, deadline: "+15m", vetoDefault: "a"),
            on: app, as: id
        )
        #expect(result.contains("Recorded #"), Comment(rawValue: result))
        #expect(result.contains("default will be held at the deadline"), Comment(rawValue: result))
    }

    @Test("timedVeto enforces a 15-minute minimum window and a 10-year horizon on both relative and ISO 8601 deadlines (#1121)")
    func timedVetoEnforcesMinimumWindowAndHorizon() async throws {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(IrisEngine.parseInboxDeadline("+3651d", now: base) == nil, "relative > 10y rejected")
        let overHorizonISO = ISO8601DateFormatter().string(from: base.addingTimeInterval(365 * 86_400 * 10 + 60))
        #expect(IrisEngine.parseInboxDeadline(overHorizonISO, now: base) == nil, "ISO > 10y rejected")

        let (app, id) = app()
        let options: [JSONValue] = [option("a", "Proceed"), option("b", "Hold")]
        let fiveMinISO = ISO8601DateFormatter().string(from: Date().addingTimeInterval(300))
        for tooShort in ["+1s", "+5m", "+14m", fiveMinISO] {
            let result = await runToolCall(
                emitCall(responseMode: "timedVeto", options: options, deadline: tooShort, vetoDefault: "a"),
                on: app, as: id
            )
            #expect(result.hasPrefix("Not raised:"), Comment(rawValue: "\(tooShort): \(result)"))
            #expect(result.contains("at least \(IrisEngine.timedVetoMinWindowMinutes)m"), Comment(rawValue: "\(tooShort): \(result)"))
        }
        #expect(try app.store.inbox.openItems().isEmpty, "short-window emits must not be stored")

        let ok = await runToolCall(
            emitCall(responseMode: "timedVeto", options: options, deadline: "+15m", vetoDefault: "a"),
            on: app, as: id
        )
        #expect(ok.contains("Recorded #"), Comment(rawValue: ok))
    }
}
