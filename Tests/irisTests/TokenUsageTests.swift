import Testing
import Foundation
@testable import iris

/// #204: `TokenUsage` had no hand-written `init(from:)`, so the synthesized decoder threw
/// `keyNotFound` for any absent key rather than falling back to the property's own default —
/// Swift's synthesized `Decodable` ignores stored-property defaults for non-Optional fields.
/// That throw is caught at the conversation-row level in `ConversationStore.loadAll` and skips
/// the whole conversation (invariant 1).
@Suite("TokenUsage lenient decoding")
struct TokenUsageTests {
    @Test("a JSON object missing every key decodes to all-zero defaults instead of throwing")
    func missingAllKeysDefaults() throws {
        let usage = try JSONDecoder().decode(TokenUsage.self, from: Data("{}".utf8))
        #expect(usage == TokenUsage(promptTokenCount: 0, candidatesTokenCount: 0, totalTokenCount: 0))
    }

    @Test("a JSON object missing the newest field defaults just that field")
    func missingOneKeyDefaults() throws {
        let json = #"{"promptTokenCount":3,"candidatesTokenCount":4}"#
        let usage = try JSONDecoder().decode(TokenUsage.self, from: Data(json.utf8))
        #expect(usage == TokenUsage(promptTokenCount: 3, candidatesTokenCount: 4, totalTokenCount: 0))
    }
}
