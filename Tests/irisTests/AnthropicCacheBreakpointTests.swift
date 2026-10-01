import Testing
import Foundation
@testable import iris

/// 5a §1. `markLastContentBlock` skipped a message whose last block was a `tool_result`, so a
/// round ending in tool results wrote its cache entry at the assistant's `tool_use` instead, and
/// the results were re-sent uncached on the next round and the next turn. The API accepts
/// `cache_control` on `tool_result` blocks; the skip was an artifact.
@Suite("Anthropic cache breakpoints (5a)")
struct AnthropicCacheBreakpointTests {
    private func part(_ text: String) -> Part {
        Part(text: text, functionCall: nil, functionResponse: nil, thought_signature: nil, thoughtSignature: nil)
    }

    private func toolRoundRequest() -> GeminiRequest {
        let call = FunctionCall(name: "run_command", args: ["command": .string("ls")], id: "call_1")
        let callPart = Part(text: nil, functionCall: call, functionResponse: nil, thought_signature: nil, thoughtSignature: nil)
        let results = ["call_1", "call_2"].map { id in
            Part(text: nil, functionCall: nil,
                 functionResponse: FunctionResponse(name: "run_command", response: ["output": .string("ok")], id: id),
                 thought_signature: nil, thoughtSignature: nil)
        }
        return GeminiRequest(contents: [
            Content(role: "user", parts: [part("count the files")]),
            Content(role: "model", parts: [callPart]),
            Content(role: "user", parts: results),
        ], systemInstruction: Content(role: "system", parts: [part("system")]), tools: nil)
    }

    private func body(_ request: GeminiRequest) throws -> [String: Any] {
        let urlRequest = try AnthropicClient.makeURLRequest(request: request, model: "m", apiKey: "k", stream: false)
        let data = try #require(urlRequest.httpBody)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test("a round ending in tool results carries the breakpoint on its last tool_result")
    func toolResultIsMarked() throws {
        let messages = try #require(try body(toolRoundRequest())["messages"] as? [[String: Any]])
        let last = try #require(messages.last?["content"] as? [[String: Any]])
        #expect(last.last?["type"] as? String == "tool_result")
        #expect(last.last?["cache_control"] != nil, "the tool results must be inside the cached prefix of the next round")
    }

    @Test("marking tool results never exceeds the API's four breakpoints, with tools declared")
    func atMostFourMarkers() throws {
        var request = toolRoundRequest()
        request.tools = Self.tools
        let data = try JSONSerialization.data(withJSONObject: try body(request))
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(text.components(separatedBy: "\"cache_control\"").count - 1 <= 4)
    }

    // MARK: - Placement (final-review item 1)
    //
    // The markers are: system (covering the tools before it), the end of turn k-2 (the read
    // point), the end of turn k-1 (the write point the next turn reads), and the last message
    // (within-turn rounds). A turn's entry is a `user` message with a non-`tool_result` block.

    static let tools = [Tool(functionDeclarations: [
        FunctionDeclaration(name: "run_command", description: "run",
                            parameters: Schema(type: "OBJECT", properties: ["command": Schema(type: "STRING")], required: ["command"])),
        FunctionDeclaration(name: "reflect", description: "think", parameters: nil),
    ])]

    private func user(_ texts: String...) -> Content {
        Content(role: "user", parts: texts.map(part))
    }
    private func model(_ text: String) -> Content { Content(role: "model", parts: [part(text)]) }
    /// One tool round: the assistant's call and the user entry carrying its result.
    private func toolRound(_ n: Int) -> [Content] {
        let id = "call_\(n)"
        return [
            Content(role: "model", parts: [Part(text: nil, functionCall: FunctionCall(name: "run_command", args: ["command": .string("echo \(n)")], id: id),
                                                functionResponse: nil, thought_signature: nil, thoughtSignature: nil)]),
            Content(role: "user", parts: [Part(text: nil, functionCall: nil,
                                               functionResponse: FunctionResponse(name: "run_command", response: ["output": .string("\(n)")], id: id),
                                               thought_signature: nil, thoughtSignature: nil)]),
        ]
    }

    private func request(_ contents: [Content]) -> GeminiRequest {
        GeminiRequest(contents: contents, systemInstruction: Content(role: "system", parts: [part("system")]), tools: Self.tools)
    }

    /// Where the markers landed: message indices whose last block is marked (and no other block
    /// is), whether system and the last tool are marked, and the total count in the body.
    private struct Markers {
        var messages: [Int] = []
        var system = false
        var lastTool = false
        var total = 0
    }

    private func markers(_ request: GeminiRequest) throws -> Markers {
        let b = try body(request)
        var m = Markers()
        let messages = try #require(b["messages"] as? [[String: Any]])
        for (i, message) in messages.enumerated() {
            let content = try #require(message["content"] as? [[String: Any]])
            for (j, block) in content.enumerated() where block["cache_control"] != nil {
                #expect(j == content.count - 1, "message \(i) is marked on block \(j), not its last")
                m.messages.append(i)
            }
        }
        m.system = ((b["system"] as? [[String: Any]])?.last?["cache_control"]) != nil
        m.lastTool = ((b["tools"] as? [[String: Any]])?.last?["cache_control"]) != nil
        let data = try JSONSerialization.data(withJSONObject: b)
        let text = try #require(String(data: data, encoding: .utf8))
        m.total = text.components(separatedBy: "\"cache_control\"").count - 1
        return m
    }

    @Test("turn 3 after a tool-heavy turn 2: markers at system, end of turn 1, end of turn 2, last")
    func longMiddleTurn() throws {
        var contents = [user("turn 1"), model("answer 1"), user("turn 2")]
        for n in 0..<12 { contents += toolRound(n) }
        contents += [model("answer 2"), user("<turn_context>facts</turn_context>", "turn 3")]
        // Turn 2 alone is 26 blocks, past Anthropic's 20-block lookback: the end of turn 1 is
        // reachable only through an explicit marker.
        #expect(contents.count == 29)
        let m = try markers(request(contents))
        #expect(m.system)
        #expect(!m.lastTool, "system's marker already covers the tools that render before it")
        #expect(m.messages == [1, 27, 28])
        #expect(m.total == 4)
    }

    @Test("a first turn: system and its own entry")
    func firstTurn() throws {
        let m = try markers(request([user("<turn_context>facts</turn_context>", "hello")]))
        #expect(m.system)
        #expect(!m.lastTool)
        #expect(m.messages == [0])
        #expect(m.total == 2)
    }

    @Test("a within-turn tool round: end of turn k-2, end of turn k-1, and the last tool result")
    func withinTurnToolRound() throws {
        let contents = [user("turn 1"), model("answer 1"), user("turn 2"), model("answer 2"),
                        user("<turn_context>facts</turn_context>", "turn 3")] + toolRound(0) + toolRound(1)
        let m = try markers(request(contents))
        #expect(m.system)
        #expect(m.messages == [1, 3, 8])
        #expect(m.total == 4)
    }

    @Test("the second turn's first round: end of turn 1 and the last message")
    func secondTurn() throws {
        let m = try markers(request([user("turn 1"), model("answer 1"), user("turn 2")]))
        #expect(m.messages == [1, 2])
        #expect(m.total == 3)
    }

    @Test("without a system prompt the last tool carries the prefix marker instead")
    func noSystemMarksLastTool() throws {
        var r = request([user("turn 1"), model("answer 1"), user("turn 2"), model("answer 2"), user("turn 3")])
        r.systemInstruction = nil
        let m = try markers(r)
        #expect(!m.system)
        #expect(m.lastTool)
        #expect(m.messages == [1, 3, 4])
        #expect(m.total == 4)
    }
}

/// The whole request, end to end: consecutive engine turns with no fact match and no peers,
/// rendered by the client that sends them. Everything through the end of the previous turn must be
/// the same bytes, or the read point (§1's marker (b)/(c)) has nothing to match (5a final review).
@MainActor
@Suite("Anthropic whole-request prefix across turns (5a)")
struct AnthropicWholeRequestPrefixTests {
    private func body(_ request: GeminiRequest) throws -> [String: Any] {
        let urlRequest = try AnthropicClient.makeURLRequest(request: request, model: "m", apiKey: "k", stream: false)
        let data = try #require(urlRequest.httpBody)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func json(_ value: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed])
    }

    /// The markers move by design (each request marks its own turn boundaries), and a marker does
    /// not change the cached content, so messages are compared with `cache_control` removed.
    private func unmarked(_ messages: [[String: Any]]) -> [[String: Any]] {
        messages.map { message in
            var m = message
            if let content = m["content"] as? [[String: Any]] {
                m["content"] = content.map { block in
                    var b = block
                    b.removeValue(forKey: "cache_control")
                    return b
                }
            }
            return m
        }
    }

    @Test("tools, system and every message through the previous turn are byte-identical turn to turn")
    func consecutiveTurnsSharePrefix() async throws {
        let app = AppState()
        let id = UUID()
        app.createNewConversation(id: id)
        let client = CapturingLLMClient(reply: "ok")
        let engine = IrisEngine(state: app, tier: .medium, principal: .main, client: client, retryDelays: [],
                                streamResponses: false, factStore: try FactStoreManager(inMemory: true),
                                protectionEnabled: false, sessionPeerCount: 0)
        for prompt in ["first question", "second question", "third question"] {
            await engine.processInput(prompt, source: "UI", conversationId: id)
        }
        let requests = client.requests
        try #require(requests.count == 3)
        let bodies = try requests.map(body)
        for k in 1..<bodies.count {
            let before = bodies[k - 1], after = bodies[k]
            #expect(after["tools"] != nil)
            #expect(try json(before["tools"] as Any) == json(after["tools"] as Any), "tools, turn \(k + 1)")
            #expect(try json(before["system"] as Any) == json(after["system"] as Any), "system, turn \(k + 1)")
            let prev = try #require(before["messages"] as? [[String: Any]])
            let cur = try #require(after["messages"] as? [[String: Any]])
            // The previous request held turns 1..k; this one adds turn k's reply and the new entry.
            #expect(cur.count == prev.count + 2)
            let n = prev.count
            #expect(try json(unmarked(prev)) == json(unmarked(Array(cur.prefix(n)))), "messages[0..<\(n)], turn \(k + 1)")
        }
    }
}
