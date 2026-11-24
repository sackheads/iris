import Testing
import Foundation
@testable import IrisKit

/// #920 slice 1: the chain that raised an item closes it once the decision is consumed
/// (`resolve_inbox_item`, status `.resolved`), and `inbox_item` is no longer declared on every plain
/// turn (Invariant 6): only to a role-bound session, the pinned Iris, or a session with an item of its
/// own still open, sticky once declared.
@MainActor
@Suite("Inbox resolve and the emit gate (#920 slice 1)", .timeLimit(.minutes(1)))
struct InboxResolveTests {
    private func item(threadId: String, ownerChain: String, state: InboxItemState = .open) -> InboxItem {
        InboxItem(id: UUID().uuidString, threadId: threadId, ownerChain: ownerChain, emitter: UUID(), emitterLabel: "dev-1",
                  title: "Ship it?", situation: "The context.", options: [InboxOption(id: "a", label: "Ship", pros: [], cons: [])],
                  responseMode: .optionsAndFreeform, routeBack: [], notify: [], deadline: nil, vetoDefaultOptionId: nil,
                  emitterTainted: false, state: state, createdAt: Date(), lastActivityAt: Date(), answer: nil)
    }

    private func offered(_ app: AppState, _ id: UUID) async -> Set<String> {
        let client = CapturingLLMClient(reply: "ok")
        let engine = IrisEngine(state: app, tier: .medium, principal: .main, client: client, retryDelays: [], sessionPeerCount: 0)
        await engine.processInput("hello", source: "UI", conversationId: id)
        return Set(client.requests.first?.tools?.flatMap { $0.functionDeclarations.map(\.name) } ?? [])
    }

    private func run(_ call: FunctionCall, on app: AppState, as id: UUID, sticky: Bool = false) async -> String {
        if sticky { app.stickyTools.record(["inbox_item", IrisEngine.resolveInboxItemTool], for: id) }
        let first = GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [Part(functionCall: call)]))], usageMetadata: nil)
        let final = GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [Part(text: "ok")]))], usageMetadata: nil)
        let engine = IrisEngine(state: app, tier: .medium, principal: .main, client: FakeLLMClient(responses: [first, final]),
                                retryDelays: [], protectionEnabled: false, sessionPeerCount: 0)
        await engine.processInput("go", source: "UI", conversationId: id)
        return (app.conversations.first { $0.id == id }?.history ?? []).flatMap(\.parts)
            .compactMap { $0.functionResponse?.response["result"]?.stringValue }.last ?? ""
    }

    private func resolveCall(_ threadId: String, note: String = "merged") -> FunctionCall {
        FunctionCall(name: IrisEngine.resolveInboxItemTool, args: ["thread_id": .string(threadId), "note": .string(note)], id: "r1")
    }

    private func setRole(_ app: AppState, _ id: UUID, _ role: String) {
        if let i = app.conversations.firstIndex(where: { $0.id == id }) { app.conversations[i].role = role }
    }

    // MARK: the gate

    @Test("the gate: a role, the pinned Iris, a /goal, an open item of its own, or sticky; never a subagent or background turn")
    func gateTable() {
        func gate(_ p: Principal = .main, unattended: Bool = false, role: String? = nil, pinned: Bool = false,
                  goal: Bool = false, owns: Bool = false, sticky: Set<String> = []) -> Bool {
            IrisEngine.inboxItemDeclared(principal: p, isUnattended: unattended, role: role, isPinned: pinned,
                                         hasActiveGoal: goal, ownsUnfinishedItem: owns, sticky: sticky)
        }
        #expect(!gate(), "a plain session's plain turn")
        #expect(gate(role: "planner"))
        #expect(gate(pinned: true))
        #expect(gate(goal: true), "a conversation working a /goal (Brian, 2026-11-23)")
        #expect(gate(owns: true))
        #expect(gate(sticky: ["inbox_item"]))
        #expect(!gate(.subagent, role: "planner"))
        #expect(!gate(.evaluator, pinned: true))
        #expect(!gate(unattended: true, role: "planner"))
    }

    @Test("a plain session is offered neither tool; a role-bound one inbox_item; one owning an open item both")
    func declarationsOnARealTurn() async throws {
        let app = AppState(); app.conversations.removeAll()
        let plain = app.createNewConversation(select: false)
        let roleBound = app.createNewConversation(select: false)
        setRole(app, roleBound, "planner")
        let owner = app.createNewConversation(select: false)
        _ = try app.store.inbox.createItem(item(threadId: "t-own", ownerChain: owner.uuidString), question: "q")

        let p = await offered(app, plain)
        #expect(!p.contains("inbox_item") && !p.contains(IrisEngine.resolveInboxItemTool), "\(p.sorted())")
        let r = await offered(app, roleBound)
        #expect(r.contains("inbox_item") && !r.contains(IrisEngine.resolveInboxItemTool), "\(r.sorted())")
        let o = await offered(app, owner)
        #expect(o.contains("inbox_item") && o.contains(IrisEngine.resolveInboxItemTool), "\(o.sorted())")
    }

    @Test("a sticky inbox_item on a session that no longer qualifies is refused at dispatch")
    func offStateEmitIsRefused() async {
        let app = AppState(); app.conversations.removeAll()
        let plain = app.createNewConversation(select: false)
        let call = FunctionCall(name: "inbox_item", args: ["title": .string("t"), "situation": .string("s"),
                                                           "response_mode": .string("freeform")], id: "e1")
        let result = await run(call, on: app, as: plain, sticky: true)
        #expect(result == IrisEngine.inboxItemOffStateRefusal, Comment(rawValue: result))
        #expect(((try? app.store.inbox.openItems()) ?? []).isEmpty, "nothing was raised")
    }

    // MARK: resolve

    @Test("the owner chain resolves its item: it leaves the open list, and the thread records why")
    func ownerResolves() async throws {
        let app = AppState(); app.conversations.removeAll()
        let id = app.createNewConversation(select: false)
        setRole(app, id, "planner")
        guard case .success(let created) = try app.store.inbox.createItem(item(threadId: "t-1", ownerChain: "planner"), question: "q") else {
            Issue.record("createItem failed"); return
        }
        let result = await run(resolveCall("t-1", note: "merged in #1360"), on: app, as: id)
        #expect(result == "Closed inbox item t-1.", Comment(rawValue: result))
        #expect(try app.store.inbox.item(id: created.id)?.state == .resolved)
        #expect(try app.store.inbox.openItems().isEmpty)
        let last = try app.store.inbox.thread(itemId: created.id).last
        #expect(last?.kind == "resolved" && last?.body == "merged in #1360" && last?.author == "planner")
    }

    @Test("another chain cannot resolve it, and an unknown thread is refused")
    func foreignChainRefused() async throws {
        let app = AppState(); app.conversations.removeAll()
        let id = app.createNewConversation(select: false)
        setRole(app, id, "dev-2")
        guard case .success(let created) = try app.store.inbox.createItem(item(threadId: "t-2", ownerChain: "planner"), question: "q") else {
            Issue.record("createItem failed"); return
        }
        // Sticky, so the call reaches `resolve`: what refuses it is the owner check, not the declaration gate.
        let foreign = await run(resolveCall("t-2"), on: app, as: id, sticky: true)
        #expect(foreign == "Not closed: that item belongs to a different chain.", Comment(rawValue: foreign))
        #expect(try app.store.inbox.item(id: created.id)?.state == .open)
        let unknown = await run(resolveCall("no-such-thread"), on: app, as: id, sticky: true)
        #expect(unknown == "Not closed: no inbox item has that thread_id.", Comment(rawValue: unknown))
    }

    @Test("an item whose answer is still being delivered cannot be resolved, so the reply is not dropped")
    func awaitingDeliveryRefused() throws {
        let store = try ConversationStore.inMemory()
        guard case .success(let created) = try store.inbox.createItem(item(threadId: "t-3", ownerChain: "planner"), question: "q") else {
            Issue.record("createItem failed"); return
        }
        _ = try store.inbox.submitAnswer(itemId: created.id, answer: InboxAnswer(chosenOptionId: "a", freeText: nil, at: Date()),
                                         pendingTargets: ["role:planner"])
        #expect(try store.inbox.item(id: created.id)?.state == .awaitingDelivery)
        #expect(try store.inbox.resolve(threadId: "t-3", fromChain: "planner", note: "", at: Date()) == .failure(.awaitingDelivery))
    }

    @Test("a resolved item is final: no second resolve, no followup, no answer")
    func resolvedIsFinal() throws {
        let store = try ConversationStore.inMemory()
        guard case .success(let created) = try store.inbox.createItem(item(threadId: "t-4", ownerChain: "planner"), question: "q") else {
            Issue.record("createItem failed"); return
        }
        #expect(try store.inbox.resolve(threadId: "t-4", fromChain: "planner", note: "done", at: Date()) == .success(created.id))
        #expect(try store.inbox.resolve(threadId: "t-4", fromChain: "planner", note: "again", at: Date()) == .failure(.itemClosed))
        #expect(try store.inbox.appendFollowup(threadId: "t-4", fromChain: "planner", author: "planner", body: "more", at: Date())
                == .failure(.itemClosed))
        let answered = try store.inbox.submitAnswer(itemId: created.id, answer: InboxAnswer(chosenOptionId: "a", freeText: nil, at: Date()),
                                                    pendingTargets: [])
        guard case .failure(.itemClosed) = answered else {
            Issue.record("a resolved item took an answer: \(answered)"); return
        }
        #expect(try store.inbox.hasUnfinishedItems(ownerChain: "planner") == false, "nothing left to keep the tools declared")
    }
}
