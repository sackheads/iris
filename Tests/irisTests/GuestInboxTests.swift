import Testing
import Foundation
@testable import IrisKit

/// #1417 (Brian, 11-27: "2: yes"): an MCP guest raises Inbox items. Its item is its client's (`guest:<clientId>`),
/// shows the guest as its source and counts as tainted, so a timed veto holds. Brian's answer reaches only that
/// guest, as a message in its mailbox, even offline, and is delivered once a poll returns it.
@MainActor
@Suite("Guests raising Inbox items (#1417)", .serialized, .timeLimit(.minutes(1)))
struct GuestInboxTests {
    /// Records what the guest seam was asked to file, and answers `next`.
    private final class GuestSink: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [(clientId: String, itemId: String, target: String, text: String)] = []
        private var answer: GuestInboxFiling = .filed
        var calls: [(clientId: String, itemId: String, target: String, text: String)] { lock.withLock { stored } }
        var next: GuestInboxFiling { get { lock.withLock { answer } } set { lock.withLock { answer = newValue } } }
        var deliver: IrisEngine.GuestInboxDeliver {
            { [self] clientId, itemId, target, text in
                lock.withLock { stored.append((clientId, itemId, target, text)); return answer }
            }
        }
    }

    /// Records the host-session deliveries, which a guest's answer must never reach.
    private final class HostSink: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [UUID] = []
        var calls: [UUID] { lock.withLock { stored } }
        var deliver: IrisEngine.InboxDeliver { { [self] id, _, _ in lock.withLock { stored.append(id) }; return .delivered } }
    }

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = true
        var on: Bool { get { lock.withLock { value } } set { lock.withLock { value = newValue } } }
    }

    private func app() async throws -> AppState {
        let app = AppState(store: try ConversationStore.inMemory(), createIfEmpty: false, emitLaunchNotices: false)
        if let sweep = app.launchInboxRedeliver { try await value(of: sweep) }
        return app
    }

    private func guest(_ app: AppState, _ clientId: String = "dev-1") -> UUID {
        app.createNewConversation(isGuest: true, guestClientId: clientId, title: "guest:\(clientId)", select: false)
    }

    private func reply(_ part: Part) -> GeminiResponse {
        GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [part]))], usageMetadata: nil)
    }

    private func engine(_ app: AppState, clientId: String = "dev-1", client: any LLMClientProtocol,
                        sessionsOn: Flag = Flag(), sink: GuestSink? = nil) async -> IrisEngine {
        let engine = IrisEngine(state: app, tier: .medium, principal: .mcpGuest, client: client, retryDelays: [],
                                protectionEnabled: false, sessionPeerCount: 0, guestClientId: clientId,
                                guestSessionsEnabled: { sessionsOn.on })
        if let sink { await engine.setGuestInboxDeliver(sink.deliver) }
        return engine
    }

    /// One guest turn that calls `inbox_item` with `args`; returns the tool's result.
    private func raise(_ app: AppState, on id: UUID, clientId: String = "dev-1", args: [String: JSONValue],
                       sessionsOn: Flag = Flag()) async -> String {
        let client = FakeLLMClient(responses: [reply(Part(functionCall: FunctionCall(name: "inbox_item", args: args, id: "c1"))),
                                               reply(Part(text: "ok"))])
        let e = await engine(app, clientId: clientId, client: client, sessionsOn: sessionsOn)
        await e.processInput("go", source: GuestSessionDriver.turnSource, conversationId: id)
        return app.conversations.first { $0.id == id }?.history.flatMap(\.parts).compactMap { part -> String? in
            guard case .string(let s)? = part.functionResponse?.response["result"] else { return nil }
            return s
        }.last ?? ""
    }

    private let basic: [String: JSONValue] = ["title": .string("Which branch?"), "situation": .string("main or next"),
                                              "response_mode": .string("freeform")]

    private func declared(_ app: AppState, on id: UUID, clientId: String = "dev-1", sessionsOn: Flag) async -> [FunctionDeclaration] {
        let client = CapturingLLMClient(reply: "ok")
        let e = await engine(app, clientId: clientId, client: client, sessionsOn: sessionsOn)
        await e.processInput("hello", source: GuestSessionDriver.turnSource, conversationId: id)
        return client.requests.first?.tools?.flatMap(\.functionDeclarations) ?? []
    }

    // MARK: declaration

    @Test("a guest turn is offered inbox_item while guest sessions are on, without route_back or notify; off, it isn't")
    func declaredOnlyWithGuestSessionsOn() async throws {
        let app = try await app()
        let id = guest(app)
        let on = Flag()
        let tools = await declared(app, on: id, sessionsOn: on)
        let inbox = try #require(tools.first { $0.name == "inbox_item" })
        #expect(inbox.description == GuestToolset.inboxItem.description, "the guest's own declaration")
        #expect(inbox.parameters?.properties?["route_back"] == nil && inbox.parameters?.properties?["notify"] == nil)
        #expect(!tools.contains { $0.name == IrisEngine.resolveInboxItemTool }, "nothing of its own to close yet")
        on.on = false
        let off = await declared(app, on: guest(app, "dev-2"), clientId: "dev-2", sessionsOn: on)
        #expect(Set(off.map(\.name)) == ["send_to_session", "list_sessions"])
    }

    @Test("with guest sessions off, a guest's inbox_item call is refused and raises nothing")
    func refusedWithGuestSessionsOff() async throws {
        let app = try await app()
        let off = Flag(); off.on = false
        let text = await raise(app, on: guest(app), args: basic, sessionsOn: off)
        // Undeclared, so #811's offered-tools check refuses it first; `guestInboxOffRefusal` backs that up.
        #expect(text.contains("is not one of the tools offered in this turn"), "\(text)")
        #expect(try app.store.inbox.openItems().isEmpty)
    }

    @Test("resolve_inbox_item is offered to a guest once it has an item of its own to close")
    func resolveOfferedOnceItOwnsOne() async throws {
        let app = try await app()
        let id = guest(app)
        _ = await raise(app, on: id, args: basic)
        let tools = await declared(app, on: id, sessionsOn: Flag())
        #expect(tools.contains { $0.name == IrisEngine.resolveInboxItemTool })
    }

    // MARK: the item

    @Test("a guest's item is its client's: chain guest:<clientId>, the guest shown as source, and tainted")
    func itemIsTheClients() async throws {
        let app = try await app()
        let text = await raise(app, on: guest(app), args: basic)
        #expect(text.hasPrefix("Recorded #"), "\(text)")
        let item = try #require(try app.store.inbox.openItems().first)
        #expect(item.ownerChain == "guest:dev-1")
        #expect(item.emitterLabel == "guest:dev-1")
        #expect(item.emitterTainted, "#813: a guest's item counts as tainted")
        #expect(item.routeBack.isEmpty && item.notify.isEmpty)
    }

    @Test("a guest naming route_back or notify is refused, and nothing is raised", arguments: ["route_back", "notify"])
    func routingArgumentsRefused(argument: String) async throws {
        let app = try await app()
        var args = basic
        args[argument] = .array([.string("role:reviewer")])
        let text = await raise(app, on: guest(app), args: args)
        #expect(text == GuestToolset.inboxArgumentRefusal(argument))
        #expect(text.contains("comes back to you alone"))
        #expect(try app.store.inbox.openItems().isEmpty)
    }

    /// Only the dispatch layer reads arguments outside the schema; the emit layer checks routing alone, so this row
    /// is what a dropped dispatch check fails.
    @Test("a guest's inbox_item with an argument outside its schema is refused at dispatch")
    func unknownArgumentRefused() async throws {
        let app = try await app()
        var args = basic
        args["attachments"] = .array([.string("/etc/hosts")])
        let text = await raise(app, on: guest(app), args: args)
        #expect(text == GuestToolset.inboxArgumentRefusal("attachments"))
        #expect(try app.store.inbox.openItems().isEmpty)
    }

    @Test("a guest can't follow up another client's thread, and another client can't follow up the guest's")
    func threadsAreTheChains() async throws {
        let app = try await app()
        _ = await raise(app, on: guest(app, "dev-1"), args: basic)
        let thread = try #require(try app.store.inbox.openItems().first?.threadId)
        var followup = basic
        followup["thread_id"] = .string(thread)
        let text = await raise(app, on: guest(app, "dev-2"), clientId: "dev-2", args: followup)
        #expect(text.contains("belongs to a different chain"), "\(text)")
        let resolve = try app.store.inbox.resolve(threadId: thread, fromChain: "guest:dev-2", note: "", at: Date())
        #expect(resolve == .failure(.notOwner))
        #expect(try app.store.inbox.openItems().count == 1)
    }

    @Test("the rate limit is the client's: its sessions share one budget, and another client keeps its own")
    func rateLimitIsPerClient() async throws {
        let app = try await app()
        let first = guest(app, "dev-1"), second = guest(app, "dev-1"), other = guest(app, "dev-2")
        for _ in 0..<PeerRateLimiter.capacity {
            guard case .allowed = app.decideInboxEmit(from: first) else { Issue.record("refused early"); return }
        }
        guard case .refused(let why) = app.decideInboxEmit(from: second) else { Issue.record("a second session refilled it"); return }
        #expect(why.contains("rate limit"))
        guard case .allowed(let chain, _, let tainted) = app.decideInboxEmit(from: other) else { Issue.record("another client was charged"); return }
        #expect(chain == "guest:dev-2" && tainted)
    }

    // MARK: the answer

    private func guestItem(_ app: AppState, routeBack: [String] = [], notify: [String] = [],
                           mode: InboxResponseMode = .freeform) throws -> InboxItem {
        let now = Date()
        let emitter = guest(app)
        let item = InboxItem(id: try app.store.inbox.newItemId(), threadId: try app.store.inbox.newThreadId(ownerChain: "guest:dev-1"),
                             ownerChain: "guest:dev-1", emitter: emitter, emitterLabel: "guest:dev-1", title: "Which branch?",
                             situation: "main or next", options: [], responseMode: mode, routeBack: routeBack, notify: notify,
                             deadline: nil, vetoDefaultOptionId: nil, emitterTainted: true, state: .open,
                             createdAt: now, lastActivityAt: now, answer: nil)
        guard case .success(let created) = try app.store.inbox.createItem(item, question: item.situation) else {
            Issue.record("createItem failed"); return item
        }
        return created
    }

    private func hostEngine(_ app: AppState, sink: GuestSink) async -> IrisEngine {
        let engine = IrisEngine(state: app, tier: .medium, principal: .main, client: FakeLLMClient(responses: []),
                                retryDelays: [], protectionEnabled: false, sessionPeerCount: 0)
        await engine.setGuestInboxDeliver(sink.deliver)
        return engine
    }

    @Test("Brian's answer goes to the guest's mailbox alone, whatever its row names, and is delivered once a poll returns it")
    func answerGoesToTheGuestsMailbox() async throws {
        let app = try await app()
        let reviewer = app.createNewConversation(select: false)
        _ = app.assignRole("reviewer", to: reviewer)
        let item = try guestItem(app, routeBack: ["role:reviewer"], notify: ["role:reviewer"])
        let guestSink = GuestSink(), host = HostSink()
        let engine = await hostEngine(app, sink: guestSink)
        let outcome = await engine.submitInboxAnswer(itemId: item.id, choice: nil, freeText: "next", deliver: host.deliver)
        #expect(outcome == .awaitingDelivery, "filed, not yet returned by a poll")
        #expect(guestSink.calls.map(\.clientId) == ["dev-1"] && guestSink.calls.map(\.target) == ["guest:dev-1"])
        #expect(guestSink.calls.first?.text.contains("next") == true)
        #expect(host.calls.isEmpty, "no host session is told of a guest's answer, by route_back or notify")
        #expect(try app.store.inbox.item(id: item.id)?.pendingTargets == ["guest:dev-1"])
        await engine.guestInboxAnswerSeen(itemId: item.id, target: "guest:dev-1")
        let after = try #require(try app.store.inbox.item(id: item.id))
        #expect(after.state == .answered && after.pendingTargets.isEmpty)
    }

    @Test("a revoked guest's answer is noted on the item, naming the client, and goes nowhere else")
    func revokedClientIsNoted() async throws {
        let app = try await app()
        let item = try guestItem(app)
        let guestSink = GuestSink(); guestSink.next = .unknownClient
        let host = HostSink()
        let engine = await hostEngine(app, sink: guestSink)
        _ = await engine.submitInboxAnswer(itemId: item.id, choice: nil, freeText: "next", deliver: host.deliver)
        let after = try #require(try app.store.inbox.item(id: item.id))
        #expect(after.state == .answered && after.pendingTargets.isEmpty)
        let note = try #require(try app.store.inbox.thread(itemId: item.id).last)
        #expect(note.kind == "undelivered" && note.body.contains("dev-1"))
        #expect(host.calls.isEmpty)
    }

    @Test("an answer the guest can't take now stays pending, and a redelivery files it again")
    func unavailableStaysPending() async throws {
        let app = try await app()
        let item = try guestItem(app)
        let guestSink = GuestSink(); guestSink.next = .unavailable
        let host = HostSink()
        let engine = await hostEngine(app, sink: guestSink)
        _ = await engine.submitInboxAnswer(itemId: item.id, choice: nil, freeText: "next", deliver: host.deliver)
        #expect(try app.store.inbox.item(id: item.id)?.state == .awaitingDelivery)
        guestSink.next = .filed
        await engine.redeliverAwaitingInbox(deliver: host.deliver)
        #expect(guestSink.calls.count == 2, "filed again once the guest's mailbox takes it")
        #expect(try app.store.inbox.item(id: item.id)?.pendingTargets == ["guest:dev-1"], "still pending until a poll returns it")
    }

    @Test("a guest's timed veto is held at its deadline, never auto-approved, and the guest is told through its mailbox")
    func guestVetoHolds() async throws {
        let app = try await app()
        let id = guest(app)
        var args = basic
        args["response_mode"] = .string("timedVeto")
        args["options"] = .array([.object(["id": .string("main"), "label": .string("main")]),
                                  .object(["id": .string("next"), "label": .string("next")])])
        args["deadline"] = .string("+20m")
        args["veto_default"] = .string("main")
        let raised = await raise(app, on: id, args: args)
        #expect(raised.contains("held at the deadline"), "\(raised)")
        let item = try #require(try app.store.inbox.openItems().first)
        let guestSink = GuestSink(), host = HostSink()
        let engine = await hostEngine(app, sink: guestSink)
        let r = await engine.evaluateInboxVetoExpiries(now: Date().addingTimeInterval(7200), deliver: host.deliver)
        #expect(r.fired == 0 && r.held == 1)
        let after = try #require(try app.store.inbox.item(id: item.id))
        #expect(after.state == .open && after.answer == nil, "the default was not applied")
        #expect(guestSink.calls.map(\.target) == ["held:guest:dev-1"], "the hold notice reached the guest's mailbox")
        #expect(host.calls.isEmpty)
    }

    @Test("a poll returning the hold notice acks only that notice: the item stays open for Brian")
    func heldNoticeAckIsInert() async throws {
        let app = try await app()
        let item = try guestItem(app)
        let engine = await hostEngine(app, sink: GuestSink())
        await engine.guestInboxAnswerSeen(itemId: item.id, target: "held:guest:dev-1")
        let after = try #require(try app.store.inbox.item(id: item.id))
        #expect(after.state == .open && after.answer == nil && after.pendingTargets.isEmpty)
    }

    @Test("a guest's chain is never gone to the stale sweep: its conversation is reaped with every session")
    func guestChainNeverGone() {
        #expect(!IrisEngine.inboxChainGone("guest:dev-1", in: []))
    }

    // MARK: the mailbox

    private final class Seen: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [(String, String)] = []
        var calls: [(String, String)] { lock.withLock { stored } }
        func record(_ a: String, _ b: String) { lock.withLock { stored.append((a, b)) } }
    }

    private func driver(_ app: AppState, seen: Seen, on: Flag = Flag()) throws -> (GuestSessionDriver, ProviderMailbox) {
        let keychain = KeychainManager(serviceSuffix: ".test-\(UUID().uuidString)", inMemory: true)
        let tokens = ProviderTokenRegistry(keychain: keychain)
        _ = try tokens.issueToken(forClientId: "dev-1")
        let mailbox = ProviderMailbox(registry: tokens)
        let sessions = GuestSessionRegistry(state: app, ttl: .seconds(900), maxLive: 4, now: { SuspendingClock.now }) { s, c in
            IrisEngine.makeGuestEngine(state: s, clientId: c, client: CapturingLLMClient(reply: "unused"), protectionEnabled: false)
        }
        let gate = ProviderRequestGate(registry: tokens, capacity: GuestSessionDriver.turnsPerHour,
                                       refillInterval: GuestSessionDriver.turnRefillInterval)
        let driver = GuestSessionDriver(state: app, registry: sessions, mailbox: mailbox, turnGate: gate, isEnabled: { on.on },
                                        inboxAnswerSeen: { seen.record($0, $1) })
        return (driver, mailbox)
    }

    @Test("the driver files one copy per item and target, and a poll that returns it is the ack, once")
    func mailboxFilingAndAck() async throws {
        let app = try await app()
        let seen = Seen()
        let (driver, mailbox) = try driver(app, seen: seen)
        #expect(await driver.deliverInboxAnswer(clientId: "dev-1", itemId: "i1", target: "guest:dev-1", text: "next") == .filed)
        #expect(await driver.deliverInboxAnswer(clientId: "dev-1", itemId: "i1", target: "guest:dev-1", text: "next") == .alreadyFiled)
        let polled = await mailbox.poll(for: "dev-1", sinceSequence: nil)
        #expect(polled.map(\.text) == ["next"] && polled.first?.from == .iris)
        // A poll whose cursor is past it returns nothing, so nothing is acked.
        driver.noteReturned(await mailbox.poll(for: "dev-1", sinceSequence: polled.last!.sequence).map(\.id))
        #expect(seen.calls.isEmpty)
        driver.noteReturned(polled.map(\.id))
        #expect(seen.calls.map(\.0) == ["i1"] && seen.calls.map(\.1) == ["guest:dev-1"])
        driver.noteReturned(polled.map(\.id))
        #expect(seen.calls.count == 1, "a repeat poll of the same message acks nothing more")
        #expect(await driver.deliverInboxAnswer(clientId: "dev-1", itemId: "i1", target: "guest:dev-1", text: "next") == .filed,
                "once acked, a later redelivery (after a restart, say) files it afresh")
    }

    @Test("the driver refuses an unregistered client, and files nothing while guest sessions are off")
    func mailboxRefusals() async throws {
        let app = try await app()
        let on = Flag()
        let (driver, mailbox) = try driver(app, seen: Seen(), on: on)
        #expect(await driver.deliverInboxAnswer(clientId: "nobody", itemId: "i1", target: "guest:nobody", text: "x") == .unknownClient)
        on.on = false
        #expect(await driver.deliverInboxAnswer(clientId: "dev-1", itemId: "i1", target: "guest:dev-1", text: "x") == .unavailable)
        #expect(await mailbox.poll(for: "dev-1", sinceSequence: nil).isEmpty)
    }
}
