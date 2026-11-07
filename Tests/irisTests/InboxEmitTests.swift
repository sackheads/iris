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
        let result = await runToolCall(emitCall(title: "Ship the thing?", situation: "Full context here.",
                                                options: options), on: app, as: id)
        #expect(result.contains("Recorded #"), Comment(rawValue: result))

        let items = try app.store.inbox.openItems()
        #expect(items.count == 1)
        let item = items[0]
        #expect(item.title == "Ship the thing?")
        #expect(item.situation == "Full context here.")
        #expect(item.options.map(\.label) == ["Ship it"])
        #expect(item.state == .open)
        #expect(item.emitter == id)
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
        #expect(result.contains("Appended"), Comment(rawValue: result))
        let reopened = try #require(try app.store.inbox.item(id: item.id))
        #expect(reopened.state == .open)
        let thread = try app.store.inbox.thread(itemId: item.id)
        #expect(thread.map(\.kind) == ["question", "answer", "followup"])
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
}
