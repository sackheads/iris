import Testing
import Foundation
@testable import iris

@MainActor
@Suite("The engine stores each reply's blocks (#314)", .timeLimit(.minutes(1)))
struct ThinkingStorageEngineTests {
    private func modelEntries(_ h: ThinkingHarness) -> [Content] { h.history.filter { $0.role == "model" } }

    @Test("every reply of a four-round turn keeps its blocks in history")
    func repliesStoreTheirBlocks() async throws {
        let dir = try ThinkingFixtures.tempDirectory("store")
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = ThinkingFixtures.fourRounds()
        let h = try ThinkingHarness.make(script, hooks: try ThinkingFixtures.hooks(in: dir))
        await h.run()
        #expect(h.client.requests.count == 4)
        #expect(modelEntries(h).map(\.anthropicBlocks) == script.map { $0.candidates?.first?.content?.anthropicBlocks })
    }

    @Test("a reply that did not think stores no blocks, and its neighbours keep theirs")
    func unthoughtStoresNone() async throws {
        let dir = try ThinkingFixtures.tempDirectory("unthought")
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = [ThinkingFixtures.reply(1, toolCall: true), ThinkingFixtures.unthought(2, toolCall: true),
                      ThinkingFixtures.reply(3, toolCall: false)]
        let h = try ThinkingHarness.make(script, hooks: try ThinkingFixtures.hooks(in: dir))
        await h.run()
        #expect(modelEntries(h).map { $0.anthropicBlocks != nil } == [true, false, true])
    }

    @Test("a reply an AfterModel hook rewrote stores no blocks")
    func afterModelRewriteStoresNone() async throws {
        let dir = try ThinkingFixtures.tempDirectory("aftermodel")
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = ThinkingFixtures.onCall(2, sed: "s/Seattle 2/Seattle two/g", counter: dir.appendingPathComponent("n"))
        let h = try ThinkingHarness.make(ThinkingFixtures.fourRounds(),
                                         hooks: try ThinkingFixtures.hooks(in: dir, ["AfterModel": script]))
        await h.run()
        #expect(modelEntries(h).map { $0.anthropicBlocks != nil } == [true, false, true, true])
        #expect(modelEntries(h)[1].parts.first?.functionCall?.args["query"] == .string("Seattle two"),
                "precondition: the hook really rewrote round two")
    }

    @Test("a hook that rewrites only the text, leaving the blocks byte-identical, still stores none")
    func textOnlyRewriteStoresNone() async throws {
        let dir = try ThinkingFixtures.tempDirectory("textonly")
        defer { try? FileManager.default.removeItem(at: dir) }
        let counter = dir.appendingPathComponent("n"), out = dir.appendingPathComponent("out.json")
        // In the payload, `parts` holds `:"done 4"` while the blocks string holds `:\"done 4\"`,
        // so this matches the parts text only. The output is kept to check the blocks survived.
        let script = """
        c=$(cat '\(counter.path)' 2>/dev/null || echo 0); c=$((c+1)); echo $c > '\(counter.path)'
        if [ "$c" -eq 4 ]; then sed -E 's/:"done 4"/:"done four"/g' | tee '\(out.path)'; else cat; fi
        """
        let rounds = ThinkingFixtures.fourRounds()
        let h = try ThinkingHarness.make(rounds, hooks: try ThinkingFixtures.hooks(in: dir, ["AfterModel": script]))
        await h.run()
        #expect(modelEntries(h).map { $0.anthropicBlocks != nil } == [true, true, true, false])
        #expect(modelEntries(h)[3].parts.first?.text == "done four", "precondition: the hook rewrote the text")
        let hooked = try JSONDecoder().decode(GeminiResponse.self, from: Data(contentsOf: out))
        #expect(hooked.candidates?.first?.content?.anthropicBlocks == rounds[3].candidates?.first?.content?.anthropicBlocks,
                "precondition: the hook left the blocks string byte-identical")
    }

    @Test("an AfterModel hook that passes its input through is not a rewrite (Review Focus 2)")
    func passThroughAfterModelKeepsBlocks() async throws {
        let dir = try ThinkingFixtures.tempDirectory("passthrough")
        defer { try? FileManager.default.removeItem(at: dir) }
        let h = try ThinkingHarness.make(ThinkingFixtures.fourRounds(),
                                         hooks: try ThinkingFixtures.hooks(in: dir, ["AfterModel": "cat"]))
        await h.run()
        #expect(modelEntries(h).allSatisfy { $0.anthropicBlocks != nil })
    }

    @Test("HookRewrite compares canonical JSON: key order is not a change, a value is")
    func hookRewriteIsCanonical() throws {
        let a = try JSONDecoder().decode([String: JSONValue].self, from: Data(#"{"a":1,"b":"x"}"#.utf8))
        let b = try JSONDecoder().decode([String: JSONValue].self, from: Data(#"{"b":"x","a":1}"#.utf8))
        let c = try JSONDecoder().decode([String: JSONValue].self, from: Data(#"{"b":"y","a":1}"#.utf8))
        #expect(!HookRewrite.changes(a, b))
        #expect(HookRewrite.changes(a, c))
    }
}
