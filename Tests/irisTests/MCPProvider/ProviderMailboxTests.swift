import Testing
import Foundation
@testable import IrisKit

private final class StubRegistry: MailboxRegistry, @unchecked Sendable {
    private let lock = NSLock()
    private var ids: Set<String>
    init(_ ids: [String]) { self.ids = Set(ids) }
    func isRegistered(clientId: String) -> Bool { lock.withLock { ids.contains(clientId) } }
    func revoke(_ clientId: String) { lock.withLock { _ = ids.remove(clientId) } }
}

private func registryWithClients(_ ids: [String]) -> StubRegistry { StubRegistry(ids) }

private final class DateBox: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date
    init(_ date: Date) { self.date = date }
    var value: Date {
        get { lock.withLock { date } }
        set { lock.withLock { date = newValue } }
    }
}

@Suite("ProviderMailbox")
struct ProviderMailboxTests {
    @Test("send always addresses Iris; there is no recipient argument to get wrong")
    func sendAlwaysAddressesIris() async throws {
        let mailbox = ProviderMailbox(registry: registryWithClients(["a"]))
        let message = try await mailbox.send(from: "a", text: "hello", fileRefs: [])
        #expect(message.to == .iris)
        #expect(message.from == .client("a"))
    }

    @Test("a client registered under the literal \"iris\" is still just a client — its messages are .client(\"iris\"), never .iris")
    func clientNamedIrisCannotBecomeIrisByConstruction() async throws {
        let mailbox = ProviderMailbox(registry: registryWithClients(["iris", "b"]))
        let fromImpersonator = try await mailbox.send(from: "iris", text: "pretending", fileRefs: [])
        #expect(fromImpersonator.from == .client("iris"))
        _ = try await mailbox.deliverReply(to: "b", text: "a real reply from Iris", fileRefs: [])
        let impersonatorsPoll = await mailbox.poll(for: "iris", sinceSequence: nil)
        #expect(impersonatorsPoll.isEmpty)
    }

    @Test("poll returns Iris's replies to the caller, oldest first, without deleting them, keyed by sequence not timestamp")
    func pollIsNonDestructivePull() async throws {
        let mailbox = ProviderMailbox(registry: registryWithClients(["a"]))
        _ = try await mailbox.deliverReply(to: "a", text: "first", fileRefs: [])
        _ = try await mailbox.deliverReply(to: "a", text: "second", fileRefs: [])
        let firstPoll = await mailbox.poll(for: "a", sinceSequence: nil)
        #expect(firstPoll.map(\.text) == ["first", "second"])
        let secondPoll = await mailbox.poll(for: "a", sinceSequence: nil)
        #expect(secondPoll.count == 2)
        let onlySecond = await mailbox.poll(for: "a", sinceSequence: firstPoll[0].sequence)
        #expect(onlySecond.map(\.text) == ["second"])
    }

    @Test("deliverReply to an unregistered client id throws unknownRecipient")
    func deliverReplyToUnknownClientRejected() async {
        let mailbox = ProviderMailbox(registry: registryWithClients([]))
        await #expect(throws: ProviderMailbox.MailboxError.unknownRecipient) {
            try await mailbox.deliverReply(to: "ghost", text: "hi", fileRefs: [])
        }
    }

    @Test("discover always reports Iris's own peer identity, never a roster of other clients")
    func discoverReportsIrisOnly() async throws {
        let mailbox = ProviderMailbox(registry: registryWithClients(["a", "b", "c"]))
        let identity = await mailbox.discover()
        #expect(identity.peerId == "iris")
    }

    @Test("text over the cap, too many fileRefs, and a malformed fileRef are each rejected before storing, for both send and deliverReply")
    func capsEnforced() async throws {
        let mailbox = ProviderMailbox(registry: registryWithClients(["a"]))
        let oversizedText = String(repeating: "x", count: ProviderMailbox.maxTextBytes + 1)
        await #expect(throws: ProviderMailbox.MailboxError.textTooLarge) {
            try await mailbox.send(from: "a", text: oversizedText, fileRefs: [])
        }
        await #expect(throws: ProviderMailbox.MailboxError.textTooLarge) {
            try await mailbox.deliverReply(to: "a", text: oversizedText, fileRefs: [])
        }

        let validHash = String(repeating: "a", count: 64)
        let tooManyRefs = Array(repeating: validHash, count: ProviderMailbox.maxFileRefsPerMessage + 1)
        await #expect(throws: ProviderMailbox.MailboxError.tooManyFileRefs) {
            try await mailbox.send(from: "a", text: "x", fileRefs: tooManyRefs)
        }
        await #expect(throws: ProviderMailbox.MailboxError.tooManyFileRefs) {
            try await mailbox.deliverReply(to: "a", text: "x", fileRefs: tooManyRefs)
        }

        await #expect(throws: ProviderMailbox.MailboxError.malformedFileRef) {
            try await mailbox.send(from: "a", text: "x", fileRefs: ["not-a-hash"])
        }
        await #expect(throws: ProviderMailbox.MailboxError.malformedFileRef) {
            try await mailbox.deliverReply(to: "a", text: "x", fileRefs: ["not-a-hash"])
        }
    }

    @Test("the inbox-full cap is per sender, not a single shared Iris inbox — one client filling its cap never blocks another's send")
    func inboxFullCapIsPerSender() async throws {
        let mailbox = ProviderMailbox(registry: registryWithClients(["a", "b"]))
        for _ in 0..<ProviderMailbox.maxPendingPerClient {
            _ = try await mailbox.send(from: "a", text: "x", fileRefs: [])
        }
        await #expect(throws: ProviderMailbox.MailboxError.inboxFull) {
            try await mailbox.send(from: "a", text: "one too many", fileRefs: [])
        }
        let fromB = try await mailbox.send(from: "b", text: "still fine", fileRefs: [])
        #expect(fromB.from == .client("b"))
    }

    @Test("deliverReply's own inbox-full cap is per recipient too")
    func deliverReplyInboxFullCapIsPerRecipient() async throws {
        let mailbox = ProviderMailbox(registry: registryWithClients(["a", "b"]))
        for _ in 0..<ProviderMailbox.maxPendingPerClient {
            _ = try await mailbox.deliverReply(to: "a", text: "x", fileRefs: [])
        }
        await #expect(throws: ProviderMailbox.MailboxError.inboxFull) {
            try await mailbox.deliverReply(to: "a", text: "one too many", fileRefs: [])
        }
        let toB = try await mailbox.deliverReply(to: "b", text: "still fine", fileRefs: [])
        #expect(toB.to == .client("b"))
    }

    @Test("the mailbox's public send signature has no way to assert a different sender than the resolved client id, and no way to name a recipient other than Iris")
    func fromIsNotASeparateCallerControlledField() async throws {
        let mailbox = ProviderMailbox(registry: registryWithClients(["a"]))
        let message = try await mailbox.send(from: "a", text: "x", fileRefs: [])
        #expect(message.from == .client("a"))
        #expect(message.to == .iris)
    }

    @Test("sweepExpired removes only messages past the TTL in either direction; purge removes everything for one client id")
    func sweepAndPurge() async throws {
        let base = Date()
        let clockBox = DateBox(base)
        let mailbox = ProviderMailbox(registry: registryWithClients(["a", "b"]), now: { clockBox.value })
        let oldFromA = try await mailbox.send(from: "a", text: "old", fileRefs: [])
        clockBox.value = base.addingTimeInterval(ProviderMailbox.ttl + 1)
        let freshFromB = try await mailbox.send(from: "b", text: "fresh", fileRefs: [])

        await mailbox.sweepExpired(now: clockBox.value)
        let remaining = await mailbox.poll(for: "a", sinceSequence: nil)  // "a" has no replies either way
        #expect(remaining.isEmpty)
        _ = oldFromA

        // purge removes everything for "b", both directions.
        _ = try await mailbox.deliverReply(to: "b", text: "a reply", fileRefs: [])
        await mailbox.purge(clientId: "b")
        let bsReplies = await mailbox.poll(for: "b", sinceSequence: nil)
        #expect(bsReplies.isEmpty)
        _ = freshFromB
    }

    @Test("a sender revoked after admission but before send cannot create a new message under its old id")
    func senderNoLongerRegisteredRejected() async throws {
        let registry = registryWithClients(["a"])
        let mailbox = ProviderMailbox(registry: registry)
        registry.revoke("a")
        await #expect(throws: ProviderMailbox.MailboxError.senderNoLongerRegistered) {
            try await mailbox.send(from: "a", text: "late", fileRefs: [])
        }
    }

    @Test("retract removes a specific pending message regardless of direction")
    func retractRemovesOneMessage() async throws {
        let mailbox = ProviderMailbox(registry: registryWithClients(["a"]))
        let message = try await mailbox.deliverReply(to: "a", text: "oops", fileRefs: [])
        await mailbox.retract(id: message.id)
        #expect(await mailbox.poll(for: "a", sinceSequence: nil).isEmpty)
    }
}
