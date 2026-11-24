import Testing
import Foundation
@testable import IrisKit

/// #920 slice 4a: what a timed veto's three outcomes deliver. Brian's Veto is his explicit decision, never
/// silence (F2); Approve now is his choice of the default, on the answer's own path; a default that ran out is
/// framed as automatic everywhere, and flagged when it was applied long after its deadline.
@MainActor
@Suite("Inbox veto semantics (#920 slice 4a)", .timeLimit(.minutes(1)))
struct InboxVetoSemanticsTests {
    private final class Sink: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [(UUID, String)] = []
        var calls: [(UUID, String)] { lock.withLock { stored } }
        var deliver: IrisEngine.InboxDeliver { { [self] id, text, _ in lock.withLock { stored.append((id, text)) }; return .delivered } }
    }

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func setup() async throws -> (AppState, IrisEngine, UUID) {
        let app = AppState(); app.conversations.removeAll()
        if let sweep = app.launchInboxRedeliver { try await value(of: sweep) }
        let engine = IrisEngine(state: app, tier: .medium, principal: .main, client: FakeLLMClient(responses: []),
                                retryDelays: [], protectionEnabled: false, sessionPeerCount: 0)
        return (app, engine, app.createNewConversation(select: false))
    }

    private func item(_ app: AppState, emitter: UUID, mode: InboxResponseMode = .timedVeto, deadline: Date? = nil) throws -> InboxItem {
        let item = InboxItem(id: try app.store.inbox.newItemId(), threadId: try app.store.inbox.newThreadId(ownerChain: emitter.uuidString),
                             ownerChain: emitter.uuidString, emitter: emitter, emitterLabel: "dev-1", title: "Ship at 5?",
                             situation: "Ships unless vetoed.",
                             options: [InboxOption(id: "a", label: "Ship", pros: [], cons: []), InboxOption(id: "b", label: "Hold", pros: [], cons: [])],
                             responseMode: mode, routeBack: [emitter.uuidString], notify: [], deadline: deadline ?? t0.addingTimeInterval(600),
                             vetoDefaultOptionId: mode == .timedVeto ? "a" : nil, emitterTainted: false, state: .open,
                             createdAt: t0, lastActivityAt: t0, answer: nil)
        guard case .success(let created) = try app.store.inbox.createItem(item, question: item.situation) else {
            Issue.record("createItem failed"); return item
        }
        return created
    }

    // MARK: Veto

    @Test("Veto delivers Brian's explicit decision: the default vetoed, no option chosen, his words")
    func vetoIsExplicit() async throws {
        let (app, engine, emitter) = try await setup()
        let veto = try item(app, emitter: emitter)
        let sink = Sink()
        #expect(await engine.vetoInboxItem(itemId: veto.id, note: "not before the freeze lifts", deliver: sink.deliver) == .delivered(1))
        let text = try #require(sink.calls.first?.1)
        #expect(sink.calls.map(\.0) == [emitter])
        #expect(text.contains("Brian's decision") && text.contains("He vetoed the default the session proposed, option 1:"))
        #expect(text.contains("He chose no option") && text.contains("He wrote: not before the freeze lifts"))
        let stored = try #require(try app.store.inbox.item(id: veto.id)?.answer)
        #expect(stored.vetoed && stored.chosenOptionId == nil && !stored.automatic)
        #expect(try app.store.inbox.thread(itemId: veto.id).last?.author == "brian")
    }

    @Test("a Veto with no words is still a stated veto, not silence")
    func vetoWithoutNote() async throws {
        let (app, engine, emitter) = try await setup()
        let veto = try item(app, emitter: emitter)
        let sink = Sink()
        _ = await engine.vetoInboxItem(itemId: veto.id, note: "   ", deliver: sink.deliver)
        let text = try #require(sink.calls.first?.1)
        #expect(text.contains("He vetoed") && !text.contains("He wrote"))
        #expect(try app.store.inbox.item(id: veto.id)?.answer?.freeText == nil)
    }

    @Test("Veto is refused for an item that isn't a timed veto, and once the item has an answer")
    func vetoRefusals() async throws {
        let (app, engine, emitter) = try await setup()
        let plain = try item(app, emitter: emitter, mode: .optionsAndFreeform)
        let sink = Sink()
        #expect(await engine.vetoInboxItem(itemId: plain.id, note: nil, deliver: sink.deliver) == .refused("Only a timed veto can be vetoed."))
        let veto = try item(app, emitter: emitter)
        _ = await engine.vetoInboxItem(itemId: veto.id, note: nil, deliver: sink.deliver)
        #expect(await engine.vetoInboxItem(itemId: veto.id, note: nil, deliver: sink.deliver) == .refused("This item already has an answer."))
    }

    @Test("a vetoed item's deadline passing later fires nothing")
    func vetoStopsTheTimer() async throws {
        let (app, engine, emitter) = try await setup()
        let veto = try item(app, emitter: emitter, deadline: t0)
        let sink = Sink()
        _ = await engine.vetoInboxItem(itemId: veto.id, note: nil, deliver: sink.deliver)
        let r = await engine.evaluateInboxVetoExpiries(now: t0.addingTimeInterval(5), deliver: sink.deliver)
        #expect(r.fired == 0 && sink.calls.count == 1)
    }

    // MARK: Approve now

    @Test("Approve now is Brian's choice of the default, delivered as his answer, and ends the timer")
    func approveNow() async throws {
        let (app, engine, emitter) = try await setup()
        let veto = try item(app, emitter: emitter, deadline: t0)
        let sink = Sink()
        #expect(await engine.approveInboxVetoNow(itemId: veto.id, deliver: sink.deliver) == .delivered(1))
        let text = try #require(sink.calls.first?.1)
        #expect(text.contains("Brian's decision") && text.contains("He chose option 1."))
        let stored = try #require(try app.store.inbox.item(id: veto.id)?.answer)
        #expect(stored.chosenOptionId == "a" && !stored.automatic && !stored.vetoed)
        #expect(await engine.evaluateInboxVetoExpiries(now: t0.addingTimeInterval(5), deliver: sink.deliver).fired == 0)
    }

    @Test("Approve now is refused for an item without a timed-veto default")
    func approveNowRefused() async throws {
        let (app, engine, emitter) = try await setup()
        let plain = try item(app, emitter: emitter, mode: .optionsAndFreeform)
        #expect(await engine.approveInboxVetoNow(itemId: plain.id, deliver: Sink().deliver)
                == .refused("Only a timed veto with a default can be approved early."))
    }

    // MARK: the automatic answer

    @Test("a default that fires on time is automatic, not flagged; one fired long after is flagged, everywhere")
    func automaticAndAway() async throws {
        let (app, engine, emitter) = try await setup()
        let onTime = try item(app, emitter: emitter, deadline: t0)
        let late = try item(app, emitter: emitter, deadline: t0.addingTimeInterval(-7200))
        let sink = Sink()
        let r = await engine.evaluateInboxVetoExpiries(now: t0.addingTimeInterval(20), deliver: sink.deliver)
        #expect(r.fired == 2)
        let onTimeAnswer = try #require(try app.store.inbox.item(id: onTime.id)?.answer)
        let lateAnswer = try #require(try app.store.inbox.item(id: late.id)?.answer)
        #expect(onTimeAnswer.automatic && !onTimeAnswer.decidedWhileAway)
        #expect(lateAnswer.automatic && lateAnswer.decidedWhileAway)
        let lateFrame = IrisEngine.inboxAnswerFrame(item: late, answer: lateAnswer, echoed: "x")
        #expect(lateFrame.contains("took effect automatically") && lateFrame.contains("while Iris was not running"))
        #expect(!lateFrame.contains("Brian's decision") && !lateFrame.contains("He chose"), "no Brian-authority words")
        #expect(!IrisEngine.inboxAnswerFrame(item: onTime, answer: onTimeAnswer, echoed: "x").contains("not running"))
        #expect(IrisEngine.inboxNotifyFrame(item: late, answer: lateAnswer, echoedTitle: "x").contains("not running"))
    }

    // MARK: the summary Brian sees

    @Test("the answered summary says You only for Brian's own answers")
    func summary() throws {
        let item = InboxItem(id: "1", threadId: "t", ownerChain: "c", emitter: UUID(), emitterLabel: "dev-1", title: "Ship?",
                             situation: "s", options: [InboxOption(id: "a", label: "Ship", pros: [], cons: [])],
                             responseMode: .timedVeto, routeBack: [], notify: [], deadline: t0, vetoDefaultOptionId: "a",
                             emitterTainted: false, state: .answered, createdAt: t0, lastActivityAt: t0, answer: nil)
        let automatic = InboxUIModel.answerSummary(InboxAnswer(chosenOptionId: "a", freeText: nil, at: t0, automatic: true), item: item)
        #expect(automatic == ["No answer by the deadline: the default, Ship, took effect automatically. Nobody chose it."])
        #expect(!automatic.joined().contains("You"))
        let away = InboxUIModel.answerSummary(InboxAnswer(chosenOptionId: "a", freeText: nil, at: t0, automatic: true, decidedWhileAway: true), item: item)
        #expect(away.count == 2 && away[1].hasPrefix("Decided while you were away"))
        #expect(InboxUIModel.answerSummary(InboxAnswer(chosenOptionId: nil, freeText: "later", at: t0, vetoed: true), item: item)
                == ["You vetoed the default, Ship.", "You wrote: later"])
        #expect(InboxUIModel.answerSummary(InboxAnswer(chosenOptionId: "a", freeText: nil, at: t0), item: item) == ["You chose: Ship"])
    }

    @Test("an answer stored before these fields reads as neither vetoed nor late (Invariant 1)")
    func oldAnswerDecodes() throws {
        let json = #"{"chosenOptionId":"a","at":800000000,"automatic":true}"#
        let answer = try JSONDecoder().decode(InboxAnswer.self, from: Data(json.utf8))
        #expect(answer.automatic && !answer.vetoed && !answer.decidedWhileAway)
    }
}
