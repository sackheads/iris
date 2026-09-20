import Testing
import Foundation
@testable import iris

/// #204 round 2: `Part`, `FunctionCall`, `FunctionResponse` and `InlineData` are reachable from a
/// persisted `history` row (`Content.parts[]`), so a `keyNotFound` inside any of them throws out of
/// whatever `decodeIfPresent` wraps them one level up -- which swallows a MISSING key at that level
/// but not a decode error inside a value that IS present. See `Content`'s existing lenient decoder
/// (#136) for the pattern these follow.
@Suite("Gemini wire types: lenient decoding")
struct GeminiWireTypesLenientDecodingTests {
    // This does not guard against a regression -- every `Part` field is `Optional`, so the
    // synthesized decoder already treats a missing key as nil with no custom code at all; deleting
    // `Part`'s `init(from:)` entirely would still pass this test. It documents that the explicit
    // decoder's behavior matches the always-safe-by-construction baseline, nothing more.
    @Test("a Part JSON missing every field decodes to an all-nil part (documents existing Optional safety, not a regression guard)")
    func partMissingAllFieldsDecodes() throws {
        let part = try JSONDecoder().decode(Part.self, from: Data("{}".utf8))
        #expect(part.text == nil)
        #expect(part.functionCall == nil)
        #expect(part.functionResponse == nil)
        #expect(part.inlineData == nil)
        #expect(part.thought_signature == nil)
        #expect(part.thoughtSignature == nil)
    }

    @Test("a FunctionCall JSON missing args defaults to an empty dictionary, name stays required")
    func functionCallMissingArgsDefaults() throws {
        let json = #"{"name":"run_command"}"#
        let call = try JSONDecoder().decode(FunctionCall.self, from: Data(json.utf8))
        #expect(call.name == "run_command")
        #expect(call.args.isEmpty)
        #expect(call.id == nil)
    }

    @Test("a FunctionCall JSON missing name throws (identity field stays required)")
    func functionCallMissingNameThrows() {
        let json = #"{"args":{}}"#
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(FunctionCall.self, from: Data(json.utf8))
        }
    }

    @Test("a FunctionResponse JSON missing response defaults to an empty dictionary")
    func functionResponseMissingResponseDefaults() throws {
        let json = #"{"name":"run_command"}"#
        let response = try JSONDecoder().decode(FunctionResponse.self, from: Data(json.utf8))
        #expect(response.name == "run_command")
        #expect(response.response.isEmpty)
    }

    @Test("a FunctionResponse JSON missing name throws (identity field stays required)")
    func functionResponseMissingNameThrows() {
        let json = #"{"response":{}}"#
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(FunctionResponse.self, from: Data(json.utf8))
        }
    }

    @Test("an InlineData JSON missing both fields decodes to safe defaults")
    func inlineDataMissingFieldsDefaults() throws {
        let inline = try JSONDecoder().decode(InlineData.self, from: Data("{}".utf8))
        #expect(inline.mimeType == "application/octet-stream")
        #expect(inline.data == "")
    }

    // JSONValue is a recursive sum type over a single JSON node (FunctionCall.args/
    // FunctionResponse.response are `[String: JSONValue]`), not a keyed container with named
    // fields -- there is nothing to decodeIfPresent. Its hand-written init(from:) already matches
    // every JSON shape exhaustively; this pins that the encoder/decoder pair stays lossless.
    @Test("JSONValue round-trips every case through Codable")
    func jsonValueRoundTrips() throws {
        let value = JSONValue.object([
            "s": .string("x"), "i": .int(1), "d": .double(1.5), "b": .bool(true),
            "a": .array([.null, .string("y")]), "n": .null
        ])
        let back = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
        #expect(back == value)
    }

    @Test("a Content history row whose Part has a function call missing args still decodes through Content")
    func contentWithLenientNestedFunctionCallDecodes() throws {
        let json = """
        {"role":"model","parts":[{"functionCall":{"name":"run_command"}}]}
        """
        let content = try JSONDecoder().decode(Content.self, from: Data(json.utf8))
        #expect(content.parts.count == 1)
        #expect(content.parts.first?.functionCall?.name == "run_command")
        #expect(content.parts.first?.functionCall?.args.isEmpty == true)
    }
}
