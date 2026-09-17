import Testing
import Foundation
@testable import iris

/// An LLM failure is shown as a tagged system message (`[LLM_ERROR]`, like `[TOOL_CALL]`) so the
/// chat can render a compact headline with an optional disclosure, instead of attributing a raw
/// provider body to Iris as if it had said it.
@Suite("LLMErrorMessage")
struct LLMErrorMessageTests {
    private let giantBody: String = {
        let trace = String(repeating: "learning/serving/servables/wiz/orch_wiz_servable.cc:1447; ", count: 1500)
        return """
        {"error": {"code": 429, "message": "Resource exhausted. Please try again later.", "status": "RESOURCE_EXHAUSTED", "details": [{"@type": "type.googleapis.com/google.rpc.DebugInfo", "detail": "\(trace)"}]}}
        """
    }()

    @Test("encode/parse round-trips headline and detail")
    func roundTrip() {
        let display = LLMErrorDisplay(headline: "Gemini HTTP 429 RESOURCE_EXHAUSTED: Resource exhausted.", detail: "{\"error\": {}}")
        let text = LLMErrorMessage.encode(display)
        #expect(text.hasPrefix(LLMErrorMessage.prefix))
        #expect(LLMErrorMessage.parse(text) == display)
    }

    @Test("a missing detail round-trips as nil")
    func roundTripWithoutDetail() {
        let display = LLMErrorDisplay(headline: "The Internet connection appears to be offline.", detail: nil)
        #expect(LLMErrorMessage.parse(LLMErrorMessage.encode(display)) == display)
    }

    @Test("other system messages are not mistaken for LLM errors")
    func parseRejectsOtherText() {
        #expect(LLMErrorMessage.parse("[TOOL_CALL]\n{\"name\": \"run_command\"}") == nil)
        #expect(LLMErrorMessage.parse("Running tool: read_file") == nil)
        #expect(LLMErrorMessage.parse("[LLM_ERROR]\nnot json") == nil)
    }

    @Test("an APIError contributes its capped detail")
    func displayFromAPIError() {
        let err = APIError.http(provider: "Gemini", statusCode: 429, body: Data(giantBody.utf8))
        let display = LLMErrorMessage.display(for: err)
        #expect(display.headline == err.message)
        #expect(display.detail == err.detail)
        #expect(LLMErrorMessage.encode(err).count < 3000)
    }

    @Test("a non-API error uses its description and has no detail")
    func displayFromOtherError() {
        let display = LLMErrorMessage.display(for: URLError(.notConnectedToInternet))
        #expect(display.headline == URLError(.notConnectedToInternet).localizedDescription)
        #expect(display.detail == nil)
    }

    @Test("an oversize non-API description is capped in the headline")
    func displayCapsUnknownErrors() {
        struct Huge: LocalizedError { var errorDescription: String? { String(repeating: "y", count: 10_000) } }
        let display = LLMErrorMessage.display(for: Huge())
        #expect(display.headline.count <= APIError.headlineLimit + 100)
    }

    // MARK: - Legacy migration

    @Test("a persisted legacy Gemini error bubble becomes a compact system message")
    func migratesLegacyGeminiBubble() throws {
        let legacy = ChatMessage(role: .agent, content: "Error calling LLM: HTTP 429: " + giantBody)
        let migrated = LLMErrorMessage.migrateLegacy(legacy)
        #expect(migrated.id == legacy.id)
        #expect(migrated.role == .system)
        #expect(migrated.content.count < 3000)
        let display = try #require(LLMErrorMessage.parse(migrated.content))
        #expect(display.headline == "Gemini HTTP 429 RESOURCE_EXHAUSTED: Resource exhausted. Please try again later.")
        #expect(display.detail?.contains("truncated") == true)
    }

    @Test("a legacy Anthropic error keeps its provider")
    func migratesLegacyAnthropicBubble() throws {
        let legacy = ChatMessage(role: .agent, content: #"Error calling LLM: Anthropic HTTP 529: {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#)
        let display = try #require(LLMErrorMessage.parse(LLMErrorMessage.migrateLegacy(legacy).content))
        #expect(display.headline == "Anthropic HTTP 529 overloaded_error: Overloaded")
    }

    @Test("a legacy error without an HTTP body keeps its text as the headline")
    func migratesLegacyPlainError() throws {
        let legacy = ChatMessage(role: .agent, content: "Error calling LLM: The Internet connection appears to be offline.")
        let display = try #require(LLMErrorMessage.parse(LLMErrorMessage.migrateLegacy(legacy).content))
        #expect(display.headline == "The Internet connection appears to be offline.")
        #expect(display.detail == nil)
    }

    @Test("ordinary messages pass through migration untouched")
    func migrationLeavesOthersAlone() {
        let agent = ChatMessage(role: .agent, content: "Here is how to fix that 429 you saw.")
        let user = ChatMessage(role: .user, content: "Error calling LLM: is what I keep seeing")
        for original in [agent, user] {
            let out = LLMErrorMessage.migrateLegacy(original)
            #expect(out.id == original.id)
            #expect(out.role == original.role)
            #expect(out.content == original.content)
        }
    }

    @Test("sanitizeLoaded migrates legacy error bubbles in saved conversations")
    func sanitizeLoadedMigrates() throws {
        let legacy = ChatMessage(role: .agent, content: "Error calling LLM: HTTP 429: " + giantBody)
        let conv = Conversation(title: "t", messages: [ChatMessage(role: .user, content: "hi"), legacy])
        let loaded = AppState.sanitizeLoaded([conv])
        let msgs = try #require(loaded.first?.messages)
        #expect(msgs.count == 2)
        #expect(msgs[0].role == .user)
        #expect(msgs[1].role == .system)
        #expect(LLMErrorMessage.parse(msgs[1].content) != nil)
    }
}
