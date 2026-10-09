import Testing
import Foundation
@testable import IrisKit

@Suite("Anthropic blocks through the assembler and the non-stream parser (#314)")
struct AnthropicBlocksTests {
    static let raw = #"[{"type":"thinking","thinking":"","signature":"sig-1"},{"type":"tool_use","id":"toolu_1","name":"search_memory","input":{"query": "Seattle", "b": 1.0}}]"#

    @Test("RawJSON cuts a top-level member out byte for byte, whitespace and all")
    func rawJSONCutsVerbatim() {
        let data = Data(#"{"id":"m", "content" : [ {"type":"text","text":"a } \" ] {"} ] ,"usage":{}}"#.utf8)
        #expect(RawJSON.topLevelValue("content", in: data) == #"[ {"type":"text","text":"a } \" ] {"} ]"#)
        #expect(RawJSON.topLevelValue("id", in: data) == #""m""#)
    }

    @Test("RawJSON reads only top-level keys, and answers nil for a missing key or a malformed body")
    func rawJSONTopLevelOnly() {
        let nested = Data(#"{"usage":{"content":[1]},"content":[2]}"#.utf8)
        #expect(RawJSON.topLevelValue("content", in: nested) == "[2]")
        #expect(RawJSON.topLevelValue("content", in: Data(#"{"usage":{"content":[1]}}"#.utf8)) == nil)
        #expect(RawJSON.topLevelValue("content", in: Data(#"{"content":[1"#.utf8)) == nil)
        #expect(RawJSON.topLevelValue("content", in: Data("[1]".utf8)) == nil)
    }

    @Test("RawJSON splits an array into its elements' own bytes, and answers nil for a non-array")
    func rawJSONElements() {
        #expect(RawJSON.elements(#" [ {"a":"x ] , {"} , [1,2] ,"s" , 3 ] "#) == [#"{"a":"x ] , {"}"#, "[1,2]", #""s""#, "3"])
        #expect(RawJSON.elements("[]") == [])
        #expect(RawJSON.elements(#"{"a":1}"#) == nil)
        #expect(RawJSON.elements("[1,]") == nil)
        #expect(RawJSON.elements("[1") == nil)
        #expect(RawJSON.elements("[1] x") == nil)
    }

    @Test("RawJSON lists an object's members with key and value bytes as received")
    func rawJSONMembers() {
        let members = RawJSON.members(#"{"type":"tool_use", "caller" : {"type": "direct"},"n":1.0}"#)
        #expect(members?.map(\.name) == ["type", "caller", "n"])
        #expect(members?.map(\.value) == [#""tool_use""#, #"{"type": "direct"}"#, "1.0"])
        #expect(members?[1].key == #""caller""#)
        #expect(RawJSON.members("{}") == [])
        #expect(RawJSON.members("[1]") == nil)
        #expect(RawJSON.members(#"{"a":1"#) == nil)
    }

    @Test("a non-stream reply keeps the response's own bytes for its blocks")
    func nonStreamKeepsBytes() throws {
        let data = Data(#"{"id":"m","content":\#(Self.raw),"stop_reason":"tool_use","usage":{"input_tokens":1,"output_tokens":1}}"#.utf8)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let response = try AnthropicClient.parseResponse(json, raw: data)
        let content = try #require(response.candidates?.first?.content)
        #expect(content.anthropicBlocks == Self.raw)
        #expect(content.parts.first?.functionCall?.id == "toolu_1")
    }

    @Test("a non-stream reply with no thinking block, or parsed without its bytes, stores nothing")
    func nonStreamWithoutThinking() throws {
        let data = Data(#"{"content":[{"type":"text","text":"hi"}],"usage":{"input_tokens":1,"output_tokens":1}}"#.utf8)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(try AnthropicClient.parseResponse(json, raw: data).candidates?.first?.content?.anthropicBlocks == nil)
        let thought = Data(#"{"content":\#(Self.raw)}"#.utf8)
        let thoughtJSON = try #require(try JSONSerialization.jsonObject(with: thought) as? [String: Any])
        #expect(try AnthropicClient.parseResponse(thoughtJSON).candidates?.first?.content?.anthropicBlocks == nil)
    }

    @Test("the assembler puts streamed blocks on the reply's content")
    func assemblerCarries() {
        var a = StreamAssembler()
        a.apply(.functionCall(FunctionCall(name: "search_memory", args: [:], id: "toolu_1")), now: 1)
        a.apply(.anthropicBlocks(Self.raw), now: 2)
        a.apply(.done(finishReason: "tool_use"), now: 3)
        #expect(a.response().candidates?.first?.content?.anthropicBlocks == Self.raw)
    }

    @Test("a finished response replayed as events keeps its blocks (the FakeLLMClient and streaming-off path)")
    func replayRoundTrip() {
        let content = Content(role: "model", parts: [Part(text: "hi")], anthropicBlocks: Self.raw)
        let events = LLMStreamEvent.events(from: GeminiResponse(candidates: [Candidate(content: content)], usageMetadata: nil))
        var a = StreamAssembler()
        for e in events { a.apply(e, now: 1) }
        #expect(a.response().candidates?.first?.content?.anthropicBlocks == Self.raw)
        #expect(a.firstTokenAt == 1, "the blocks event is not a token, but the text before it is")
    }
}
