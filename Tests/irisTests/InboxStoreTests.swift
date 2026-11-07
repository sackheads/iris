import Testing
import Foundation
@testable import IrisKit

/// #920 Task 1: the durable inbox store — items and their thread entries, independent of any
/// conversation (so a reply outlives a dead emitter), in the `PeerLedger` mould.
@Suite("Inbox store and item/thread model (#920)")
struct InboxStoreTests {
    private func store() throws -> ConversationStore { try ConversationStore.inMemory() }

    private func sampleItem(threadId: String, ownerChain: String = "dev-1") -> InboxItem {
        InboxItem(id: UUID().uuidString, threadId: threadId, ownerChain: ownerChain,
                  emitter: UUID(), emitterLabel: "dev-1",
                  title: "Ship the thing?", situation: "Here is the full context.",
                  options: [InboxOption(id: "a", label: "Ship it", pros: ["fast"], cons: ["risky"]),
                            InboxOption(id: "b", label: "Wait", pros: ["safer"], cons: ["slow"])],
                  responseMode: .optionsAndFreeform, routeBack: ["dev-1"], notify: ["planner"],
                  deadline: nil, vetoDefaultOptionId: nil, emitterTainted: false, state: .open,
                  createdAt: Date(), lastActivityAt: Date(), answer: nil)
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
        try s.inbox.createItem(item, question: "Here is the full context.")

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

    @Test("a followup from the owning chain reopens an answered item and appends")
    func followupByOwnerReopensAndAppends() throws {
        let s = try store()
        let threadId = try s.inbox.newThreadId(ownerChain: "dev-1")
        let item = sampleItem(threadId: threadId)
        try s.inbox.createItem(item, question: "Here is the full context.")

        try s.inbox.recordAnswer(itemId: item.id, answer: InboxAnswer(chosenOptionId: "a", freeText: nil, at: Date()))
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
        try s.inbox.createItem(item, question: "Here is the full context.")
        try s.inbox.recordAnswer(itemId: item.id, answer: InboxAnswer(chosenOptionId: "a", freeText: nil, at: Date()))

        let result = try s.inbox.appendFollowup(threadId: threadId, fromChain: "dev-2", author: "dev-2",
                                                 body: "I'll reopen this myself", at: Date())
        guard case .failure(let error) = result else { Issue.record("expected failure, got \(result)"); return }
        #expect(error == .notOwner)

        let thread = try s.inbox.thread(itemId: item.id)
        #expect(thread.map(\.kind) == ["question", "answer"], "the foreign followup must not have appended")
        #expect(try s.inbox.item(id: item.id)?.state == .answered, "the foreign followup must not have reopened it")
    }

    @Test("a row this build cannot read is skipped, never traps the whole load (#920 review focus)")
    func malformedRowSkipped() throws {
        let s = try store()
        let threadId = try s.inbox.newThreadId(ownerChain: "dev-1")
        let good = sampleItem(threadId: threadId)
        try s.inbox.createItem(good, question: "Here is the full context.")

        // A row this build doesn't know how to decode: a responseMode this build never wrote.
        try s.inbox.rawInsertForTesting(id: "bad-row", threadId: "bad-thread", ownerChain: "dev-9",
                                        responseMode: "some_future_mode")

        let items = try s.inbox.openItems()
        #expect(items.count == 1)
        #expect(items[0].id == good.id)
    }
}
