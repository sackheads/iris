import Testing
import Foundation
import os
@testable import IrisKit

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

    @Test("listModels sends one one-token rawPredict per known id and keeps the ones that answer 200")
    func listProbesKnownIDs() async throws {
        let seen = OSAllocatedUnfairLock(initialState: [URLRequest]())
        let models = try await withMock({ request in
            seen.withLock { $0.append(request) }
            let url = request.url!
            #expect(request.httpMethod == "POST")
            #expect(url.absoluteString.hasSuffix(":rawPredict"))
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer ya29.t")
            #expect(request.value(forHTTPHeaderField: "x-goog-user-project") == "gke-claude-dev")
            #expect(request.value(forHTTPHeaderField: "x-api-key") == nil)
            let id = url.lastPathComponent.replacingOccurrences(of: ":rawPredict", with: "")
            let ok = id == "claude-sonnet-5" || id == "claude-haiku-4-5@20251001"
            let status = ok ? 200 : 404
            let body = ok
                ? #"{"id":"msg_vrtx_1","type":"message","role":"assistant","content":[{"type":"text","text":"H"}],"usage":{"input_tokens":8,"output_tokens":1}}"#
                : #"{"error":{"code":404,"message":"Publisher model not found or your project does not have access"}}"#
            return (HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        }) { session in
            let catalog = ModelCatalog(provider: .anthropic, apiKey: "", baseURL: "", anthropicVertex: Self.target, session: session)
            return try await catalog.listModels(adcToken: "ya29.t", quotaProject: "ignored-for-vertex")
        }
        // Anthropic spelling in the result, so a pick is valid in either auth mode.
        #expect(models.map(\.id) == ["claude-sonnet-5", "claude-haiku-4-5-20251001"])
        let requests = seen.withLock { $0 }
        #expect(requests.count == ModelCatalog.knownVertexClaudeModels.count)
        #expect(requests.allSatisfy { $0.url!.absoluteString.hasPrefix("https://aiplatform.googleapis.com/v1/projects/gke-claude-dev/locations/global/publishers/anthropic/models/") })
        for request in requests {
            let data = try #require(request.bodyData)
            let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(body["max_tokens"] as? Int == 1, "a probe costs one output token")
            #expect(body["anthropic_version"] as? String == "vertex-2023-10-16")
        }
    }

    @Test("a regional location probes the regional host")
    func regionalHost() async throws {
        let hosts = OSAllocatedUnfairLock(initialState: Set<String>())
        _ = try await withMock({ request in
            hosts.withLock { _ = $0.insert(request.url!.host!) }
            return (HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"error":{"code":404,"message":"not found"}}"#.utf8))
        }) { session in
            let catalog = ModelCatalog(provider: .anthropic, apiKey: "", baseURL: "",
                                       anthropicVertex: AnthropicVertexTarget(project: "test-project", location: "us-east5"), session: session)
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

    @Test("when every probe fails and any failure is not a 404/400, that error is thrown, never an empty catalog")
    func nonNotFoundFailureThrows() async {
        await withMock({ request in
            (HTTPURLResponse(url: request.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!,
             Data(#"{"error":{"code":403,"message":"Permission denied on resource project"}}"#.utf8))
        }) { session in
            let catalog = ModelCatalog(provider: .anthropic, apiKey: "", baseURL: "", anthropicVertex: Self.target, session: session)
            do {
                _ = try await catalog.listModels(adcToken: "ya29.t")
                Issue.record("expected the 403 to surface")
            } catch {
                #expect((error as? APIError)?.statusCode == 403)
                #expect((error as? APIError)?.message.contains("Vertex AI") == true)
            }
        }
    }

    /// Measured on gke-claude-dev: a model whose publisher terms the project has not accepted
    /// answers 403 ("requires data sharing to be enabled for publisher 'anthropic'") while its
    /// neighbours answer 200. That is a per-model condition, not a wrong project.
    @Test("a 403 beside a 200 is a per-model condition and only drops that model")
    func mixedFailuresKeepSuccesses() async throws {
        let models = try await withMock({ request in
            let id = request.url!.lastPathComponent.replacingOccurrences(of: ":rawPredict", with: "")
            if id == "claude-sonnet-5" {
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                        Data(#"{"id":"m","type":"message","role":"assistant","content":[],"usage":{"input_tokens":8,"output_tokens":1}}"#.utf8))
            }
            return (HTTPURLResponse(url: request.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"error":{"code":403,"message":"Access to this model requires data sharing to be enabled for publisher 'anthropic'."}}"#.utf8))
        }) { session in
            let catalog = ModelCatalog(provider: .anthropic, apiKey: "", baseURL: "", anthropicVertex: Self.target, session: session)
            return try await catalog.listModels(adcToken: "ya29.t")
        }
        #expect(models.map(\.id) == ["claude-sonnet-5"])
    }

    /// A body regression (a wrong anthropic_version, a probe body that failed to build) makes
    /// every id answer 400; that must surface, not read as "no Claude models".
    @Test("when nothing is served and every failure is a 400, the 400 is thrown")
    func allBadRequestsThrow() async {
        await withMock({ request in
            (HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!,
             Data(#"{"error":{"code":400,"message":"anthropic_version: field required"}}"#.utf8))
        }) { session in
            let catalog = ModelCatalog(provider: .anthropic, apiKey: "", baseURL: "", anthropicVertex: Self.target, session: session)
            do {
                _ = try await catalog.listModels(adcToken: "ya29.t")
                Issue.record("expected the 400 to surface")
            } catch {
                #expect((error as? APIError)?.statusCode == 400)
            }
        }
    }

    /// Twelve concurrent probes can trip a 429; a rate-limited model is still enabled, so it is
    /// listed with the failure on it instead of vanishing as if it were not.
    @Test("a 429 or 5xx beside a 200 is listed as unverified, not dropped")
    func transientFailuresAreShown() async throws {
        let models = try await withMock({ request in
            let id = request.url!.lastPathComponent.replacingOccurrences(of: ":rawPredict", with: "")
            switch id {
            case "claude-sonnet-5":
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                        Data(#"{"id":"m","type":"message","role":"assistant","content":[],"usage":{"input_tokens":8,"output_tokens":1}}"#.utf8))
            case "claude-opus-5":
                return (HTTPURLResponse(url: request.url!, statusCode: 429, httpVersion: nil, headerFields: nil)!,
                        Data(#"{"error":{"code":429,"message":"Quota exceeded"}}"#.utf8))
            case "claude-opus-4-8":
                return (HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!,
                        Data(#"{"error":{"code":503,"message":"overloaded"}}"#.utf8))
            default:
                return (HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!,
                        Data(#"{"error":{"code":404,"message":"not found"}}"#.utf8))
            }
        }) { session in
            let catalog = ModelCatalog(provider: .anthropic, apiKey: "", baseURL: "", anthropicVertex: Self.target, session: session)
            return try await catalog.listModels(adcToken: "ya29.t")
        }
        #expect(models.map(\.id) == ["claude-opus-5", "claude-opus-4-8", "claude-sonnet-5"], "catalog order, with the unverified ones kept")
        #expect(models.first { $0.id == "claude-opus-5" }?.displayName?.contains("429") == true)
        #expect(models.first { $0.id == "claude-opus-4-8" }?.displayName?.contains("503") == true)
        #expect(models.first { $0.id == "claude-sonnet-5" }?.displayName == nil)
    }

    @Test("a 400 for an id the location rejects drops the id like a 404")
    func badRequestDrops() async throws {
        let models = try await withMock({ request in
            let id = request.url!.lastPathComponent.replacingOccurrences(of: ":rawPredict", with: "")
            if id == "claude-sonnet-5" {
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                        Data(#"{"id":"m","type":"message","role":"assistant","content":[],"usage":{"input_tokens":8,"output_tokens":1}}"#.utf8))
            }
            return (HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"error":{"code":400,"message":"is not supported"}}"#.utf8))
        }) { session in
            let catalog = ModelCatalog(provider: .anthropic, apiKey: "", baseURL: "", anthropicVertex: Self.target, session: session)
            return try await catalog.listModels(adcToken: "ya29.t")
        }
        #expect(models.map(\.id) == ["claude-sonnet-5"])
    }

    @Test("probe sends the Vertex request shape for the tier's model, with the dated id mapped")
    func probeUsesVertexTransport() async throws {
        let captured = OSAllocatedUnfairLock(initialState: [URLRequest]())
        let result = await withMock({ request in
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

    @Test("the known list is in Anthropic spelling and covers ConfigManager's shipped Anthropic tier defaults")
    func knownListCoversDefaults() {
        let known = ModelCatalog.knownVertexClaudeModels
        #expect(known.allSatisfy { !$0.contains("@") }, "a pick must stay valid when the user switches back to API-key mode")
        #expect(Set(known).count == known.count, "no duplicate probes")
        let name = "iris-181-cat-\(UUID().uuidString)"
        let store = UserDefaults(suiteName: name)!
        defer { store.removePersistentDomain(forName: name); IrisDefaults.removeSuiteFile(named: name, in: IrisDefaults.preferencesDirectory) }
        let config = ConfigManager(store: store)
        for tier in [ModelTier.easy, .medium, .hard] {
            config.primaryProvider = LLMProvider.anthropic.rawValue
            let shipped = config.getModel(for: tier)
            #expect(known.contains(shipped), "shipped \(tier) default \(shipped) is not in the probe list")
        }
    }
}
