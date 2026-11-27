import Foundation
import Testing
@testable import IrisKit

// #1437 diagnosis only; not for main. Does each tick's cache read point sit where the previous tick wrote, over the
// same bytes? Fake client, real request assembly and real Anthropic body encoding.
@MainActor
@Suite struct Measure1437MarkerTests {
    @Test func markerContinuity() async throws {
        let state = AppState(store: try ConversationStore.inMemory(), tier2Provisioning: .provisioned,
                             tier3Provisioning: .provisioned, createIfEmpty: false, emitLaunchNotices: false)
        let id = state.createNewConversation(isBackground: false, select: true)
        let ticks = 8
        let replies = (1...ticks).map { n in
            GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [Part(text: "ack \(n)")]))], usageMetadata: nil)
        }
        let dumped = LockedBox<[GeminiRequest]>([])
        let engine = IrisEngine(state: state, tier: .medium, client: FakeLLMClient(responses: replies), retryDelays: [],
                                protectionEnabled: false, sessionPeerCount: 0,
                                requestDumpSink: { request, _, _ in dumped.withLock { $0.append(request) } },
                                cacheTTLOverride: CacheTTLPolicy(prefix: .oneHour, history: .oneHour))
        let prompt = "Loop tick: read this board, then reply with exactly `ack` and the number of open items. No tools.\n"
            + (1...12).map { "- item \($0): open" }.joined(separator: "\n")
        for _ in 1...ticks { await engine.processInput(prompt, source: "Loop", conversationId: id) }

        let bodies: [[String: Any]] = try dumped.withLock { $0 }.map { request in
            let url = try AnthropicClient.makeURLRequest(request: request, model: "claude-sonnet-5-5",
                                                         transport: .direct(apiKey: "k", baseURL: ""), stream: false)
            let data = url.httpBody ?? Data()
            return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        }
        func messages(_ body: [String: Any]) -> [[String: Any]] { body["messages"] as? [[String: Any]] ?? [] }
        func markers(_ body: [String: Any]) -> [Int] {
            messages(body).indices.filter { i in
                ((messages(body)[i]["content"] as? [[String: Any]])?.last?["cache_control"]) != nil
            }
        }
        func stripped(_ body: [String: Any], through i: Int) -> String {
            let msgs = messages(body).prefix(i + 1).map { msg -> [String: Any] in
                var m = msg
                m["content"] = (msg["content"] as? [[String: Any]])?.map { var b = $0; b.removeValue(forKey: "cache_control"); return b }
                return m
            }
            var head = body; head["messages"] = Array(msgs); head.removeValue(forKey: "max_tokens")
            if var sys = head["system"] as? [[String: Any]] { sys = sys.map { var b = $0; b.removeValue(forKey: "cache_control"); return b }; head["system"] = sys }
            head.removeValue(forKey: "tools")   // compared separately below
            return String(decoding: (try? JSONSerialization.data(withJSONObject: head, options: [.sortedKeys])) ?? Data(), as: UTF8.self)
        }
        func toolsAndSystem(_ body: [String: Any]) -> String {
            String(decoding: (try? JSONSerialization.data(withJSONObject: [body["tools"] ?? [], body["system"] ?? []], options: [.sortedKeys])) ?? Data(), as: UTF8.self)
        }
        print("M1437|ticks=\(bodies.count) messages per tick=\(bodies.map { messages($0).count })")
        for k in 1..<bodies.count {
            let prev = bodies[k - 1], cur = bodies[k]
            let prevMarks = Set(markers(prev))
            let reads = markers(cur).filter { $0 < messages(cur).count - 1 }   // (b) and (c); (d) is this request's own write
            let hits = reads.filter { prevMarks.contains($0) && stripped(prev, through: $0) == stripped(cur, through: $0) }
            // Where do the two requests first differ?
            let n = min(messages(prev).count, messages(cur).count)
            let firstDiff = (0..<n).first { stripped(prev, through: $0) != stripped(cur, through: $0) }
            print("M1437|tick \(k + 1): markers=\(markers(cur)) prevMarkers=\(prevMarks.sorted()) readable=\(hits) "
                  + "toolsSystemSame=\(toolsAndSystem(prev) == toolsAndSystem(cur)) firstDiffMsg=\(firstDiff.map(String.init) ?? "none")")
            if let d = firstDiff {
                let a = String(decoding: (try? JSONSerialization.data(withJSONObject: messages(prev)[d], options: [.sortedKeys])) ?? Data(), as: UTF8.self)
                let b = String(decoding: (try? JSONSerialization.data(withJSONObject: messages(cur)[d], options: [.sortedKeys])) ?? Data(), as: UTF8.self)
                print("M1437|   prev[\(d)]=\(a.prefix(300))")
                print("M1437|   cur [\(d)]=\(b.prefix(300))")
            }
        }
    }
}
