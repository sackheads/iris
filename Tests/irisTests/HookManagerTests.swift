import Testing
import Foundation
@testable import iris

@Test func testHookManagerProceed() async throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("iris-hookmgr-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }
    let configURL = tempDir.appendingPathComponent("test_settings_proceed.json")
    
    // Command that returns modified JSON payload successfully
    let hookConfig = """
    {
      "hooks": {
        "BeforeTool": [
          {
            "matcher": "test_tool",
            "hooks": [
              {
                "type": "command",
                "command": "echo '{\\"modified\\": \\"yes\\"}'"
              }
            ]
          }
        ]
      }
    }
    """
    try hookConfig.write(to: configURL, atomically: true, encoding: .utf8)
    
    var hookManager = HookManager()
    hookManager.configPathOverride = configURL.path
    
    let decision = await hookManager.fireBeforeTool(toolName: "test_tool", args: ["test": .string("val")])
    
    if case .proceed(let modifiedData) = decision {
        #expect(modifiedData != nil)
        let json = try JSONSerialization.jsonObject(with: modifiedData!, options: []) as? [String: String]
        #expect(json?["modified"] == "yes")
    } else {
        Issue.record("Expected proceed with data")
    }
}

@Test func testHookManagerBlock() async throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("iris-hookmgr-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }
    let configURL = tempDir.appendingPathComponent("test_settings_block.json")
    
    // Command that exits with 2 to trigger a hard block
    let hookConfig = """
    {
      "hooks": {
        "BeforeTool": [
          {
            "matcher": "test_tool",
            "hooks": [
              {
                "type": "command",
                "command": ">&2 echo 'Blocked by test hook'; exit 2"
              }
            ]
          }
        ]
      }
    }
    """
    try hookConfig.write(to: configURL, atomically: true, encoding: .utf8)
    
    var hookManager = HookManager()
    hookManager.configPathOverride = configURL.path
    
    let decision = await hookManager.fireBeforeTool(toolName: "test_tool", args: [:])
    
    if case .block(let reason) = decision {
        #expect(reason == "Blocked by test hook")
    } else {
        Issue.record("Expected block")
    }
}

@Test func testHookManagerWarning() async throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("iris-hookmgr-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }
    let configURL = tempDir.appendingPathComponent("test_settings_warning.json")
    
    // Command that exits with non-zero (but not 2)
    let hookConfig = """
    {
      "hooks": {
        "BeforeAgent": [
          {
            "matcher": "BeforeAgent",
            "hooks": [
              {
                "type": "command",
                "command": "exit 1"
              }
            ]
          }
        ]
      }
    }
    """
    try hookConfig.write(to: configURL, atomically: true, encoding: .utf8)
    
    var hookManager = HookManager()
    hookManager.configPathOverride = configURL.path
    
    let decision = await hookManager.fireBeforeAgent(input: "test")
    
    // Warning is treated as proceed internally by fireEvent
    if case .proceed(let modifiedData) = decision {
        #expect(modifiedData != nil)
        let json = try? JSONSerialization.jsonObject(with: modifiedData!, options: []) as? [String: String]
        #expect(json?["input"] == "test")
    } else {
        Issue.record("Expected proceed")
    }
}

@Test func testHookManagerBeforeToolSelection() async throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("iris-hookmgr-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }
    let configURL = tempDir.appendingPathComponent("test_settings_tool_selection.json")
    
    let hookConfig = """
    {
      "hooks": {
        "BeforeToolSelection": [
          {
            "matcher": ".*",
            "hooks": [
              {
                "type": "command",
                "command": "echo '[]'"
              }
            ]
          }
        ]
      }
    }
    """
    try hookConfig.write(to: configURL, atomically: true, encoding: .utf8)
    
    var hookManager = HookManager()
    hookManager.configPathOverride = configURL.path
    
    // Test with a dummy tool. We expect the hook to replace it with an empty array.
    let decision = await hookManager.fireBeforeToolSelection(tools: [FunctionDeclaration(name: "test", description: "test", parameters: nil)])
    
    if case .proceed(let modifiedData) = decision {
        #expect(modifiedData != nil)
        let modifiedTools = try JSONDecoder().decode([FunctionDeclaration].self, from: modifiedData!)
        #expect(modifiedTools.isEmpty)
    } else {
        Issue.record("Expected proceed with modified data")
    }
}

@Test func testHookManagerPreCompress() async throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("iris-hookmgr-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }
    let configURL = tempDir.appendingPathComponent("test_settings_pre_compress.json")
    
    let hookConfig = """
    {
      "hooks": {
        "PreCompress": [
          {
            "matcher": ".*",
            "hooks": [
              {
                "type": "command",
                "command": "echo '[{\\"role\\": \\"system\\", \\"parts\\": [{\\"text\\": \\"compressed\\"}]}]'"
              }
            ]
          }
        ]
      }
    }
    """
    try hookConfig.write(to: configURL, atomically: true, encoding: .utf8)
    
    var hookManager = HookManager()
    hookManager.configPathOverride = configURL.path
    
    let originalHistory = [Content(role: "user", parts: [Part(text: "hello", functionCall: nil, functionResponse: nil)])]
    let decision = await hookManager.firePreCompress(history: originalHistory)
    
    if case .proceed(let modifiedData) = decision {
        #expect(modifiedData != nil)
        let modifiedHistory = try JSONDecoder().decode([Content].self, from: modifiedData!)
        #expect(modifiedHistory.count == 1)
        #expect(modifiedHistory[0].role == "system")
        #expect(modifiedHistory[0].parts.first?.text == "compressed")
    } else {
        Issue.record("Expected proceed with modified data")
    }
}

@Test func testHookManagerNotification() async throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("iris-hookmgr-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }
    let configURL = tempDir.appendingPathComponent("test_settings_notification.json")
    let testOutputURL = tempDir.appendingPathComponent("notification_output.txt")

    let hookConfig = """
    {
      "hooks": {
        "Notification": [
          {
            "matcher": ".*",
            "hooks": [
              {
                "type": "command",
                "command": "cat > '\(testOutputURL.path)'"
              }
            ]
          }
        ]
      }
    }
    """
    try hookConfig.write(to: configURL, atomically: true, encoding: .utf8)
    
    var hookManager = HookManager()
    hookManager.configPathOverride = configURL.path
    
    await hookManager.fireNotification(title: "Alert", body: "Something happened")
    
    // Poll for the process to write the file, up to 2 seconds
    var output = ""
    for _ in 0..<20 {
        if let currentOutput = try? String(contentsOf: testOutputURL, encoding: .utf8), currentOutput.contains("Something happened") {
            output = currentOutput
            break
        }
        try await Task.sleep(nanoseconds: 100_000_000)
    }
    
    #expect(output.contains("Alert"))
    #expect(output.contains("Something happened"))
}

@Test func testHookManagerChaining() async throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("iris-hookmgr-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }
    let configURL = tempDir.appendingPathComponent("test_settings_chaining.json")
    
    // Command 1 adds a field, Command 2 adds another field to the modified output of Command 1
    let hookConfig = """
    {
      "hooks": {
        "BeforeAgent": [
          {
            "matcher": ".*",
            "hooks": [
              {
                "type": "command",
                "command": "jq '. + {\\"step1\\": \\"done\\"}'"
              },
              {
                "type": "command",
                "command": "jq '. + {\\"step2\\": \\"done\\"}'"
              }
            ]
          }
        ]
      }
    }
    """
    try hookConfig.write(to: configURL, atomically: true, encoding: .utf8)
    
    var hookManager = HookManager()
    hookManager.configPathOverride = configURL.path
    
    let decision = await hookManager.fireBeforeAgent(input: "test")
    
    if case .proceed(let modifiedData) = decision {
        #expect(modifiedData != nil)
        let json = try JSONSerialization.jsonObject(with: modifiedData!, options: []) as? [String: String]
        #expect(json?["input"] == "test")
        #expect(json?["step1"] == "done")
        #expect(json?["step2"] == "done")
    } else {
        Issue.record("Expected proceed with chained data")
    }
}

@Test func testHookManagerMissingEventTypes() async throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("iris-hookmgr-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }
    let configURL = tempDir.appendingPathComponent("test_settings_missing_events.json")
    
    let hookConfig = """
    {
      "hooks": {
        "AfterTool": [
          {
            "matcher": ".*",
            "hooks": [ { "type": "command", "command": "jq '. + {\\"hooked\\": \\"AfterTool\\"}'" } ]
          }
        ],
        "BeforeModel": [
          {
            "matcher": ".*",
            "hooks": [ { "type": "command", "command": "echo '{\\"hooked\\": \\"BeforeModel\\"}'" } ]
          }
        ],
        "AfterModel": [
          {
            "matcher": ".*",
            "hooks": [ { "type": "command", "command": "echo '{\\"hooked\\": \\"AfterModel\\"}'" } ]
          }
        ],
        "SessionStart": [
          {
            "matcher": ".*",
            "hooks": [ { "type": "command", "command": "echo '{\\"hooked\\": \\"SessionStart\\"}'" } ]
          }
        ],
        "AfterAgent": [
          {
            "matcher": ".*",
            "hooks": [ { "type": "command", "command": "echo '{\\"hooked\\": \\"AfterAgent\\"}'" } ]
          }
        ]
      }
    }
    """
    try hookConfig.write(to: configURL, atomically: true, encoding: .utf8)
    
    var hookManager = HookManager()
    hookManager.configPathOverride = configURL.path
    
    // Test AfterTool
    let afterToolDecision = await hookManager.fireAfterTool(toolName: "test_tool", result: "result")
    if case .proceed(let data) = afterToolDecision, let json = try? JSONSerialization.jsonObject(with: data!, options: []) as? [String: String] {
        #expect(json["hooked"] == "AfterTool")
    } else { Issue.record("AfterTool failed") }
    
    // Test BeforeModel
    let req = GeminiRequest(contents: [], systemInstruction: nil, tools: nil)
    let beforeModelDecision = await hookManager.fireBeforeModel(request: req)
    if case .proceed(let data) = beforeModelDecision, let json = try? JSONSerialization.jsonObject(with: data!, options: []) as? [String: String] {
        #expect(json["hooked"] == "BeforeModel")
    } else { Issue.record("BeforeModel failed") }
    
    // Test AfterModel
    let res = GeminiResponse(candidates: nil, usageMetadata: nil)
    let afterModelDecision = await hookManager.fireAfterModel(response: res)
    if case .proceed(let data) = afterModelDecision, let json = try? JSONSerialization.jsonObject(with: data!, options: []) as? [String: String] {
        #expect(json["hooked"] == "AfterModel")
    } else { Issue.record("AfterModel failed") }
    
    // Test SessionStart
    let sessionStartDecision = await hookManager.fireSessionStart(conversationId: UUID())
    if case .proceed(let data) = sessionStartDecision, let json = try? JSONSerialization.jsonObject(with: data!, options: []) as? [String: String] {
        #expect(json["hooked"] == "SessionStart")
    } else { Issue.record("SessionStart failed") }
    
    // Test AfterAgent
    let afterAgentDecision = await hookManager.fireAfterAgent(output: "test")
    if case .proceed(let data) = afterAgentDecision, let json = try? JSONSerialization.jsonObject(with: data!, options: []) as? [String: String] {
        #expect(json["hooked"] == "AfterAgent")
    } else { Issue.record("AfterAgent failed") }
}

@Test func testHookManagerLoginPathEnv() async throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("iris-hookmgr-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }
    let configURL = tempDir.appendingPathComponent("test_settings_path.json")
    let markerURL = tempDir.appendingPathComponent("hook_path_\(UUID().uuidString).txt")

    // #228: command hooks run with the bare GUI environment otherwise, so a hook that calls a
    // pyenv/nvm/Homebrew CLI would exit 127. The hook's PATH must begin with the login dirs.
    let hookConfig = """
    {
      "hooks": {
        "BeforeTool": [
          {
            "matcher": "test_tool",
            "hooks": [
              { "type": "command", "command": "printf '%s' \\"$PATH\\" > '\(markerURL.path)'" }
            ]
          }
        ]
      }
    }
    """
    try hookConfig.write(to: configURL, atomically: true, encoding: .utf8)

    var hookManager = HookManager()
    hookManager.configPathOverride = configURL.path

    _ = await hookManager.fireBeforeTool(toolName: "test_tool", args: [:])

    var path = ""
    for _ in 0..<20 {
        if let current = try? String(contentsOf: markerURL, encoding: .utf8), !current.isEmpty {
            path = current
            break
        }
        try await Task.sleep(nanoseconds: 100_000_000)
    }

    // #319: asserting the hook's first PATH element equals defaultSearchDirs().first is fragile —
    // the hook's `/bin/zsh -c` still sources ~/.zshenv (every zsh invocation does, login or not),
    // and a user's own PATH edits there are legitimate and expected to apply to their hooks too.
    // What #228/#315 actually promise is that the login search dirs are present, in order; assert
    // that as a subsequence instead of requiring them to be first.
    let hookPathDirs = path.split(separator: ":").map(String.init)
    let loginDirs = BinaryResolver.defaultSearchDirs()
    #expect(!loginDirs.isEmpty, "defaultSearchDirs() returned nothing — the subsequence check below would pass vacuously")
    var remaining = loginDirs[...]
    for dir in hookPathDirs {
        if dir == remaining.first {
            remaining = remaining.dropFirst()
        }
    }
    #expect(remaining.isEmpty, "expected login search dirs \(loginDirs) to appear in order within hook PATH \(hookPathDirs)")
}
