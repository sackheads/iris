import Testing
import Foundation
@testable import iris

/// #181: Claude on Vertex AI. The request is the Messages API with three differences — the
/// model lives in the URL, `anthropic_version` lives in the body, and auth is a Google bearer
/// token — so the transport is one branch in `makeURLRequest` and everything after the wire
/// (the stream mapper, `parseResponse`, the cache usage fields 5a's budgets read) is shared.
@Suite("Anthropic on Vertex AI: the transport (#181)")
struct AnthropicVertexTransportTests {

    private static let request = GeminiRequest(
        contents: [Content(role: "user", parts: [Part(text: "hi")])],
        systemInstruction: Content(role: "system", parts: [Part(text: "sys")]),
        tools: [Tool(functionDeclarations: [FunctionDeclaration(
            name: "get_time", description: "time",
            parameters: Schema(type: "OBJECT", properties: ["city": Schema(type: "STRING", description: "c")], required: ["city"]))])])

    private static let vertex = AnthropicTransport.vertex(project: "gke-claude-dev", location: "global", accessToken: "ya29.token")

    private func body(_ req: URLRequest) throws -> [String: Any] {
        let data = try #require(req.httpBody)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: URL

    @Test("global location: aiplatform.googleapis.com, model in the path, rawPredict or streamRawPredict")
    func globalURL() throws {
        let plain = try AnthropicClient.makeURLRequest(request: Self.request, model: "claude-sonnet-5", transport: Self.vertex, stream: false)
        #expect(plain.url?.absoluteString == "https://aiplatform.googleapis.com/v1/projects/gke-claude-dev/locations/global/publishers/anthropic/models/claude-sonnet-5:rawPredict")
        let streamed = try AnthropicClient.makeURLRequest(request: Self.request, model: "claude-sonnet-5", transport: Self.vertex, stream: true)
        #expect(streamed.url?.absoluteString.hasSuffix(":streamRawPredict") == true)
    }

    @Test("multi-region and regional locations pick their own hosts")
    func locationHosts() throws {
        let us = try AnthropicClient.makeURLRequest(request: Self.request, model: "claude-sonnet-5",
                                                    transport: .vertex(project: "test-project", location: "us", accessToken: "t"), stream: false)
        #expect(us.url?.host == "aiplatform.us.rep.googleapis.com")
        #expect(us.url?.path.contains("/locations/us/") == true)
        let eu = try AnthropicClient.makeURLRequest(request: Self.request, model: "claude-sonnet-5",
                                                    transport: .vertex(project: "test-project", location: "eu", accessToken: "t"), stream: false)
        #expect(eu.url?.host == "aiplatform.eu.rep.googleapis.com")
        let regional = try AnthropicClient.makeURLRequest(request: Self.request, model: "claude-sonnet-4-6",
                                                          transport: .vertex(project: "test-project", location: "us-east5", accessToken: "t"), stream: false)
        #expect(regional.url?.host == "us-east5-aiplatform.googleapis.com")
        #expect(regional.url?.path.contains("/locations/us-east5/") == true)
    }

    // MARK: Model IDs

    @Test("a first-party dated id becomes Vertex's @-dated id; bare and @-dated ids pass through")
    func modelIDs() {
        #expect(AnthropicClient.vertexModelID("claude-haiku-4-5-20251001") == "claude-haiku-4-5@20251001")
        #expect(AnthropicClient.vertexModelID("claude-sonnet-5") == "claude-sonnet-5")
        #expect(AnthropicClient.vertexModelID("claude-fable-5") == "claude-fable-5")
        #expect(AnthropicClient.vertexModelID("claude-opus-4-5@20251101") == "claude-opus-4-5@20251101")
        #expect(AnthropicClient.vertexModelID("claude-opus-4-1-20250805") == "claude-opus-4-1@20250805")
    }

    @Test("the mapped id is what reaches the URL")
    func mappedIDInURL() throws {
        let req = try AnthropicClient.makeURLRequest(request: Self.request, model: "claude-haiku-4-5-20251001", transport: Self.vertex, stream: false)
        #expect(req.url?.absoluteString.contains("/models/claude-haiku-4-5@20251001:rawPredict") == true)
    }

    // MARK: Body and headers

    @Test("the body carries anthropic_version and no model; stream only when streaming")
    func bodyShape() throws {
        let plain = try body(try AnthropicClient.makeURLRequest(request: Self.request, model: "claude-sonnet-5", transport: Self.vertex, stream: false))
        #expect(plain["anthropic_version"] as? String == "vertex-2023-10-16")
        #expect(plain["model"] == nil)
        #expect(plain["stream"] == nil)
        #expect((plain["messages"] as? [[String: Any]])?.count == 1)
        let streamed = try body(try AnthropicClient.makeURLRequest(request: Self.request, model: "claude-sonnet-5", transport: Self.vertex, stream: true))
        #expect(streamed["stream"] as? Bool == true)
    }

    @Test("a Google bearer token and the quota project, never the Anthropic key headers")
    func headers() throws {
        let req = try AnthropicClient.makeURLRequest(request: Self.request, model: "claude-sonnet-5", transport: Self.vertex, stream: false)
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer ya29.token")
        #expect(req.value(forHTTPHeaderField: "x-goog-user-project") == "gke-claude-dev")
        #expect(req.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(req.value(forHTTPHeaderField: "x-api-key") == nil)
        #expect(req.value(forHTTPHeaderField: "anthropic-version") == nil)
        #expect(req.httpMethod == "POST")
    }

    @Test("cache markers survive the transport: system and the last tool still carry cache_control")
    func cacheMarkersKept() throws {
        let b = try body(try AnthropicClient.makeURLRequest(request: Self.request, model: "claude-sonnet-5", transport: Self.vertex, stream: false))
        let system = try #require(b["system"] as? [[String: Any]])
        #expect(system.first?["cache_control"] != nil)
        let tools = try #require(b["tools"] as? [[String: Any]])
        #expect(tools.last?["cache_control"] == nil, "marker (a) sits on system when there is one (5a), on Vertex as on the API")
    }

    /// 5c §0.8 and the spec's facts: Vertex accepts `ttl: "1h"` with no beta header.
    @Test("a 1h policy reaches the Vertex body, with no beta header")
    func oneHourOnVertex() throws {
        var r = Self.request
        r.cacheHints = CacheHints(ttl: .init(prefix: .oneHour, history: .oneHour))
        let req = try AnthropicClient.makeURLRequest(request: r, model: "claude-sonnet-5", transport: Self.vertex, stream: false)
        #expect(req.value(forHTTPHeaderField: "anthropic-beta") == nil)
        let b = try body(req)
        let system = try #require(b["system"] as? [[String: Any]])
        #expect((system.first?["cache_control"] as? [String: Any])?["ttl"] as? String == "1h")
        let messages = try #require(b["messages"] as? [[String: Any]])
        let last = try #require(messages.last?["content"] as? [[String: Any]])
        #expect((last.last?["cache_control"] as? [String: Any])?["ttl"] as? String == "1h")
    }

    @Test("an empty project or token is refused before anything is sent")
    func refusals() {
        #expect(throws: (any Error).self) {
            _ = try AnthropicClient.makeURLRequest(request: Self.request, model: "m",
                                                   transport: .vertex(project: "", location: "global", accessToken: "t"), stream: false)
        }
        #expect(throws: (any Error).self) {
            _ = try AnthropicClient.makeURLRequest(request: Self.request, model: "m",
                                                   transport: .vertex(project: "test-project", location: "global", accessToken: ""), stream: false)
        }
    }

    /// Two requests whose schema dictionaries were filled in opposite key orders, as 5a's
    /// `RequestByteStabilityTests` does: equal values that would encode differently without
    /// sorted keys.
    private static func request(order reversed: Bool) -> GeminiRequest {
        let keys = ["alpha", "beta", "gamma", "delta", "epsilon", "zeta", "eta", "theta"]
        var properties: [String: Schema] = [:]
        for key in (reversed ? keys.reversed() : keys) { properties[key] = Schema(type: "STRING", description: key) }
        return GeminiRequest(contents: [Content(role: "user", parts: [Part(text: "hi")])], systemInstruction: nil,
                             tools: [Tool(functionDeclarations: [FunctionDeclaration(name: "t", description: "d",
                                                                                     parameters: Schema(type: "OBJECT", properties: properties, required: keys))])])
    }

    @Test("two equal Vertex requests built from differently ordered inputs are identical bytes (5a sorted keys)")
    func byteStable() throws {
        let a = try AnthropicClient.makeURLRequest(request: Self.request(order: false), model: "claude-sonnet-5", transport: Self.vertex, stream: false).httpBody
        let b = try AnthropicClient.makeURLRequest(request: Self.request(order: true), model: "claude-sonnet-5", transport: Self.vertex, stream: false).httpBody
        #expect(a == b)
    }

    @Test("a location or project that is not a plain id is refused before the token goes anywhere")
    func hostInjectionRefused() {
        for location in ["foo.example.com/x?", "US-EAST5", "us east5", "", "global#"] {
            #expect(throws: (any Error).self, "location \(location.debugDescription)") {
                _ = try AnthropicClient.makeURLRequest(request: Self.request, model: "m",
                                                       transport: .vertex(project: "test-project", location: location, accessToken: "t"), stream: false)
            }
        }
        for project in ["bad/project", "p?x=1", "P"] {
            #expect(throws: (any Error).self, "project \(project.debugDescription)") {
                _ = try AnthropicClient.makeURLRequest(request: Self.request, model: "m",
                                                       transport: .vertex(project: project, location: "global", accessToken: "t"), stream: false)
            }
        }
        #expect(AnthropicTransport.isValidProject("example.com:legacy-project"))
        #expect(AnthropicTransport.isValidProject("gke-claude-dev"))
        #expect(AnthropicTransport.isValidLocation("europe-west1"))
        // The GCP project-id grammar: 6-30 chars, starts with a letter, no trailing hyphen; a
        // domain-scoped prefix is a hostname, so no empty labels.
        for bad in ["a..b:proj-ect", "-leading", "trailing-", "short", "9starts-with-digit", "has_underscore", "UPPER-case-id", ".dot:proj-ect"] {
            #expect(!AnthropicTransport.isValidProject(bad), Comment(rawValue: bad))
        }
    }

    @Test("errors name Vertex AI and the location, so a 404 reads as 'not served here'")
    func providerLabel() {
        #expect(AnthropicTransport.vertex(project: "test-project", location: "us-east5", accessToken: "t").providerLabel == "Anthropic (Vertex AI, us-east5)")
        #expect(AnthropicTransport.direct(apiKey: "k", baseURL: "").providerLabel == "Anthropic")
    }

    @Test("the direct transport is unchanged: api.anthropic.com, x-api-key, model in the body")
    func directUnchanged() throws {
        let req = try AnthropicClient.makeURLRequest(request: Self.request, model: "claude-sonnet-5", apiKey: "k", stream: false)
        #expect(req.url?.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(req.value(forHTTPHeaderField: "x-api-key") == "k")
        #expect(req.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        let b = try body(req)
        #expect(b["model"] as? String == "claude-sonnet-5")
        #expect(b["anthropic_version"] == nil)
    }

    // MARK: Usage reaches the same fields (5a budgets and perf read them)

    /// Captured from gke-claude-dev on 2026-10-02: a Vertex reply differs from the API's only in
    /// the `msg_vrtx_` id, and carries the same cache fields.
    @Test("a Vertex reply's cache_read and cache_creation reach UsageMetadata like the API's")
    func vertexUsageFields() throws {
        let json: [String: Any] = [
            "model": "claude-haiku-4-5-20251001", "id": "msg_vrtx_011CfckvPAzJNHmSfv4ZAoAF", "type": "message", "role": "assistant",
            "content": [["type": "text", "text": "ok"]],
            "usage": ["input_tokens": 14, "cache_creation_input_tokens": 50, "cache_read_input_tokens": 900, "output_tokens": 4,
                      "cache_creation": ["ephemeral_5m_input_tokens": 50, "ephemeral_1h_input_tokens": 0]]
        ]
        let r = try AnthropicClient.parseResponse(json)
        #expect(r.usageMetadata?.cacheReadTokens == 900)
        #expect(r.usageMetadata?.cacheWriteTokens == 50)
        #expect(r.usageMetadata?.promptTokenCount == 964)
        #expect(r.usageMetadata?.totalTokenCount == 968)
    }

    @Test("a Vertex message_start event carries the cache fields through the shared stream mapper")
    func vertexStreamUsage() throws {
        var mapper = AnthropicStreamMapper()
        let line = #"{"type":"message_start","message":{"model":"claude-haiku-4-5-20251001","id":"msg_vrtx_011","type":"message","role":"assistant","content":[],"usage":{"input_tokens":14,"cache_creation_input_tokens":50,"cache_read_input_tokens":900,"output_tokens":1}}}"#
        let events = try mapper.handle(SSEEvent(event: "message_start", data: line))
        guard case .usage(let u)? = events.first else { Issue.record("no usage event"); return }
        #expect(u.cacheReadTokens == 900)
        #expect(u.cacheWriteTokens == 50)
        #expect(u.promptTokenCount == 964)
    }
}
