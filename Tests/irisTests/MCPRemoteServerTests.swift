import Testing
import Foundation
@testable import IrisKit
import MCP

/// #1096: a remote server reached over Streamable HTTP, end to end against an in-process server
/// shaped like sharpei: stateless, JSON responses, 405 on the standalone GET, bearer auth.
@Suite("Remote MCP servers over Streamable HTTP, loopback (#1096)", .timeLimit(.minutes(1)))
struct MCPRemoteServerTests {
    private final class SeenHeaders: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String] = []
        func add(_ v: String?) { lock.withLock { values.append(v ?? "<none>") } }
        var all: [String] { lock.withLock { values } }
    }

    /// A stateless MCP server: one fresh `Server` + `StatelessHTTPServerTransport` per request, as
    /// `IrisMCPProviderServer.dispatch` does. Requests without `Bearer <token>` get a 401.
    private static func makeServer(token: String, seen: SeenHeaders) -> LoopbackHTTPListener {
        LoopbackHTTPListener(port: 0) { request in
            seen.add(request.header("Authorization"))
            guard request.header("Authorization") == "Bearer \(token)" else {
                return .error(statusCode: 401, .invalidRequest("unauthorized"))
            }
            let server = Server(name: "fake-sharpei", version: "1",
                                capabilities: .init(tools: .init(listChanged: false)))
            await server.withMethodHandler(ListTools.self) { _ in
                ListTools.Result(tools: [
                    MCP.Tool(name: "echo", description: "Echoes its input",
                             inputSchema: ["type": "object", "properties": ["text": ["type": "string"]]],
                             annotations: .init(readOnlyHint: true)),
                ])
            }
            await server.withMethodHandler(CallTool.self) { params in
                let text = params.arguments?["text"]?.stringValue ?? ""
                return CallTool.Result(content: [.text(text: "echo: \(text)", annotations: nil, _meta: nil)])
            }
            let transport = StatelessHTTPServerTransport()
            do { try await server.start(transport: transport) } catch {
                return .error(statusCode: 500, .internalError("start failed"))
            }
            let response = await transport.handleRequest(request)
            await server.stop()
            return response
        }
    }

    private func withConfig(_ json: String, _ body: (String) async throws -> Void) async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("iris-remote-mcp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("mcp_servers.json").path
        try Data(json.utf8).write(to: URL(fileURLWithPath: path))
        try await body(path)
    }

    @Test("connects, lists and calls a tool, with the keychain-expanded bearer token on every request")
    func roundTrip() async throws {
        let seen = SeenHeaders()
        let listener = Self.makeServer(token: "s3cret", seen: seen)
        try await listener.start()
        defer { listener.stop() }
        let port = try #require(listener.boundPort)

        try await withConfig("""
        {"mcpServers":{"sharpei":{"url":"http://127.0.0.1:\(port)/mcp",
          "headers":{"Authorization":"Bearer ${keychain:SHARPEI_TOKEN}"},"allowedKeys":["SHARPEI_TOKEN"]}}}
        """) { path in
            let manager = MCPManager(configPath: path, fileSecrets: { ["SHARPEI_TOKEN": "s3cret", "OTHER": "x"] })
            await manager.startServers()
            #expect(await manager.serverStatuses()["sharpei"] == .running(toolCount: 1))
            #expect(await manager.getGeminiTools().map(\.name) == ["sharpei___echo"])
            #expect(await manager.readOnlyToolNames() == ["sharpei___echo"])

            let out = await manager.callTool(name: "sharpei___echo", args: ["text": .string("hi")])
            #expect(out == "echo: hi")
            await manager.stopServers()
        }
        #expect(!seen.all.isEmpty)
        #expect(seen.all.allSatisfy { $0 == "Bearer s3cret" })
    }

    @Test("a wrong token fails that server only; a stdio sibling with a bad entry fails alone too")
    func wrongToken() async throws {
        let seen = SeenHeaders()
        let listener = Self.makeServer(token: "right", seen: seen)
        try await listener.start()
        defer { listener.stop() }
        let port = try #require(listener.boundPort)

        try await withConfig("""
        {"sharpei":{"url":"http://127.0.0.1:\(port)/mcp","headers":{"Authorization":"Bearer wrong"}},
         "broken":{"args":[]}}
        """) { path in
            let manager = MCPManager(configPath: path, fileSecrets: { [:] }, remoteConnectTimeout: 10)
            await manager.startServers()
            let statuses = await manager.serverStatuses()
            guard case .failed = statuses["sharpei"] else { Issue.record("sharpei: \(String(describing: statuses["sharpei"]))"); return }
            guard case .failed(let reason) = statuses["broken"] else { Issue.record("broken not failed"); return }
            #expect(reason.contains("command"))
            #expect(await manager.configuredServerNames() == ["sharpei", "broken"])
        }
    }

    @Test("a header key outside allowedKeys never opens a connection")
    func allowlistBlocksConnection() async throws {
        let seen = SeenHeaders()
        let listener = Self.makeServer(token: "x", seen: seen)
        try await listener.start()
        defer { listener.stop() }
        let port = try #require(listener.boundPort)

        try await withConfig("""
        {"evil":{"url":"http://127.0.0.1:\(port)/mcp","headers":{"Authorization":"Bearer ${keychain:GITHUB_TOKEN}"}}}
        """) { path in
            let manager = MCPManager(configPath: path, fileSecrets: { ["GITHUB_TOKEN": "leak-me"] })
            await manager.startServers()
            guard case .failed(let reason) = await manager.serverStatuses()["evil"] else { Issue.record("not failed"); return }
            #expect(reason.contains("allowedKeys"))
        }
        #expect(seen.all.isEmpty)
    }

    @Test("plain http to a non-loopback host is refused before any connection")
    func plainHTTPRefused() async throws {
        try await withConfig(#"{"far":{"url":"http://example.invalid/mcp"}}"#) { path in
            let manager = MCPManager(configPath: path, fileSecrets: { [:] })
            await manager.startServers()
            guard case .failed(let reason) = await manager.serverStatuses()["far"] else { Issue.record("not failed"); return }
            #expect(reason.contains("https"))
        }
    }

    @Test("a server that never answers times out as .failed instead of holding startup")
    func hungServer() async throws {
        let listener = LoopbackHTTPListener(port: 0) { _ in
            try? await Task.sleep(for: .seconds(30))
            return .ok()
        }
        try await listener.start()
        defer { listener.stop() }
        let port = try #require(listener.boundPort)

        try await withConfig(#"{"slow":{"url":"http://127.0.0.1:\#(port)/mcp"}}"#) { path in
            let manager = MCPManager(configPath: path, fileSecrets: { [:] }, remoteConnectTimeout: 1)
            let start = TestClock.now()
            let task = Task { await manager.startServers() }
            try await value(of: task, within: 15)
            #expect(TestClock.seconds(since: start) < 10)
            #expect(await manager.serverStatuses()["slow"] == .failed("timed out connecting"))
        }
    }
}
