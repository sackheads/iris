import Foundation
import Testing
@testable import IrisKit

/// #1437: a request marked `uncached` reaches Anthropic with no `cache_control` anywhere, and an ordinary request still
/// has every marker it had.
@Suite("An uncached request sends no cache marker; an ordinary one is unchanged (#1437)")
struct AnthropicUncachedTests {
    private func body(uncached: Bool, system: String?) throws -> String {
        var request = GeminiRequest(contents: [Content(role: "user", parts: [Part(text: "one")]),
                                               Content(role: "model", parts: [Part(text: "two")]),
                                               Content(role: "user", parts: [Part(text: "three")])],
                                    systemInstruction: system.map { Content(role: "system", parts: [Part(text: $0)]) },
                                    tools: [Tool(functionDeclarations: [FunctionDeclaration(name: "read_file", description: "reads", parameters: nil)])])
        if uncached { request.cacheHints = CacheHints(uncached: true) }
        let url = try AnthropicClient.makeURLRequest(request: request, model: "claude-sonnet-5-5",
                                                     transport: .direct(apiKey: "k", baseURL: ""), stream: false)
        return String(decoding: try #require(url.httpBody), as: UTF8.self)
    }

    @Test("uncached: no marker on system, tools or messages", arguments: ["be brief", nil] as [String?])
    func noMarkers(system: String?) throws {
        #expect(!(try body(uncached: true, system: system)).contains("cache_control"))
    }

    @Test("ordinary: the markers are still sent", arguments: ["be brief", nil] as [String?])
    func markersKept(system: String?) throws {
        #expect((try body(uncached: false, system: system)).contains("cache_control"))
    }
}
