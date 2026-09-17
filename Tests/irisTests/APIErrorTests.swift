import Testing
import Foundation
@testable import iris

/// A provider's non-200 body used to be pasted verbatim into the error the user sees. Vertex's
/// 429 body carries ~90 KB of internal serving traces, which arrived in the chat as one giant
/// Markdown-mangled agent bubble. The parser reduces any provider body to a one-line headline
/// plus a bounded raw detail for the disclosure.
@Suite("APIError.http parsing")
struct APIErrorTests {
    private func body(_ s: String) -> Data { Data(s.utf8) }

    private let gemini429 = """
    {
      "error": {
        "code": 429,
        "message": "Resource exhausted. Please try again later. Please refer to https://cloud.google.com/vertex-ai/generative-ai/docs/error-code-429 for more details.",
        "status": "RESOURCE_EXHAUSTED",
        "details": [{"@type": "type.googleapis.com/google.rpc.DebugInfo", "detail": "\(String(repeating: "learning/serving/servables/wiz/orch_wiz_servable.cc:1447; ", count: 2000))"}]
      }
    }
    """

    @Test("Gemini body becomes a one-line headline with status label")
    func geminiHeadline() {
        let err = APIError.http(provider: "Gemini", statusCode: 429, body: body(gemini429))
        #expect(err.message == "Gemini HTTP 429 RESOURCE_EXHAUSTED: Resource exhausted. Please try again later. Please refer to https://cloud.google.com/vertex-ai/generative-ai/docs/error-code-429 for more details.")
        #expect(err.statusCode == 429)
        #expect(err.provider == "Gemini")
    }

    @Test("raw detail is kept for the disclosure but capped")
    func detailIsCapped() {
        let err = APIError.http(provider: "Gemini", statusCode: 429, body: body(gemini429))
        let detail = try! #require(err.detail)
        #expect(gemini429.count > 100_000)
        #expect(detail.count < APIError.detailLimit + 100)
        #expect(detail.hasPrefix("{"))
        #expect(detail.contains("truncated"))
    }

    @Test("a short body is kept whole as detail")
    func shortDetailIsWhole() {
        let raw = #"{"error": {"code": 401, "message": "Request had invalid authentication credentials.", "status": "UNAUTHENTICATED"}}"#
        let err = APIError.http(provider: "Gemini", statusCode: 401, body: body(raw))
        #expect(err.detail == raw)
        #expect(err.message == "Gemini HTTP 401 UNAUTHENTICATED: Request had invalid authentication credentials.")
    }

    @Test("Anthropic error shape uses error.type as the label")
    func anthropicShape() {
        let raw = #"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#
        let err = APIError.http(provider: "Anthropic", statusCode: 529, body: body(raw))
        #expect(err.message == "Anthropic HTTP 529 overloaded_error: Overloaded")
    }

    @Test("OpenAI error shape uses error.type as the label")
    func openAIShape() {
        let raw = #"{"error":{"message":"You exceeded your current quota.","type":"insufficient_quota","param":null,"code":"insufficient_quota"}}"#
        let err = APIError.http(provider: "OpenAI", statusCode: 429, body: body(raw))
        #expect(err.message == "OpenAI HTTP 429 insufficient_quota: You exceeded your current quota.")
    }

    @Test("a non-JSON body falls back to its first non-empty line")
    func nonJSONBody() {
        let raw = "\n\n<html><head><title>502 Bad Gateway</title></head>\n<body>nginx</body></html>"
        let err = APIError.http(provider: "OpenAI", statusCode: 502, body: body(raw))
        #expect(err.message == "OpenAI HTTP 502: <html><head><title>502 Bad Gateway</title></head>")
    }

    @Test("an empty body still yields a usable headline and no detail")
    func emptyBody() {
        let err = APIError.http(provider: "Anthropic", statusCode: 500, body: Data())
        #expect(err.message == "Anthropic HTTP 500")
        #expect(err.detail == nil)
    }

    @Test("an oversize provider message is capped in the headline")
    func headlineIsCapped() {
        let raw = #"{"error":{"message":"\#(String(repeating: "x", count: 5000))","status":"INTERNAL"}}"#
        let err = APIError.http(provider: "Gemini", statusCode: 500, body: body(raw))
        #expect(err.message.count <= APIError.headlineLimit + 100)
    }

    @Test("only rate-limit and overload statuses are retryable")
    func retryable() {
        for code in [429, 503, 529] {
            #expect(APIError.http(provider: "Gemini", statusCode: code, body: Data()).isRetryable, "\(code)")
        }
        for code in [400, 401, 403, 404, 500] {
            #expect(!APIError.http(provider: "Gemini", statusCode: code, body: Data()).isRetryable, "\(code)")
        }
        #expect(!APIError(message: "no status").isRetryable)
    }

    @Test("the legacy message-only initializer still works and is not retryable")
    func legacyInit() {
        let err = APIError(message: "GEMINI_FALLBACK_AUTH_ERROR_1013")
        #expect(err.localizedDescription == "GEMINI_FALLBACK_AUTH_ERROR_1013")
        #expect(err.statusCode == nil)
        #expect(err.detail == nil)
    }
}
