import Testing
import Foundation
@testable import iris

/// Gemini omits `parts` on a candidate it stopped early (safety, recitation, an empty
/// answer). `Content` is also the persisted history type, so decoding must tolerate the
/// absence rather than fail the whole response (#136).
@Suite("Gemini response decoding")
struct GeminiResponseDecodingTests {
    @Test("a candidate without parts decodes to empty parts and keeps its finish reason")
    func partsAbsent() throws {
        let json = #"{"candidates":[{"content":{"role":"model"},"finishReason":"SAFETY","index":0}],"usageMetadata":{"promptTokenCount":14,"totalTokenCount":14}}"#
        let r = try JSONDecoder().decode(GeminiResponse.self, from: Data(json.utf8))
        let c = try #require(r.candidates?.first)
        #expect(c.content?.parts.isEmpty == true)
        #expect(c.finishReason == "SAFETY")
        #expect(r.usageMetadata?.promptTokenCount == 14)
    }

    @Test("a prompt block with no candidates decodes and exposes the block reason")
    func promptBlocked() throws {
        let json = #"{"promptFeedback":{"blockReason":"PROHIBITED_CONTENT"},"usageMetadata":{"promptTokenCount":9}}"#
        let r = try JSONDecoder().decode(GeminiResponse.self, from: Data(json.utf8))
        #expect(r.candidates == nil)
        #expect(r.promptFeedback?.blockReason == "PROHIBITED_CONTENT")
    }

    @Test("a normal candidate still decodes its parts")
    func normal() throws {
        let json = #"{"candidates":[{"content":{"role":"model","parts":[{"text":"Canberra."}]},"finishReason":"STOP"}]}"#
        let r = try JSONDecoder().decode(GeminiResponse.self, from: Data(json.utf8))
        #expect(r.candidates?.first?.content?.parts.first?.text == "Canberra.")
        #expect(r.candidates?.first?.finishReason == "STOP")
    }

    @Test("persisted history Content without a parts key still loads")
    func persistedContent() throws {
        let c = try JSONDecoder().decode(Content.self, from: Data(#"{"role":"model"}"#.utf8))
        #expect(c.role == "model")
        #expect(c.parts.isEmpty)
        // Round trip keeps the key present for anything already persisted.
        let again = try JSONDecoder().decode(Content.self, from: JSONEncoder().encode(c))
        #expect(again.parts.isEmpty)
    }

    @Test("GeminiResponse.emptyReason names why nothing came back")
    func emptyReason() throws {
        let safety = try JSONDecoder().decode(GeminiResponse.self, from: Data(#"{"candidates":[{"content":{"role":"model"},"finishReason":"SAFETY"}]}"#.utf8))
        #expect(safety.emptyReason == "finishReason: SAFETY")
        let blocked = try JSONDecoder().decode(GeminiResponse.self, from: Data(#"{"promptFeedback":{"blockReason":"OTHER"}}"#.utf8))
        #expect(blocked.emptyReason == "blockReason: OTHER")
        let bare = try JSONDecoder().decode(GeminiResponse.self, from: Data(#"{}"#.utf8))
        #expect(bare.emptyReason == "no candidates")
        let normal = try JSONDecoder().decode(GeminiResponse.self, from: Data(#"{"candidates":[{"content":{"role":"model","parts":[{"text":"hi"}]}}]}"#.utf8))
        #expect(normal.emptyReason == nil)
    }
}
