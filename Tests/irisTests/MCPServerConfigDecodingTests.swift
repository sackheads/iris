import Testing
import Foundation
@testable import IrisKit

/// #1096: the `mcp_servers.json` entry schema (stdio or remote), the legacy-file parser that
/// isolates a bad entry, the remote URL policy, and the per-server key allowlist on header secrets.
@Suite("MCP server config: remote entries, per-entry parsing, URL policy, key allowlist (#1096)")
struct MCPServerConfigDecodingTests {
    private func decode(_ json: String) throws -> MCPServerConfig {
        try JSONDecoder().decode(MCPServerConfig.self, from: Data(json.utf8))
    }

    // MARK: - Entry decoding

    @Test("stdio entry decodes as before; missing args is []")
    func stdio() throws {
        #expect(try decode(#"{"command":"uvx","args":["a"],"env":{"K":"v"}}"#)
                == .stdio(command: "uvx", args: ["a"], env: ["K": "v"]))
        #expect(try decode(#"{"command":"uvx"}"#) == .stdio(command: "uvx", args: [], env: nil))
    }

    @Test("remote entry: url, and the serverUrl / httpUrl aliases, all decode to the same case",
          arguments: ["url", "serverUrl", "httpUrl"])
    func remoteAliases(key: String) throws {
        let config = try decode(#"{"\#(key)":"https://h.example/mcp","headers":{"A":"b"},"allowedKeys":["T"]}"#)
        #expect(config == .remote(url: URL(string: "https://h.example/mcp")!, headers: ["A": "b"], allowedKeys: ["T"]))
    }

    @Test("remote entry with no headers or allowedKeys defaults both to empty")
    func remoteDefaults() throws {
        #expect(try decode(#"{"url":"https://h.example/mcp"}"#)
                == .remote(url: URL(string: "https://h.example/mcp")!, headers: [:], allowedKeys: []))
    }

    @Test("invalid shapes are refused", arguments: [
        #"{"url":"https://a/mcp","serverUrl":"https://a/mcp"}"#,            // two URL keys, even agreeing
        #"{"command":"x","url":"https://a/mcp"}"#,                         // both forms
        #"{"args":["x"]}"#,                                                // neither
        #"{"url":"https://a/mcp","env":{"K":"v"}}"#,                       // env on remote
        #"{"command":"x","headers":{"K":"v"}}"#,                           // headers on stdio
        #"{"command":"x","allowedKeys":["K"]}"#,                           // allowedKeys on stdio
        #"{"url":"https://a/mcp","type":"stdio"}"#,                        // type disagrees
        #"{"command":"x","type":"http"}"#,                                 // type disagrees
        #"{"url":"not a url at all"}"#,                                    // unparseable URL
    ])
    func refused(json: String) {
        #expect(throws: (any Error).self) { try decode(json) }
    }

    @Test("type sse is refused with a reason naming the legacy transport")
    func sseRefused() {
        do {
            _ = try decode(#"{"url":"https://a/sse","type":"sse"}"#)
            Issue.record("sse decoded")
        } catch {
            #expect(String(describing: error).contains("legacy HTTP+SSE"))
        }
    }

    @Test("type http / streamable-http (any case) and stdio are accepted when they agree")
    func typeAgrees() throws {
        _ = try decode(#"{"url":"https://a/mcp","type":"http"}"#)
        _ = try decode(#"{"url":"https://a/mcp","type":"Streamable-HTTP"}"#)
        _ = try decode(#"{"command":"x","type":"stdio"}"#)
    }

    @Test("unknown keys are ignored")
    func unknownKeys() throws {
        #expect(try decode(#"{"command":"x","disabled":false,"timeout":5}"#) == .stdio(command: "x", args: [], env: nil))
    }

    @Test("encoding round-trips both forms with canonical keys only")
    func roundTrip() throws {
        let remote = MCPServerConfig.remote(url: URL(string: "https://a/mcp")!, headers: ["A": "b"], allowedKeys: ["T"])
        let stdio = MCPServerConfig.stdio(command: "x", args: ["y"], env: nil)
        for config in [remote, stdio] {
            let data = try JSONEncoder().encode(config)
            #expect(try JSONDecoder().decode(MCPServerConfig.self, from: data) == config)
        }
        let text = String(decoding: try JSONEncoder().encode(remote), as: UTF8.self)
        #expect(text.contains("\"url\"") && !text.contains("serverUrl") && !text.contains("httpUrl"))
    }

    // MARK: - Legacy file parsing

    @Test("bare map and mcpServers wrapper parse the same")
    func wrapper() {
        let bare = MCPManager.parseLegacyFile(Data(#"{"a":{"command":"x"}}"#.utf8))
        let wrapped = MCPManager.parseLegacyFile(Data(#"{"mcpServers":{"a":{"command":"x"}}}"#.utf8))
        #expect(bare.configs == ["a": .stdio(command: "x", args: [], env: nil)])
        #expect(wrapped.configs == bare.configs)
        #expect(bare.failures.isEmpty && wrapped.failures.isEmpty)
    }

    @Test("one bad entry fails alone; its siblings still parse")
    func isolation() {
        let parsed = MCPManager.parseLegacyFile(Data(#"""
        {"good":{"command":"x"},"bad":{"args":[]},"remote":{"serverUrl":"https://a/mcp"},"junk":42}
        """#.utf8))
        #expect(Set(parsed.configs.keys) == ["good", "remote"])
        #expect(Set(parsed.failures.keys) == ["bad", "junk"])
        #expect(parsed.failures["bad"]!.hasPrefix("invalid entry: "))
        #expect(parsed.names == ["good", "remote", "bad", "junk"])
    }

    @Test("a file that is not a JSON object fails once under the reserved, dot-free name")
    func notAnObject() {
        for body in ["[1,2]", "{not json"] {
            let parsed = MCPManager.parseLegacyFile(Data(body.utf8))
            #expect(parsed.configs.isEmpty)
            #expect(Array(parsed.failures.keys) == [MCPManager.legacyFileStatusName])
        }
        #expect(!MCPManager.legacyFileStatusName.contains("."))
    }

    @Test("removing an entry keeps the wrapper and the entries it cannot model")
    func removePreserves() throws {
        let input = Data(#"{"mcpServers":{"gone":{"command":"x"},"weird":{"type":"sse","url":"https://a"},"keep":{"url":"https://b/mcp"}}}"#.utf8)
        let output = try #require(MCPManager.removingLegacyEntry(named: "gone", from: input))
        let root = try #require(try JSONSerialization.jsonObject(with: output) as? [String: Any])
        let servers = try #require(root["mcpServers"] as? [String: Any])
        #expect(Set(servers.keys) == ["weird", "keep"])
    }

    // MARK: - URL policy

    @Test("https and loopback http pass", arguments: [
        "https://sharpei.example/mcp", "http://localhost:8080/mcp", "http://127.0.0.1/mcp",
        "http://127.8.9.10:9/mcp", "http://[::1]:7/mcp", "HTTPS://upper.example/mcp",
    ])
    func urlAllowed(url: String) {
        #expect(MCPManager.remoteURLRefusal(URL(string: url)!) == nil)
    }

    @Test("plain http to anything else, and other schemes, are refused", arguments: [
        "http://example.com/mcp", "http://127.0.0.1.example.com/mcp", "http://10.0.0.1/mcp",
        "http://128.0.0.1/mcp", "ftp://127.0.0.1/mcp", "file:///tmp/mcp", "ws://localhost/mcp",
    ])
    func urlRefused(url: String) {
        #expect(MCPManager.remoteURLRefusal(URL(string: url)!) != nil)
    }

    @Test("every URL alias goes through the same policy", arguments: ["url", "serverUrl", "httpUrl"])
    func aliasesHitPolicy(key: String) throws {
        guard case .remote(let url, _, _) = try decode(#"{"\#(key)":"http://example.com/mcp"}"#) else {
            Issue.record("not remote"); return
        }
        #expect(MCPManager.remoteURLRefusal(url) != nil)
    }

    // MARK: - Header expansion and the key allowlist

    @Test("an allowed key expands; literals pass through")
    func headersAllowed() throws {
        let out = try MCPManager.resolveHeaders(
            ["Authorization": "Bearer ${keychain:T}", "X-Lit": "plain"],
            allowedKeys: ["T"], secrets: { ["T": "s3cret"] })
        #expect(out == ["Authorization": "Bearer s3cret", "X-Lit": "plain"])
    }

    @Test("a key outside allowedKeys fails closed even when present, and its value never reaches the expander")
    func headersNotAllowed() {
        do {
            _ = try MCPManager.resolveHeaders(["Authorization": "Bearer ${keychain:GITHUB_TOKEN}"],
                                              allowedKeys: ["T"],
                                              secrets: { ["T": "a", "GITHUB_TOKEN": "leak-me"] })
            Issue.record("expanded a key outside the allowlist")
        } catch {
            let text = String(describing: error)
            #expect(text.contains("GITHUB_TOKEN") && text.contains("allowedKeys") && text.contains("Authorization"))
            #expect(!text.contains("leak-me"))
        }
    }

    @Test("no allowedKeys means no references at all, and the Keychain is not read")
    func headersNoAllowlist() {
        var reads = 0
        #expect(throws: (any Error).self) {
            _ = try MCPManager.resolveHeaders(["A": "${keychain:T}"], allowedKeys: [],
                                              secrets: { reads += 1; return ["T": "v"] })
        }
        #expect(reads == 0)
    }

    @Test("an allowed but missing key fails with a different reason")
    func headersMissing() {
        do {
            _ = try MCPManager.resolveHeaders(["A": "${keychain:T}"], allowedKeys: ["T"], secrets: { [:] })
            Issue.record("expanded a missing key")
        } catch {
            let text = String(describing: error)
            #expect(text.contains("not in the Keychain") && !text.contains("allowedKeys"))
        }
    }

    @Test("no references means no Keychain read")
    func headersNoRefs() throws {
        var reads = 0
        let out = try MCPManager.resolveHeaders(["A": "b"], allowedKeys: ["T"], secrets: { reads += 1; return [:] })
        #expect(out == ["A": "b"] && reads == 0)
    }
}
