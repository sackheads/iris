import Testing
import Foundation
@testable import IrisKit

/// #920 Task 1: the durable inbox store — items and their thread entries, independent of any
/// conversation (so a reply outlives a dead emitter), in the `PeerLedger` mould.
@Suite("Inbox store and item/thread model (#920)")
struct InboxStoreTests {
    private func store() throws -> ConversationStore { try ConversationStore.inMemory() }

    private func sampleItem(threadId: String, ownerChain: String = "dev-1", createdAt: Date = Date()) -> InboxItem {
        InboxItem(id: UUID().uuidString, threadId: threadId, ownerChain: ownerChain,
                  emitter: UUID(), emitterLabel: "dev-1",
                  title: "Ship the thing?", situation: "Here is the full context.",
                  options: [InboxOption(id: "a", label: "Ship it", pros: ["fast"], cons: ["risky"]),
                            InboxOption(id: "b", label: "Wait", pros: ["safer"], cons: ["slow"])],
                  responseMode: .optionsAndFreeform, routeBack: ["dev-1"], notify: ["planner"],
                  deadline: nil, vetoDefaultOptionId: nil, emitterTainted: false, state: .open,
                  createdAt: createdAt, lastActivityAt: createdAt, answer: nil)
    }

    @discardableResult
    private func create(_ store: ConversationStore, _ item: InboxItem, question: String = "Here is the full context.") throws -> InboxItem {
        guard case .success(let created) = try store.inbox.createItem(item, question: question) else {
            Issue.record("createItem failed for \(item.threadId)")
            return item
        }
        return created
    }

    @Test("the migration creates both tables, empty")
    func migrationCreatesInboxTables() throws {
        let s = try store()
        #expect(try s.inbox.openItems().isEmpty)
    }

    @Test("createItem then item(id:) round-trips every field; thread has one question entry")
    func createAndReadItem() throws {
        let s = try store()
        let threadId = try s.inbox.newThreadId(ownerChain: "dev-1")
        let item = sampleItem(threadId: threadId)
        try create(s, item)

        let read = try #require(try s.inbox.item(id: item.id))
        #expect(read.id == item.id)
        #expect(read.threadId == item.threadId)
        #expect(read.ownerChain == item.ownerChain)
        #expect(read.emitter == item.emitter)
        #expect(read.emitterLabel == item.emitterLabel)
        #expect(read.title == item.title)
        #expect(read.situation == item.situation)
        #expect(read.options == item.options)
        #expect(read.responseMode == item.responseMode)
        #expect(read.routeBack == item.routeBack)
        #expect(read.notify == item.notify)
        #expect(read.deadline == item.deadline)
        #expect(read.vetoDefaultOptionId == item.vetoDefaultOptionId)
        #expect(read.emitterTainted == item.emitterTainted)
        #expect(read.state == .open)
        #expect(read.answer == nil)

        let thread = try s.inbox.thread(itemId: item.id)
        #expect(thread.count == 1)
        #expect(thread[0].kind == "question")
        #expect(thread[0].itemId == item.id)
    }

    @Test("newThreadId's id carries the sanitized ownerChain as its prefix")
    func newThreadIdNamespacedByOwner() throws {
        let s = try store()
        let threadId = try s.inbox.newThreadId(ownerChain: "dev-1")
        #expect(threadId.hasPrefix("dev1-"), "expected the sanitized owner as the prefix, got \(threadId)")
    }

    @Test("a second create for the same threadId is refused, never takes over ownership (#920 review: finding 1)")
    func createOnExistingThreadRefused() throws {
        let s = try store()
        let threadId = try s.inbox.newThreadId(ownerChain: "dev-1")
        let original = sampleItem(threadId: threadId, ownerChain: "dev-1")
        try create(s, original)

        // The same owner trying again is refused the same way: creating is for a new thread only.
        let sameOwnerRetry = sampleItem(threadId: threadId, ownerChain: "dev-1")
        let r1 = try s.inbox.createItem(sameOwnerRetry, question: "again")
        guard case .failure(let e1) = r1 else { Issue.record("expected failure, got \(r1)"); return }
        #expect(e1 == .threadAlreadyExists)

        // A foreign chain racing an earlier createdAt must not become the owner either (the
        // original attack: hijack by writing an earlier-dated row into the victim's threadId).
        let hijack = sampleItem(threadId: threadId, ownerChain: "dev-2", createdAt: original.createdAt.addingTimeInterval(-3600))
        let r2 = try s.inbox.createItem(hijack, question: "I own this now")
        guard case .failure(let e2) = r2 else { Issue.record("expected failure, got \(r2)"); return }
        #expect(e2 == .threadAlreadyExists)

        // The real owner's followup still works; dev-2 never got in.
        let followup = try s.inbox.appendFollowup(threadId: threadId, fromChain: "dev-1", author: "dev-1", body: "mine", at: Date())
        guard case .success = followup else { Issue.record("expected success, got \(followup)"); return }
        let stillOwner = try #require(try s.inbox.item(id: original.id))
        #expect(stillOwner.ownerChain == "dev-1")
    }

    @Test("a followup from the owning chain reopens an answered item and appends")
    func followupByOwnerReopensAndAppends() throws {
        let s = try store()
        let threadId = try s.inbox.newThreadId(ownerChain: "dev-1")
        let item = sampleItem(threadId: threadId)
        try create(s, item)

        let answered = try s.inbox.recordAnswer(itemId: item.id, answer: InboxAnswer(chosenOptionId: "a", freeText: nil, at: Date()))
        guard case .success = answered else { Issue.record("expected success, got \(answered)"); return }
        #expect(try s.inbox.item(id: item.id)?.state == .answered)

        let result = try s.inbox.appendFollowup(threadId: threadId, fromChain: "dev-1", author: "dev-1",
                                                 body: "actually, hold on", at: Date())
        guard case .success = result else { Issue.record("expected success, got \(result)"); return }

        let read = try #require(try s.inbox.item(id: item.id))
        #expect(read.state == .open)

        let thread = try s.inbox.thread(itemId: item.id)
        #expect(thread.map(\.kind) == ["question", "answer", "followup"])
    }

    @Test("a followup from a foreign chain is refused: thread ownership (#920 review focus)")
    func followupByForeignChainRefused() throws {
        let s = try store()
        let threadId = try s.inbox.newThreadId(ownerChain: "dev-1")
        let item = sampleItem(threadId: threadId, ownerChain: "dev-1")
        try create(s, item)
        let answered = try s.inbox.recordAnswer(itemId: item.id, answer: InboxAnswer(chosenOptionId: "a", freeText: nil, at: Date()))
        guard case .success = answered else { Issue.record("expected success, got \(answered)"); return }

        let result = try s.inbox.appendFollowup(threadId: threadId, fromChain: "dev-2", author: "dev-2",
                                                 body: "I'll reopen this myself", at: Date())
        guard case .failure(let error) = result else { Issue.record("expected failure, got \(result)"); return }
        #expect(error == .notOwner)

        let thread = try s.inbox.thread(itemId: item.id)
        #expect(thread.map(\.kind) == ["question", "answer"], "the foreign followup must not have appended")
        #expect(try s.inbox.item(id: item.id)?.state == .answered, "the foreign followup must not have reopened it")
    }

    @Test("a followup on a closed thread is refused: closing is final")
    func followupOnClosedThreadRefused() throws {
        let s = try store()
        let threadId = try s.inbox.newThreadId(ownerChain: "dev-1")
        let item = sampleItem(threadId: threadId)
        try create(s, item)
        try s.inbox.setState(itemId: item.id, .closed)

        let result = try s.inbox.appendFollowup(threadId: threadId, fromChain: "dev-1", author: "dev-1", body: "reopen?", at: Date())
        guard case .failure(let error) = result else { Issue.record("expected failure, got \(result)"); return }
        #expect(error == .itemClosed)
    }

    @Test("recordAnswer on an unknown item is refused and leaves no orphan thread entry (#920 review: finding 4)")
    func recordAnswerOnUnknownItemRefused() throws {
        let s = try store()
        let result = try s.inbox.recordAnswer(itemId: "nope", answer: InboxAnswer(chosenOptionId: "a", freeText: nil, at: Date()))
        guard case .failure(let error) = result else { Issue.record("expected failure, got \(result)"); return }
        #expect(error == .unknownItem)
        #expect(try s.inbox.thread(itemId: "nope").isEmpty, "no orphan thread entry for an item that doesn't exist")
    }

    @Test("recordAnswer on a closed item is refused, never revives it")
    func recordAnswerOnClosedItemRefused() throws {
        let s = try store()
        let threadId = try s.inbox.newThreadId(ownerChain: "dev-1")
        let item = sampleItem(threadId: threadId)
        try create(s, item)
        try s.inbox.setState(itemId: item.id, .closed)

        let result = try s.inbox.recordAnswer(itemId: item.id, answer: InboxAnswer(chosenOptionId: "a", freeText: nil, at: Date()))
        guard case .failure(let error) = result else { Issue.record("expected failure, got \(result)"); return }
        #expect(error == .itemClosed)
        #expect(try s.inbox.item(id: item.id)?.state == .closed)
    }

    @Test("setState on an unknown item is refused")
    func setStateOnUnknownItemRefused() throws {
        let s = try store()
        let result = try s.inbox.setState(itemId: "nope", .closed)
        guard case .failure(let error) = result else { Issue.record("expected failure, got \(result)"); return }
        #expect(error == .unknownItem)
    }

    @Test("a row this build cannot read is skipped, never traps the whole load (#920 review focus)")
    func malformedRowSkipped() throws {
        let s = try store()
        let threadId = try s.inbox.newThreadId(ownerChain: "dev-1")
        let good = sampleItem(threadId: threadId)
        try create(s, good)

        // A row this build doesn't know how to decode: a responseMode this build never wrote.
        try s.inbox.rawInsertForTesting(id: "bad-mode", threadId: "bad-thread-1", responseMode: "some_future_mode")
        // An unknown state value.
        try s.inbox.rawInsertForTesting(id: "bad-state", threadId: "bad-thread-2", state: "some_future_state")
        // A non-UUID emitter.
        try s.inbox.rawInsertForTesting(id: "bad-emitter", threadId: "bad-thread-3", emitter: "not-a-uuid")
        // Malformed optionsJSON.
        try s.inbox.rawInsertForTesting(id: "bad-options", threadId: "bad-thread-4", optionsJSON: "not json")
        // An answerJSON that fails to decode: the row is dropped rather than coming back with a
        // silently empty answer while the state still says "answered" (#920 review: finding 3).
        try s.inbox.rawInsertForTesting(id: "bad-answer", threadId: "bad-thread-5",
                                        state: InboxItemState.answered.rawValue, answerJSON: "not json")

        let items = try s.inbox.openItems()
        #expect(items.count == 1)
        #expect(items[0].id == good.id)
    }

    @Test("InboxOption and InboxAnswer decode missing/extra fields defensively (Invariant 1, #920 review: finding 3)")
    func optionAndAnswerDecodeDefensively() throws {
        let optionJSON = Data(#"{"id":"a","label":"Ship it"}"#.utf8)
        let option = try JSONDecoder().decode(InboxOption.self, from: optionJSON)
        #expect(option.pros == [] && option.cons == [])

        let answerJSON = Data(#"{"at":815788800.0}"#.utf8)
        let answer = try JSONDecoder().decode(InboxAnswer.self, from: answerJSON)
        #expect(answer.chosenOptionId == nil && answer.freeText == nil)
    }
}
