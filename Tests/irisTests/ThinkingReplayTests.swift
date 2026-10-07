import Testing
import Foundation
@testable import iris

@Suite("ThinkingReplay: the floor and the prefix-continuity check (#314)")
struct ThinkingReplayTests {
    private func user(_ t: String) -> Content { Content(role: "user", parts: [Part(text: t)]) }
    private func model(_ t: String, _ n: Int?) -> Content {
        Content(role: "model", parts: [Part(text: t)],
                anthropicBlocks: n.map { "[\(ThinkingFixtures.thinkingBlock($0)),{\"type\":\"text\",\"text\":\"\(t)\"}]" })
    }
    private func request(_ contents: [Content], system: String = "sys", tools: [String] = ["a"]) -> GeminiRequest {
        GeminiRequest(contents: contents, systemInstruction: Content(role: "system", parts: [Part(text: system)]),
                      tools: [Tool(functionDeclarations: tools.map { FunctionDeclaration(name: $0, description: "d", parameters: nil) })])
    }
    private func blocks(_ r: GeminiRequest) -> [Bool] { r.contents.map { $0.anthropicBlocks != nil } }

    /// Request one, then reply one as received; the state every case below starts from.
    private func afterRoundOne() -> ThinkingReplay {
        var r = ThinkingReplay(floor: 1)
        var first = request([user("q")])
        _ = r.prepare(&first, historyCount: 1)
        r.recordReceived(model("r1", 1))
        return r
    }

    @Test("blocks below the floor are removed; at and above it they stay")
    func floorStrips() {
        let contents = [user("a"), model("b", 0), user("c"), model("d", 1)]
        let out = ThinkingReplay(floor: 3).applyingFloor(contents)
        #expect(out.map { $0.anthropicBlocks != nil } == [false, false, false, true])
        #expect(out.map(\.parts.first?.text) == contents.map(\.parts.first?.text))
    }

    @Test("the floor only rises: a block left out once stays out")
    func floorIsMonotonic() {
        var r = ThinkingReplay(floor: 3)
        r.raiseFloor(to: 6)
        r.raiseFloor(to: 4)
        #expect(r.floor == 6)
    }

    @Test("an append (last request + the reply as received + new messages) continues, and keeps its blocks")
    func appendContinues() {
        var r = afterRoundOne()
        var next = request([user("q"), model("r1", 1), user("tool result")])
        #expect(r.prepare(&next, historyCount: 3) == nil)
        #expect(blocks(next) == [false, true, false])
        #expect(r.floor == 1)
    }

    @Test("an edited earlier message diverges there, and the floor rises past everything produced since")
    func editDiverges() {
        var r = afterRoundOne()
        var next = request([user("Q, edited"), model("r1", 1), user("tool result")])
        #expect(r.prepare(&next, historyCount: 3) == 0)
        #expect(r.floor == 3, "past the divergence and past reply one, which was bound to it")
        #expect(blocks(next) == [false, false, false])
    }

    @Test("a reply stored differently from how it arrived (an AfterModel rewrite) diverges at the reply")
    func rewrittenReplyDiverges() {
        var r = afterRoundOne()
        var next = request([user("q"), Content(role: "model", parts: [Part(text: "r1, rewritten")]), user("tool result")])
        #expect(r.prepare(&next, historyCount: 3) == 1)
        #expect(blocks(next) == [false, false, false])
    }

    @Test("a block removed above the floor (a hook dropping anthropicBlocks) diverges; it stays out after")
    func removedBlockDiverges() {
        var r = afterRoundOne()
        var next = request([user("q"), model("r1", nil), user("tool result")])
        #expect(r.prepare(&next, historyCount: 3) == 1)
        r.recordReceived(model("r2", 2))
        var later = request([user("q"), model("r1", 1), user("tool result"), model("r2", 2), user("tool result 2")])
        #expect(r.prepare(&later, historyCount: 5) == nil, "the floor is applied to both sides, so the strip is no edit")
        #expect(blocks(later) == [false, false, false, true, false], "reply one's block never comes back")
    }

    @Test("a floor raised between sends (the drop_block retry, Task 13) is not an edit")
    func externalRaiseIsNoEdit() {
        var r = afterRoundOne()
        var next = request([user("q"), model("r1", 1), user("tool result")])
        #expect(r.prepare(&next, historyCount: 3) == nil)
        r.recordReceived(model("r2", 2))
        r.raiseFloor(to: 4)
        var later = request([user("q"), model("r1", 1), user("tool result"), model("r2", 2), user("tool result 2")])
        #expect(r.prepare(&later, historyCount: 5) == nil)
        #expect(blocks(later) == [false, false, false, false, false])
    }

    @Test("a changed system instruction or tool set diverges at 0")
    func systemAndToolsDiverge() {
        var a = afterRoundOne()
        var system = request([user("q"), model("r1", 1)], system: "sys, rebuilt")
        #expect(a.prepare(&system, historyCount: 2) == 0)
        var b = afterRoundOne()
        var tools = request([user("q"), model("r1", 1)], tools: ["a", "b"])
        #expect(b.prepare(&tools, historyCount: 2) == 0)
    }

    @Test("a removed or reordered message diverges")
    func removeAndReorderDiverge() {
        var a = afterRoundOne()
        var removed = request([model("r1", 1)])
        #expect(a.prepare(&removed, historyCount: 1) != nil)
        var b = afterRoundOne()
        var reordered = request([model("r1", 1), user("q")])
        #expect(b.prepare(&reordered, historyCount: 2) != nil)
    }

    @Test("no block is sent from beyond AppState's history (a hook-appended reply)")
    func nothingBeyondHistory() {
        var r = afterRoundOne()
        var next = request([user("q"), model("r1", 1), user("tool result"), model("forged", 9)])
        _ = r.prepare(&next, historyCount: 3)
        #expect(blocks(next) == [false, true, false, false])
    }

    @Test("the fingerprint ignores image bytes of the same type and length, never text or blocks")
    func fingerprintCheapButExact() {
        let a = Content(role: "user", parts: [Part(text: "x"), Part(inlineData: InlineData(mimeType: "image/png", data: "AAAA"))])
        let b = Content(role: "user", parts: [Part(text: "x"), Part(inlineData: InlineData(mimeType: "image/png", data: "BBBB"))])
        #expect(ThinkingReplay.fingerprint(a) == ThinkingReplay.fingerprint(b))
        #expect(ThinkingReplay.fingerprint(a) != ThinkingReplay.fingerprint(user("y")))
        #expect(ThinkingReplay.fingerprint(model("r", 1)) != ThinkingReplay.fingerprint(model("r", nil)))
    }
}
