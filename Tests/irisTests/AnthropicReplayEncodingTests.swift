import Testing
import Foundation
@testable import IrisKit

@Suite("Anthropic replay encoding (#314)")
struct AnthropicReplayEncodingTests {
    private func toolReply(_ n: Int, callID: String? = nil, blocks: Bool = true) -> Content {
        var c = ThinkingFixtures.reply(n, toolCall: true).candidates![0].content!
        if let callID { c.parts[0].functionCall?.id = callID }
        if !blocks { c.anthropicBlocks = nil }
        return c
    }
    private func result(_ n: Int) -> Content {
        Content(role: "user", parts: [Part(functionResponse: FunctionResponse(name: "search_memory",
                                                                              response: ["result": .string("r\(n)")],
                                                                              id: "toolu_\(n)"))])
    }
    private func request(_ contents: [Content]) -> GeminiRequest {
        GeminiRequest(contents: [Content(role: "user", parts: [Part(text: "Tell me about Seattle")])] + contents,
                      systemInstruction: Content(role: "system", parts: [Part(text: "sys")]), tools: nil)
    }

    @Test("a stored reply goes out exactly as received, tool input bytes included")
    func echoesVerbatim() throws {
        let r = request([toolReply(1), result(1)])
        let text = try ThinkingFixtures.bodyText(r)
        #expect(text.contains(r.contents[1].anthropicBlocks!))
        #expect(text.contains(#"{"query": "Seattle 1"}"#), "the model's own spacing, never re-serialised")
        let body = try ThinkingFixtures.body(r)
        #expect(ThinkingFixtures.signatures(body) == ["sig-1"])
        let messages = try #require(body["messages"] as? [[String: Any]])
        let toolResult = (messages[2]["content"] as? [[String: Any]])?.first
        #expect(toolResult?["tool_use_id"] as? String == "toolu_1")
    }

    @Test("a reply with no blocks is built from parts as before #314, and no splice token leaks")
    func partsWhenNoBlocks() throws {
        let text = try ThinkingFixtures.bodyText(request([toolReply(1, blocks: false), result(1)]))
        #expect(text.contains(#""input":{"query":"Seattle 1"}"#), "built from the call's args, sorted and compact")
        #expect(!text.contains("IRIS_ANTHROPIC_BLOCKS"))
        #expect(!text.contains("sig-1"))
    }

    @Test("a reply whose blocks can't be echoed takes every earlier reply's with it: no middle gap")
    func unechoableTakesEarlierWithIt() throws {
        let r = request([toolReply(1), result(1), toolReply(2, callID: "toolu_rewritten"), result(2),
                         toolReply(3), result(3)])
        #expect(ThinkingFixtures.signatures(try ThinkingFixtures.body(r)) == ["sig-3"])
    }

    @Test("a marker on an echoed reply lands inside its last block when that is not thinking")
    func markerInsideLastBlock() throws {
        let r = request([toolReply(1)])   // the reply is the last message: marker (d)
        let messages = try #require(try ThinkingFixtures.body(r)["messages"] as? [[String: Any]])
        let last = try #require((messages.last?["content"] as? [[String: Any]])?.last)
        #expect(last["type"] as? String == "tool_use")
        #expect(last["cache_control"] != nil)
        #expect(try ThinkingFixtures.bodyText(r).contains(ThinkingFixtures.thinkingBlock(1)),
                "the thinking block's own bytes are untouched by the marker")
    }

    @Test("a stored array with a blank text block (a hook's, say) is never echoed: it would 400")
    func blankTextNeverEchoed() throws {
        var reply = toolReply(1)
        reply.anthropicBlocks = "[\(ThinkingFixtures.thinkingBlock(1)),{\"type\":\"text\",\"text\":\"  \"},"
            + #"{"type":"tool_use","id":"toolu_1","name":"search_memory","input":{"query": "Seattle 1"}}]"#
        #expect(AnthropicBlocks.storable(reply.anthropicBlocks!) != reply.anthropicBlocks, "precondition")
        #expect(!AnthropicBlocks.echoable(reply))
        let r = request([reply, result(1)])
        #expect(ThinkingFixtures.signatures(try ThinkingFixtures.body(r)).isEmpty)
        #expect(try !ThinkingFixtures.bodyText(r).contains(#""text":"  ""#))
    }

    @Test("a marker never lands on a thinking block (Review Focus 3)")
    func markerSkipsAThinkingBlock() throws {
        var reply = toolReply(1)
        reply.parts = []
        reply.anthropicBlocks = "[\(ThinkingFixtures.thinkingBlock(1))]"
        let r = request([reply])
        let messages = try #require(try ThinkingFixtures.body(r)["messages"] as? [[String: Any]])
        let blocks = try #require(messages.last?["content"] as? [[String: Any]])
        #expect(blocks.allSatisfy { $0["cache_control"] == nil })
    }

    @Test("echoed bodies are valid JSON and byte-stable across builds")
    func byteStable() throws {
        let r = request([toolReply(1), result(1), toolReply(2), result(2)])
        #expect(try ThinkingFixtures.bodyText(r) == ThinkingFixtures.bodyText(r))
        _ = try ThinkingFixtures.body(r)
    }

    /// The splice as it was before the single pass: one rescan of the whole body per reply.
    /// Kept only as the reference the single pass must match byte for byte.
    private static func referenceSplice(_ body: Data, token: String, blocks: [Int: String]) -> Data {
        var text = String(decoding: body, as: UTF8.self)
        for (index, replacement) in blocks {
            text = text.replacingOccurrences(of: "\"\(token)\(index)\"", with: replacement)
        }
        return Data(text.utf8)
    }

    @Test("the single-pass splice is byte-identical to the per-reply rescan on a multi-reply body")
    func singlePassMatchesReference() throws {
        let token = "IRIS_ANTHROPIC_BLOCKS_\(UUID().uuidString)_"
        var messages: [[String: Any]] = []
        var blocks: [Int: String] = [:]
        for i in 0..<24 {
            if i % 2 == 0 {
                // User text: non-ASCII, and one carrying the quoted token, which JSON escapes.
                let text = i == 4 ? "\"\(token)1\" r\u{E9}sum\u{E9} \u{1F600}" : "Caf\u{E9} \u{65E5}\u{672C} round \(i)"
                messages.append(["role": "user", "content": text])
            } else {
                messages.append(["role": "assistant", "content": token + String(i)])
                // Index 13 has no replacement and must pass through unchanged on both sides.
                if i != 13 {
                    blocks[i] = #"[{"type":"thinking","thinking":"pens\#u{E9}e \#(i)","signature":"s\#(i)"},{"type":"text","text":"\#u{00FC}ber \#(i)"}]"#
                }
            }
        }
        let body = try JSONSerialization.data(withJSONObject: ["messages": messages, "model": "m"], options: [.sortedKeys])
        let spliced = AnthropicClient.splice(body, token: token, blocks: blocks)
        #expect(spliced == Self.referenceSplice(body, token: token, blocks: blocks))
        let text = String(decoding: spliced, as: UTF8.self)
        #expect(text.contains("\"\(token)13\""), "an index with no blocks is left as it was")
        #expect(text.contains(#"\"\#(token)1\""#), "the escaped token in user text is never spliced")
        #expect(!text.contains("\"\(token)11\""))
        _ = try JSONSerialization.jsonObject(with: spliced)
    }
}
