import Testing
import Foundation
@testable import iris

/// Releases `sleep` callers on demand so a flush window is deterministic.
private actor Gate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async { await withCheckedContinuation { waiters.append($0) } }
    func release() { let w = waiters; waiters = []; w.forEach { $0.resume() } }
    var waiting: Int { waiters.count }
}

private actor Recorder {
    var opens: [(UUID, String)] = []
    var updates: [(UUID, String, Bool)] = []
    func open(_ id: UUID, _ text: String) { opens.append((id, text)) }
    func update(_ id: UUID, _ text: String, _ final: Bool) { updates.append((id, text, final)) }
}

private func eventually(_ timeoutMs: Int = 2000, _ condition: @Sendable () async -> Bool) async -> Bool {
    for _ in 0..<(timeoutMs / 10) {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return await condition()
}

@Suite("Message streamer")
struct MessageStreamerTests {
    private func make(_ recorder: Recorder, gate: Gate) -> MessageStreamer {
        MessageStreamer(open: { await recorder.open($0, $1) },
                        update: { await recorder.update($0, $1, $2) },
                        sleep: { _ in await gate.wait() })
    }

    @Test("the row opens with the first delta; later deltas coalesce into one update per window; finish writes once and persists")
    func coalescing() async {
        let recorder = Recorder(), gate = Gate()
        let s = make(recorder, gate: gate)
        await s.append("Hel")
        #expect(await recorder.opens.map(\.1) == ["Hel"])
        await s.append("lo")
        await s.append(" wor")
        #expect(await eventually { await gate.waiting == 1 })
        #expect(await recorder.updates.isEmpty)
        await gate.release()
        #expect(await eventually { await recorder.updates.count == 1 })
        #expect(await recorder.updates.first?.1 == "Hello wor")
        #expect(await recorder.updates.first?.2 == false)
        await s.finish("Hello world!")
        let updates = await recorder.updates
        #expect(updates.count == 2)
        #expect(updates.last?.1 == "Hello world!" && updates.last?.2 == true)
        #expect(await recorder.opens.count == 1)
        #expect(await recorder.opens.first?.0 == s.messageId)
    }

    @Test("a replayed call opens and finalizes in one go")
    func replayPath() async {
        let recorder = Recorder(), gate = Gate()
        let s = make(recorder, gate: gate)
        await s.finish("whole reply")
        #expect(await recorder.opens.map(\.1) == ["whole reply"])
        #expect(await recorder.updates.map(\.1) == ["whole reply"])
        #expect(await recorder.updates.map(\.2) == [true])
    }

    @Test("finishing with nothing to show opens no row")
    func emptyFinish() async {
        let recorder = Recorder(), gate = Gate()
        let s = make(recorder, gate: gate)
        await s.finish("")
        let opens = await recorder.opens
        let updates = await recorder.updates
        #expect(opens.isEmpty && updates.isEmpty)
    }

    @Test("settle returns what was shown and finalizes it; a pending flush no longer fires")
    func settle() async {
        let recorder = Recorder(), gate = Gate()
        let s = make(recorder, gate: gate)
        await s.append("par")
        await s.append("tial")
        let shown = await s.settle()
        #expect(shown == "partial")
        let lastUpdate = await recorder.updates.last
        #expect(lastUpdate?.1 == "partial" && lastUpdate?.2 == true)
        let before = await recorder.updates.count
        await gate.release()
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(await recorder.updates.count == before)
    }

    @Test("no writes after finish or settle: a late delta is ignored, on-screen text stays put")
    func noWritesAfterFinish() async {
        let recorder = Recorder(), gate = Gate()
        let s = make(recorder, gate: gate)
        await s.append("a")
        await s.finish("ab")
        await s.append("c")
        await gate.release()
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(await recorder.updates.count == 1)
        let lastUpdate = await recorder.updates.last
        #expect(lastUpdate?.1 == "ab" && lastUpdate?.2 == true)
        #expect(await s.text == "ab")

        let recorder2 = Recorder(), gate2 = Gate()
        let s2 = make(recorder2, gate: gate2)
        _ = await s2.settle()
        await s2.append("x")
        #expect(await recorder2.opens.isEmpty)
    }

    @Test("the flush interval is 50 ms")
    func interval() {
        #expect(MessageStreamer.flushIntervalMs == 50)
    }
}

@MainActor
@Suite("AppState in-place message update")
struct UpdateMessageContentTests {
    @Test("content is replaced without adding a message; persist is opt-in")
    func updateInPlace() {
        let app = AppState()
        let conv = UUID()
        app.createNewConversation(id: conv)
        let id = UUID()
        app.appendMessage(role: .agent, content: "a", id: id, to: conv)
        let count = app.conversations.first { $0.id == conv }!.messages.count
        app.updateMessageContent(id: id, content: "ab", in: conv)
        let messages = app.conversations.first { $0.id == conv }!.messages
        #expect(messages.count == count)
        #expect(messages.first { $0.id == id }?.content == "ab")
        #expect(messages.first { $0.id == id }?.role == .agent)
    }

    @Test("an unknown message id is a no-op")
    func unknownId() {
        let app = AppState()
        let conv = UUID()
        app.createNewConversation(id: conv)
        let before = app.conversations.first { $0.id == conv }!.messages
        app.updateMessageContent(id: UUID(), content: "x", in: conv)
        #expect(app.conversations.first { $0.id == conv }!.messages.map(\.content) == before.map(\.content))
    }
}
