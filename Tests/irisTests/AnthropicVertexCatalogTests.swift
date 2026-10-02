import Testing
import Foundation
import os
@testable import iris

/// #181: Vertex has no "list Claude models" endpoint, so the catalog asks about each id Iris knows
/// and keeps the ones the project can see. A typed id the catalog has never heard of still works
/// in the tier field; this list only feeds the picker.
@Suite("Anthropic on Vertex AI: the model catalog (#181)")
struct AnthropicVertexCatalogTests {

    /// `scopedSession`, never the global `handler` slot: suites run in parallel (invariant 7).
    private func withMock<T>(_ handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data),
                             _ body: (URLSession) async throws -> T) async rethrows -> T {
        let (session, remove) = MockURLProtocol.scopedSession(handler)
        defer { remove() }
        return try await body(session)
    }

    private static let target = AnthropicVertexTarget(project: "gke-claude-dev", location: "global")

    @Test("listModels probes each known id with a bearer token and keeps the ones that answer 200")
    func listProbesKnownIDs() async throws {
        let seen = OSAllocatedUnfairLock(initialState: [String]())
        let models = try await withMock({ request in
            let url = request.url!
            seen.withLock { $0.append(url.absoluteString) }
            #expect(request.httpMethod == "GET")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer ya29.t")
            #expect(request.value(forHTTPHeaderField: "x-goog-user-project") == "gke-claude-dev")
            #expect(request.value(forHTTPHeaderField: "x-api-key") == nil)
            let id = url.lastPathComponent
            let ok = id == "claude-sonnet-5" || id == "claude-haiku-4-5"
            let status = ok ? 200 : 404
            let body = ok ? #"{"name":"publishers/anthropic/models/\#(id)","versionId":"default"}"# : #"{"error":{"code":404,"message":"not found"}}"#
            return (HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        }) { session in
            let catalog = ModelCatalog(provider: .anthropic, apiKey: "", baseURL: "", anthropicVertex: Self.target, session: session)
            return try await catalog.listModels(adcToken: "ya29.t", quotaProject: "ignored-for-vertex")
        }
        #expect(models.map(\.id) == ["claude-sonnet-5", "claude-haiku-4-5"])
        let urls = seen.withLock { $0 }
        #expect(urls.count == ModelCatalog.knownVertexClaudeModels.count)
        #expect(urls.allSatisfy { $0.hasPrefix("https://aiplatform.googleapis.com/v1/publishers/anthropic/models/") })
    }

    @Test("a regional location probes the regional host")
    func regionalHost() async throws {
        let hosts = OSAllocatedUnfairLock(initialState: Set<String>())
        _ = try await withMock({ request in
            hosts.withLock { _ = $0.insert(request.url!.host!) }
            return (HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data("{}".utf8))
        }) { session in
            let catalog = ModelCatalog(provider: .anthropic, apiKey: "", baseURL: "",
                                       anthropicVertex: AnthropicVertexTarget(project: "p", location: "us-east5"), session: session)
            return try await catalog.listModels(adcToken: "t")
        }
        #expect(hosts.withLock { $0 } == ["us-east5-aiplatform.googleapis.com"])
    }

    @Test("listModels without a token is refused with a sentence, not an empty list")
    func listNeedsToken() async {
        await withMock({ request in
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
        }) { session in
            let catalog = ModelCatalog(provider: .anthropic, apiKey: "", baseURL: "", anthropicVertex: Self.target, session: session)
            do {
                _ = try await catalog.listModels(adcToken: nil)
                Issue.record("expected a refusal")
            } catch {
                #expect((error as? APIError)?.message.lowercased().contains("token") == true)
            }
        }
    }

    @Test("probe sends the Vertex request shape for the tier's model, with the dated id mapped")
    func probeUsesVertexTransport() async throws {
        let captured = OSAllocatedUnfairLock(initialState: [URLRequest]())
        let result = try await withMock({ request in
            captured.withLock { $0.append(request) }
            let body = #"{"id":"msg_vrtx_1","type":"message","role":"assistant","content":[{"type":"text","text":"Hello"}],"usage":{"input_tokens":5,"output_tokens":1}}"#
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        }) { session in
            let catalog = ModelCatalog(provider: .anthropic, apiKey: "", baseURL: "", anthropicVertex: Self.target, session: session)
            return await catalog.probe(model: "claude-haiku-4-5-20251001", label: "easy", adcToken: "ya29.t")
        }
        guard case .ok = result.outcome else { Issue.record("probe failed: \(result.outcome)"); return }
        let req = try #require(captured.withLock { $0.first })
        #expect(req.url?.absoluteString == "https://aiplatform.googleapis.com/v1/projects/gke-claude-dev/locations/global/publishers/anthropic/models/claude-haiku-4-5@20251001:rawPredict")
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer ya29.t")
        let data = try #require(req.bodyData)
        let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(body["anthropic_version"] as? String == "vertex-2023-10-16")
        #expect(body["model"] == nil)
    }

    @Test("the known list covers Iris's shipped Anthropic tier defaults, spelled as Vertex wants them")
    func knownListCoversDefaults() {
        let known = ModelCatalog.knownVertexClaudeModels
        // The easy default is dated on the API; Vertex's catalog entry is the bare id.
        #expect(known.contains("claude-haiku-4-5"))
        #expect(known.contains("claude-sonnet-5"))
        #expect(known.contains("claude-fable-5"))
        #expect(Set(known).count == known.count, "no duplicate probes")
    }
}
