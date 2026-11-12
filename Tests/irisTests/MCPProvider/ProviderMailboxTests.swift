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
    @Test("send always addresses Iris; there is no recipient or sender argument to get wrong")
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

        // Shares ProviderArtifactStore.isValidHash, so these pin the same ASCII-only guard
        // #1075's finding 1 was about, here too — not just "some string that isn't hex."
        let fullwidth = String(repeating: "\u{FF41}", count: 64)
        await #expect(throws: ProviderMailbox.MailboxError.malformedFileRef) {
            try await mailbox.send(from: "a", text: "x", fileRefs: [fullwidth])
        }
        let uppercase = String(repeating: "A", count: 64)
        await #expect(throws: ProviderMailbox.MailboxError.malformedFileRef) {
            try await mailbox.send(from: "a", text: "x", fileRefs: [uppercase])
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

    /// Neither `poll` nor `status` can observe a message addressed *to* Iris, so these two
    /// tests use `maxPendingPerClient` as the observable instead: if a sent message were still
    /// counted against the cap, the next `send` would throw `.inboxFull`.
    @Test("sweepExpired actually removes past-TTL messages sent to Iris, freeing the sender's cap")
    func sweepExpiredFreesTheSenderCap() async throws {
        let base = Date()
        let clockBox = DateBox(base)
        let mailbox = ProviderMailbox(registry: registryWithClients(["a"]), now: { clockBox.value })
        for _ in 0..<ProviderMailbox.maxPendingPerClient {
            _ = try await mailbox.send(from: "a", text: "x", fileRefs: [])
        }
        await #expect(throws: ProviderMailbox.MailboxError.inboxFull) {
            try await mailbox.send(from: "a", text: "one too many", fileRefs: [])
        }

        clockBox.value = base.addingTimeInterval(ProviderMailbox.ttl + 1)
        await mailbox.sweepExpired(now: clockBox.value)

        // If sweepExpired were a no-op, this would still throw .inboxFull.
        let afterSweep = try await mailbox.send(from: "a", text: "fits now", fileRefs: [])
        #expect(afterSweep.from == .client("a"))
    }

    @Test("purge removes a client's own sent-to-Iris messages too, not only Iris's replies to it")
    func purgeRemovesBothDirections() async throws {
        let mailbox = ProviderMailbox(registry: registryWithClients(["a"]))
        for _ in 0..<ProviderMailbox.maxPendingPerClient {
            _ = try await mailbox.send(from: "a", text: "x", fileRefs: [])
        }
        await #expect(throws: ProviderMailbox.MailboxError.inboxFull) {
            try await mailbox.send(from: "a", text: "one too many", fileRefs: [])
        }

        await mailbox.purge(clientId: "a")

        // If purge only cleared Iris's replies to "a" (the `to` side), this would still throw
        // .inboxFull — a later holder of the id "a" would inherit the old occupant's full inbox.
        let afterPurge = try await mailbox.send(from: "a", text: "fits now", fileRefs: [])
        #expect(afterPurge.from == .client("a"))
    }

    @Test("purge also removes Iris's replies to the client")
    func purgeRemovesRepliesToo() async throws {
        let mailbox = ProviderMailbox(registry: registryWithClients(["a"]))
        _ = try await mailbox.deliverReply(to: "a", text: "a reply", fileRefs: [])
        await mailbox.purge(clientId: "a")
        let remaining = await mailbox.poll(for: "a", sinceSequence: nil)
        #expect(remaining.isEmpty)
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
