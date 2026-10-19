import Testing
import Foundation
import Observation
@testable import IrisKit

/// #541: a streamed reply's updates go to its box in `AppState.streaming`, not to
/// `conversations`, so the chat window's root does not re-evaluate on every token. Only the final
/// write reaches `conversations`, and everything a user or another session sees reads the box.
@MainActor
@Suite("Streamed replies stay out of conversations until they end (#541)")
struct StreamingTextsTests {
    private func app() throws -> (AppState, UUID) {
        let a = AppState(store: try .inMemory())
        let id = UUID()
        a.createNewConversation(id: id)
        return (a, id)
    }

    /// Opens an agent row as the streamer does, then streams `updates` into it.
    private func stream(_ a: AppState, in id: UUID, _ updates: [String]) -> UUID {
        let mid = UUID()
        a.appendMessage(role: .agent, content: "", id: mid, to: id)
        for text in updates { a.updateMessageContent(id: mid, content: text, in: id, persist: false) }
        return mid
    }

    private func fires(_ read: @escaping () -> Void, after change: () -> Void) -> Bool {
        final class Flag: @unchecked Sendable { var fired = false }
        let flag = Flag()
        withObservationTracking(read) { flag.fired = true }
        change()
        return flag.fired
    }

    @Test("a token reaches neither conversations nor the stream registry, only its own box")
    func tokenTouchesOnlyItsBox() throws {
        let (a, id) = try app()
        let mid = stream(a, in: id, ["He"])
        let message = try #require(a.conversations.first { $0.id == id }?.messages.first { $0.id == mid })
        // The root's inputs: what ChatView's body, the grouping, the sidebar and the session
        // strip read. None of them may fire on a token, or the whole window re-lays out per token.
        #expect(!fires({ _ = a.conversations }, after: { a.updateMessageContent(id: mid, content: "Hel", in: id) }),
                "conversations is untouched by a token")
        #expect(!fires({ _ = a.streaming.boxes }, after: { a.updateMessageContent(id: mid, content: "Hell", in: id) }),
                "the registry changes only when a stream starts or ends")
        // The row's read does fire: it is how the bubble grows.
        #expect(fires({ _ = a.liveContent(of: message) }, after: { a.updateMessageContent(id: mid, content: "Hello", in: id) }))
        #expect(a.liveContent(of: message) == "Hello")
        #expect(a.conversations.first { $0.id == id }?.messages.first { $0.id == mid }?.content == "",
                "conversations still holds the row as it opened")
    }

    @Test("the final write is exact, reaches conversations, is recorded, and leaves no box")
    func finalWriteCommits() throws {
        let (a, id) = try app()
        let mid = stream(a, in: id, ["a", "ab"])
        a.flushSave()
        a.updateMessageContent(id: mid, content: "abc, final", in: id, persist: true)
        #expect(a.conversations.first { $0.id == id }?.messages.first { $0.id == mid }?.content == "abc, final")
        #expect(a.streaming.boxes.isEmpty)
        #expect(a.pendingChangeSet(for: id) != nil, "the final write is saved")
    }

    @Test("a Stop mid-stream commits exactly what was shown")
    func stopCommitsWhatWasShown() async throws {
        let (a, id) = try app()
        let streamer = MessageStreamer(
            open: { mid, text in await MainActor.run { a.appendMessage(role: .agent, content: text, id: mid, to: id) } },
            update: { mid, text, isFinal, sequence in
                await MainActor.run {
                    a.updateMessageContent(id: mid, content: text, in: id, persist: isFinal, sequence: sequence)
                }
            },
            sleep: { _ in })
        await streamer.append("Hello")
        await streamer.append(", wor")
        try await Task.sleep(nanoseconds: 50_000_000)   // the coalesced flush
        let shown = await streamer.settle()
        #expect(shown == "Hello, wor")
        #expect(a.conversations.first { $0.id == id }?.messages.last?.content == "Hello, wor")
        #expect(a.streaming.boxes.isEmpty)
    }

    @Test("a save mid-stream writes the reply as it reads now, not as it opened")
    func saveOverlaysTheStream() throws {
        let (a, id) = try app()
        let mid = stream(a, in: id, ["partial so", "partial so far"])
        a.flushSave()   // the debounced save the row's opening scheduled
        let saved = try a.store.loadAll().conversations.first { $0.id == id }?.messages.first { $0.id == mid }
        #expect(saved?.content == "partial so far")
        #expect(a.conversations.first { $0.id == id }?.messages.first { $0.id == mid }?.content == "",
                "the overlay is the snapshot's alone")
    }

    @Test("copy, export and another session's read see the live text")
    func readersSeeLiveText() throws {
        let (a, id) = try app()
        let mid = stream(a, in: id, ["live text"])
        let messages = try #require(a.conversations.first { $0.id == id }?.messages)
        let message = try #require(messages.first { $0.id == mid })
        #expect(a.liveMessage(message).exportLine(format: .plainText).contains("live text"))
        #expect(a.liveMessages(messages).first { $0.id == mid }?.content == "live text")
        #expect(message.exportLine(format: .plainText).contains("live text") == false,
                "precondition: the stored message alone is stale")
    }

    @Test("two streams in two conversations keep their own boxes")
    func concurrentStreams() throws {
        let (a, one) = try app()
        let two = UUID()
        a.createNewConversation(id: two)
        let m1 = stream(a, in: one, ["one"])
        let m2 = stream(a, in: two, ["two"])
        #expect(a.streaming.boxes[m1]?.text == "one" && a.streaming.boxes[m2]?.text == "two")
        a.updateMessageContent(id: m1, content: "one done", in: one, persist: true)
        #expect(a.streaming.boxes[m1] == nil && a.streaming.boxes[m2]?.text == "two")
    }

    @Test("deleting a conversation mid-stream leaves no box")
    func deleteDropsTheBox() throws {
        let (a, id) = try app()
        _ = stream(a, in: id, ["going"])
        a.deleteConversation(id)
        #expect(a.streaming.boxes.isEmpty)
    }

    @Test("archiving a conversation mid-stream keeps what streamed and leaves no box")
    func archiveCommits() throws {
        let (a, id) = try app()
        a.createNewConversation()   // somewhere to go, so the archive is allowed
        let mid = stream(a, in: id, ["kept"])
        #expect(a.archiveConversation(id) == nil)
        #expect(a.streaming.boxes.isEmpty)
        #expect(a.conversations.first { $0.id == id }?.messages.first { $0.id == mid }?.content == "kept")
    }

    @Test("a turn that ends without the final write keeps what it showed and leaves no box")
    func abandonedTurnCommits() throws {
        let (a, id) = try app()
        a.beginEngineTurn(for: id)
        let mid = stream(a, in: id, ["cut off"])
        a.endEngineTurn(for: id)
        #expect(a.streaming.boxes.isEmpty)
        #expect(a.conversations.first { $0.id == id }?.messages.first { $0.id == mid }?.content == "cut off")
    }

    // MARK: Ordering (#583 review)

    @Test("a partial that lands after the final write changes nothing: the final stays stored, no box comes back")
    func latePartialAfterFinal() throws {
        let (a, id) = try app()
        let mid = UUID()
        a.appendMessage(role: .agent, content: "", id: mid, to: id)
        a.updateMessageContent(id: mid, content: "par", in: id, persist: false, sequence: 1)
        a.updateMessageContent(id: mid, content: "partial, final", in: id, persist: true, sequence: 3)
        a.updateMessageContent(id: mid, content: "partial", in: id, persist: false, sequence: 2)   // late
        a.updateMessageContent(id: mid, content: "unnumbered", in: id, persist: false)            // late too
        #expect(a.streaming.boxes.isEmpty, "no box recreated")
        let stored = { a.conversations.first { $0.id == id }?.messages.first { $0.id == mid }?.content }
        #expect(stored() == "partial, final")
        a.beginEngineTurn(for: id)
        a.endEngineTurn(for: id)   // the commit that used to write the stale partial over the final
        #expect(stored() == "partial, final")
    }

    @Test("partials out of order show the newest")
    func outOfOrderPartials() throws {
        let (a, id) = try app()
        let mid = UUID()
        a.appendMessage(role: .agent, content: "", id: mid, to: id)
        a.updateMessageContent(id: mid, content: "abc", in: id, persist: false, sequence: 2)
        a.updateMessageContent(id: mid, content: "ab", in: id, persist: false, sequence: 1)
        #expect(a.streaming.boxes[mid]?.text == "abc")
    }

    @Test("a box no turn will finish is kept when the conversation's next turn starts")
    func staleBoxSweptAtNextTurn() throws {
        let (a, id) = try app()
        let mid = stream(a, in: id, ["abandoned"])   // a round no bracketed turn owns
        a.beginEngineTurn(for: id)
        #expect(a.streaming.boxes.isEmpty)
        #expect(a.conversations.first { $0.id == id }?.messages.first { $0.id == mid }?.content == "abandoned")
        a.endEngineTurn(for: id)
    }

    /// The root must never read live text (#541): a view that starts calling the live accessors
    /// stays green in the observation tests above, so every call site is listed here, and a new
    /// one fails until it is added on purpose.
    @Test("the live accessors are called only where a row, copy, export, another session or the save reads")
    nonisolated func liveAccessorCallSites() throws {
        // Off the main actor: a scan of the sources held it for seconds in a parallel run (#637).
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources/IrisKit")
        let allowed: [String: Int] = [
            "AppState.swift": 1,              // the save's overlay
            "ChatView.swift": 4,              // MessageView's row, Cmd-C, Copy as…, Export
            "SessionStripView.swift": 1,      // Copy Transcript
            "iris.swift": 2,                  // read_conversation, get_job_run's excerpt
            "ConversationRotation.swift": 1,  // the rotation summary
        ]
        var found: [String: Int] = [:]
        for file in try FileManager.default.contentsOfDirectory(atPath: sources.path) where file.hasSuffix(".swift") {
            let text = try String(contentsOf: sources.appendingPathComponent(file), encoding: .utf8)
            let calls = text.components(separatedBy: "\n").filter { line in
                let code = line.components(separatedBy: "//").first ?? ""
                return code.contains("liveContent(of:") || code.contains("liveMessage(") || code.contains("liveMessages(")
            }.filter { !$0.contains("func live") }
            if !calls.isEmpty { found[file] = calls.count }
        }
        #expect(found == allowed, "live-text call sites changed: \(found.sorted { $0.key < $1.key })")
    }
}
