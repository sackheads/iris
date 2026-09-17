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

    @Test("an array-wrapped error body still yields a real headline")
    func arrayShapedBody() {
        let raw = """
        [
          {
            "error": {
              "code": 429,
              "message": "Quota exceeded for aiplatform.googleapis.com.",
              "status": "RESOURCE_EXHAUSTED"
            }
          }
        ]
        """
        let err = APIError.http(provider: "Gemini", statusCode: 429, body: body(raw))
        #expect(err.message == "Gemini HTTP 429 RESOURCE_EXHAUSTED: Quota exceeded for aiplatform.googleapis.com.")
        #expect(err.isRetryable)
    }

    @Test("Retry-After in seconds is carried on the error, matched case-insensitively")
    func retryAfterSeconds() {
        let err = APIError.http(provider: "Anthropic", statusCode: 429, body: Data(), headers: ["retry-after": "7"])
        #expect(err.retryAfter == 7)
        #expect(APIError.http(provider: "Anthropic", statusCode: 429, body: Data()).retryAfter == nil)
        #expect(APIError.http(provider: "Anthropic", statusCode: 429, body: Data(), headers: ["Retry-After": "soon"]).retryAfter == nil)
    }

    @Test("Retry-After as an HTTP-date becomes a wait relative to now, never negative")
    func retryAfterDate() {
        let now = Date(timeIntervalSince1970: 1_700_000_000) // Tue, 14 Nov 2023 22:13:20 GMT
        let future = APIError.retryAfter(from: ["Retry-After": "Tue, 14 Nov 2023 22:13:50 GMT"], now: now)
        #expect(future == 30)
        let past = APIError.retryAfter(from: ["Retry-After": "Tue, 14 Nov 2023 22:13:00 GMT"], now: now)
        #expect(past == 0)
    }

    @Test("the legacy message-only initializer still works and is not retryable")
    func legacyInit() {
        let err = APIError(message: "GEMINI_FALLBACK_AUTH_ERROR_1013")
        #expect(err.localizedDescription == "GEMINI_FALLBACK_AUTH_ERROR_1013")
        #expect(err.statusCode == nil)
        #expect(err.detail == nil)
    }
}

/// Backoff timing: a scheduled delay is jittered ±25% so agents that fail together do not
/// retry in lockstep; a provider's `Retry-After` wins, is capped, and is only ever stretched.
@Suite("LLMRetry.wait")
struct LLMRetryWaitTests {
    @Test("a scheduled delay is spread across ±25%")
    func scheduledJitter() {
        #expect(LLMRetry.wait(scheduled: 8, retryAfter: nil, unitRandom: 0) == 6)
        #expect(LLMRetry.wait(scheduled: 8, retryAfter: nil, unitRandom: 0.5) == 8)
        #expect(LLMRetry.wait(scheduled: 8, retryAfter: nil, unitRandom: 1) == 10)
        for _ in 0..<200 {
            let w = LLMRetry.wait(scheduled: 4, retryAfter: nil)
            #expect(w >= 3 && w <= 5)
        }
    }

    @Test("Retry-After overrides the schedule and is never shortened")
    func retryAfterWins() {
        #expect(LLMRetry.wait(scheduled: 2, retryAfter: 20, unitRandom: 0) == 20)
        #expect(LLMRetry.wait(scheduled: 2, retryAfter: 20, unitRandom: 1) == 25)
        #expect(LLMRetry.wait(scheduled: 2, retryAfter: 0, unitRandom: 1) == 0)
    }

    @Test("a huge Retry-After is capped")
    func retryAfterCap() {
        #expect(LLMRetry.wait(scheduled: 2, retryAfter: 3600, unitRandom: 0) == LLMRetry.retryAfterCap)
    }

    @Test("a zero schedule stays zero (tests rely on this)")
    func zeroStaysZero() {
        #expect(LLMRetry.wait(scheduled: 0, retryAfter: nil) == 0)
    }
}
