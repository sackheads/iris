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
    @Test("a Part JSON missing every field decodes to an all-nil part instead of throwing")
    func partMissingAllFieldsDecodes() throws {
        let part = try JSONDecoder().decode(Part.self, from: Data("{}".utf8))
        #expect(part.text == nil)
        #expect(part.functionCall == nil)
        #expect(part.functionResponse == nil)
        #expect(part.inlineData == nil)
        #expect(part.thought_signature == nil)
        #expect(part.thoughtSignature == nil)
    }

    @Test("a Part round-trips through Codable with every field populated")
    func partRoundTrips() throws {
        let part = Part(text: "hi", functionCall: FunctionCall(name: "f", args: ["a": .string("b")], id: "c1"),
                        functionResponse: nil, inlineData: InlineData(mimeType: "image/png", data: "AA=="),
                        thought_signature: "sig1", thoughtSignature: "sig2")
        let back = try JSONDecoder().decode(Part.self, from: JSONEncoder().encode(part))
        #expect(back.text == "hi")
        #expect(back.functionCall?.name == "f")
        #expect(back.inlineData?.mimeType == "image/png")
        #expect(back.thought_signature == "sig1")
        #expect(back.thoughtSignature == "sig2")
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

    @Test("an InlineData JSON missing both fields decodes to safe defaults")
    func inlineDataMissingFieldsDefaults() throws {
        let inline = try JSONDecoder().decode(InlineData.self, from: Data("{}".utf8))
        #expect(inline.mimeType == "application/octet-stream")
        #expect(inline.data == "")
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
