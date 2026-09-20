import XCTest
@testable import iris

@MainActor
final class SubagentManagerTests: XCTestCase {
    
    override func setUp() {
        super.setUp()
        URLProtocol.registerClass(MockURLProtocol.self)
        // Clear user defaults for clean state
        UserDefaults.standard.removeObject(forKey: "iris_conversations")
        UserDefaults.standard.set("Anthropic", forKey: "PRIMARY_PROVIDER")
        UserDefaults.standard.set("claude-3-5-sonnet", forKey: "ANTHROPIC_MODEL_MEDIUM")
        ConfigManager.shared.primaryProvider = "Anthropic"
        ConfigManager.shared.anthropicModelMedium = "claude-3-5-sonnet"
        ConfigManager.shared.anthropicAPIKey = "mock-api-key"
    }
    
    override func tearDown() {
        URLProtocol.unregisterClass(MockURLProtocol.self)
        MockURLProtocol.handler = nil
        super.tearDown()
    }
    
    func testSubagentExecutionBlocksAndReturnsSummary() async throws {
        // Setup AppState
        let state = AppState()
        
        let lock = NSLock()
        var count = 0
        
        // Mock the LLM to instantly call `goal_complete`
        MockURLProtocol.handler = { request in
            lock.lock()
            let currentCount = count
            count += 1
            lock.unlock()
            
            let responseJson: [String: Any]
            if currentCount >= 1 {
                // Break the loop
                responseJson = [
                    "id": UUID().uuidString,
                    "type": "message",
                    "role": "assistant",
                    "model": "claude-3-5-sonnet",
                    "content": [
                        [
                            "type": "text",
                            "text": "Finished."
                        ]
                    ],
                    "usage": [
                        "input_tokens": 10,
                        "output_tokens": 10
                    ]
                ]
            } else {
                responseJson = [
                    "id": UUID().uuidString,
                    "type": "message",
                    "role": "assistant",
                    "model": "claude-3-5-sonnet",
                    "content": [
                        [
                            "type": "tool_use",
                            "id": "call_1",
                            "name": "goal_complete",
                            "input": [
                                "summary": "I have audited the code securely."
                            ]
                        ]
                    ],
                    "usage": [
                        "input_tokens": 10,
                        "output_tokens": 10
                    ]
                ]
            }
            let responseData = try! JSONSerialization.data(withJSONObject: responseJson)
            let httpResponse = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (httpResponse, responseData)
        }
        
        let parentConversationId = UUID()
        await MainActor.run {
            state.createNewConversation(id: parentConversationId)
        }
        
        let summary = await SubagentManager.shared.runSubagent(
            role: "security_auditor",
            task: "Find vulnerabilities",
            effort: "easy",
            parentConversationId: parentConversationId, appState: state).rendered
        
        XCTAssertTrue(summary.contains("I have audited the code securely."))
        XCTAssertTrue(summary.contains("status: completed"))
        XCTAssertTrue(summary.contains("goal_complete called"))
    }
    
    func testConcurrentSubagentExecution() async throws {
        let state = AppState()
        
        let lock = NSLock()
        var count = 0
        
        // Mock LLM to return a success message indicating concurrency test
        MockURLProtocol.handler = { request in
            lock.lock()
            let currentCount = count
            count += 1
            lock.unlock()
            
            let responseJson: [String: Any]
            if currentCount >= 5 {
                responseJson = [
                    "id": UUID().uuidString,
                    "type": "message",
                    "role": "assistant",
                    "model": "claude-3-5-sonnet",
                    "content": [
                        [
                            "type": "text",
                            "text": "Finished."
                        ]
                    ],
                    "usage": ["input_tokens": 10, "output_tokens": 10]
                ]
            } else {
                responseJson = [
                    "id": UUID().uuidString,
                    "type": "message",
                    "role": "assistant",
                    "model": "claude-3-5-sonnet",
                    "content": [
                        [
                            "type": "tool_use",
                            "id": "call_2",
                            "name": "goal_complete",
                            "input": [
                                "summary": "Concurrent execution complete."
                            ]
                        ]
                    ],
                    "usage": ["input_tokens": 10, "output_tokens": 10]
                ]
            }
            let responseData = try! JSONSerialization.data(withJSONObject: responseJson)
            let httpResponse = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (httpResponse, responseData)
        }
        
        let parentConversationId = UUID()
        await MainActor.run {
            state.createNewConversation(id: parentConversationId)
        }
        
        // Run 5 subagents concurrently using the ResultHolder fix
        let results = await withTaskGroup(of: String.self) { group in
            for i in 0..<5 {
                group.addTask {
                    return await SubagentManager.shared.runSubagent(
                        role: "worker_\(i)",
                        task: "Task \(i)",
                        effort: "medium",
                        parentConversationId: parentConversationId, appState: state).rendered
                }
            }
            
            var collected: [String] = []
            for await result in group {
                collected.append(result)
            }
            return collected
        }
        
        XCTAssertEqual(results.count, 5, "All 5 concurrent subagents should return successfully")
        for res in results {
            XCTAssertTrue(res.contains("Concurrent execution complete."))
        }
    }
    func testInvalidEffortStringDefaultsToMedium() async throws {
        let state = AppState()
        
        let lock = NSLock()
        var usedModel = ""
        
        MockURLProtocol.handler = { request in
            let bodyData: Data
            if let stream = request.httpBodyStream {
                stream.open()
                let bufferSize = 1024
                let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
                var data = Data()
                while stream.hasBytesAvailable {
                    let read = stream.read(buffer, maxLength: bufferSize)
                    if read > 0 { data.append(buffer, count: read) } else { break }
                }
                buffer.deallocate()
                stream.close()
                bodyData = data
            } else {
                bodyData = request.httpBody ?? Data()
            }
            
            if let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any], let model = json["model"] as? String {
                lock.lock()
                usedModel = model
                lock.unlock()
            }
            
            let responseJson: [String: Any] = [
                "id": UUID().uuidString,
                "type": "message",
                "role": "assistant",
                "model": "claude-3-5-sonnet",
                "content": [
                    [
                        "type": "tool_use",
                        "id": "call_1",
                        "name": "goal_complete",
                        "input": [
                            "summary": "Finished with unknown effort."
                        ]
                    ]
                ],
                "usage": ["input_tokens": 10, "output_tokens": 10]
            ]
            let responseData = try! JSONSerialization.data(withJSONObject: responseJson)
            let httpResponse = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (httpResponse, responseData)
        }
        
        let parentConversationId = UUID()
        await MainActor.run {
            state.createNewConversation(id: parentConversationId)
        }
        
        // Use an invalid effort string. It should fall back to .medium which is claude-3-5-sonnet
        let summary = await SubagentManager.shared.runSubagent(
            role: "security_auditor",
            task: "Find vulnerabilities",
            effort: "invalid_effort_string",
            parentConversationId: parentConversationId, appState: state).rendered
        
        XCTAssertTrue(summary.contains("Finished with unknown effort."))
        XCTAssertEqual(usedModel, "claude-3-5-sonnet")
    }

    func testNeverCompletingSubagentTimesOut() async throws {
        let state = AppState()

        // Always return plain text — the subagent never calls goal_complete, so it loops until the cap.
        MockURLProtocol.handler = { request in
            let responseJson: [String: Any] = [
                "id": UUID().uuidString, "type": "message", "role": "assistant",
                "model": "claude-3-5-sonnet",
                "content": [["type": "text", "text": "Still working..."]],
                "usage": ["input_tokens": 10, "output_tokens": 10]
            ]
            let data = try! JSONSerialization.data(withJSONObject: responseJson)
            let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, data)
        }

        let parentId = UUID()
        await MainActor.run { state.createNewConversation(id: parentId) }

        let summary = await SubagentManager.shared.runSubagent(
            role: "worker", task: "loop forever", effort: "easy",
            parentConversationId: parentId, maxIterations: 3, appState: state).rendered   // ~300ms cap

        XCTAssertTrue(summary.contains("status: timed out"))
    }

    func testRolePromptIncludesVMConfigAuthority() {
        let prompt = SubagentManager.shared.generateRolePrompt(role: "engineer")
        XCTAssertTrue(prompt.contains("fully configurable sandboxed micro-VM"))
        XCTAssertTrue(prompt.contains("full root permissions"))
    }

    func testSubagentWriteIsRecordedInResult() async throws {
        let state = AppState()
        // Fast-path approve write_file for the exact path the mock uses (spec §5 / requestApproval).
        PermissionManager.shared.allowGlobally(toolName: "write_file", details: "ledger_probe.txt")

        let lock = NSLock(); var count = 0
        MockURLProtocol.handler = { request in
            lock.lock(); let c = count; count += 1; lock.unlock()
            let input: [String: Any]
            if c == 0 {
                input = ["type": "tool_use", "id": "w1", "name": "write_file",
                         "input": ["path": "ledger_probe.txt", "content": "hi"]]
            } else {
                input = ["type": "tool_use", "id": "g1", "name": "goal_complete",
                         "input": ["summary": "wrote the file"]]
            }
            let responseJson: [String: Any] = [
                "id": UUID().uuidString, "type": "message", "role": "assistant",
                "model": "claude-3-5-sonnet", "content": [input],
                "usage": ["input_tokens": 10, "output_tokens": 10]
            ]
            let data = try! JSONSerialization.data(withJSONObject: responseJson)
            let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, data)
        }

        let parentId = UUID()
        await MainActor.run { state.createNewConversation(id: parentId) }
        let summary = await SubagentManager.shared.runSubagent(
            role: "engineer", task: "write a file", effort: "easy", parentConversationId: parentId, appState: state).rendered

        XCTAssertTrue(summary.contains("Files written (1)"))
        XCTAssertTrue(summary.contains("ledger_probe.txt"))

        // Clean up the file written during this test.
        let probePath = FileManager.default.currentDirectoryPath + "/ledger_probe.txt"
        try? FileManager.default.removeItem(atPath: probePath)
    }
}
