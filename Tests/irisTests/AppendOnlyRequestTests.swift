import Testing
import Foundation
@testable import iris

/// Spec §2.1, PRs 1-2: within one turn, each request's messages extend the last request's,
/// ignoring `cache_control`. Bodies come from `AnthropicClient.makeURLRequest`, the RequestDump
/// path; replies carry fake signed blocks, which no signature check reads here.
@MainActor
@Suite("Append-only requests within a turn (#314)", .timeLimit(.minutes(1)))
struct AppendOnlyRequestTests {
    private func expectPrefixChain(_ h: ThinkingHarness, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let bodies = try h.client.requests.map { try ThinkingFixtures.messagesIgnoringCacheControl(try ThinkingFixtures.body($0)) }
        for n in bodies.indices.dropLast() {
            #expect(Array(bodies[n + 1].prefix(bodies[n].count)) == bodies[n],
                    "request \(n + 2) does not extend request \(n + 1)", sourceLocation: sourceLocation)
        }
    }

    @Test("each request of a four-round turn extends the one before")
    func prefixChain() async throws {
        let dir = try ThinkingFixtures.tempDirectory("chain")
        defer { try? FileManager.default.removeItem(at: dir) }
        let h = try ThinkingHarness.make(ThinkingFixtures.fourRounds(), hooks: try ThinkingFixtures.hooks(in: dir),
                                         earlierTurn: true)
        await h.run()
        try #require(h.client.requests.count == 4)
        try expectPrefixChain(h)
    }

    @Test("replies that did not think keep the chain too")
    func prefixChainUnthought() async throws {
        let dir = try ThinkingFixtures.tempDirectory("chain-unthought")
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = [ThinkingFixtures.unthought(1, toolCall: true), ThinkingFixtures.reply(2, toolCall: true),
                      ThinkingFixtures.unthought(3, toolCall: false)]
        let h = try ThinkingHarness.make(script, hooks: try ThinkingFixtures.hooks(in: dir))
        await h.run()
        try #require(h.client.requests.count == 3)
        try expectPrefixChain(h)
    }

    @Test("PR 1 sends no block back: no request carries a thinking block or the stored field")
    func noThinkingOnTheWire() async throws {
        let dir = try ThinkingFixtures.tempDirectory("nowire")
        defer { try? FileManager.default.removeItem(at: dir) }
        let h = try ThinkingHarness.make(ThinkingFixtures.fourRounds(), hooks: try ThinkingFixtures.hooks(in: dir),
                                         earlierTurn: true)
        await h.run()
        for request in h.client.requests {
            let text = try ThinkingFixtures.bodyText(request)
            #expect(!text.contains("sig-"))
            #expect(!text.contains("anthropicBlocks"))
        }
    }

    @Test("no beta header reaches an unknown id; a check model gets it on every request")
    func headerPerModel() async throws {
        let dir = try ThinkingFixtures.tempDirectory("header")
        defer { try? FileManager.default.removeItem(at: dir) }
        let h = try ThinkingHarness.make(ThinkingFixtures.fourRounds(), hooks: try ThinkingFixtures.hooks(in: dir))
        await h.run()
        for request in h.client.requests {
            #expect(try ThinkingFixtures.urlRequest(request, model: "claude-made-up-9").value(forHTTPHeaderField: "anthropic-beta") == nil)
            #expect(try ThinkingFixtures.urlRequest(request).value(forHTTPHeaderField: "anthropic-beta") == AnthropicCapabilities.bindingBeta)
        }
    }
}
