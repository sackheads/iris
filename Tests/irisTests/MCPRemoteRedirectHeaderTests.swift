import Testing
import Foundation
@testable import IrisKit
import MCP

/// #1116 (from #1101): a remote MCP server's headers carry the plugin's secrets (`${keychain:KEY}`,
/// expanded by `MCPManager.resolveHeaders`). A 307 from the configured host to another must not take
/// them along (`RemoteMCPRedirectPolicy`). Two loopback listeners stand in for the hosts: `127.0.0.1`
/// answers 307 to `localhost`.
@Suite("a remote MCP server's redirect to another host does not carry its headers (#1116)", .serialized, .timeLimit(.minutes(1)))
struct MCPRemoteRedirectHeaderTests {
    private final class Seen: @unchecked Sendable {
        private let lock = NSLock()
        private var requests: [HTTPRequest] = []
        func add(_ request: HTTPRequest) { lock.withLock { requests.append(request) } }
        var all: [HTTPRequest] { lock.withLock { requests } }
    }

    private static let secret = "s3cret-\(UUID().uuidString)"

    /// Starts the server through `MCPManager`'s real path and returns what each host received.
    private func run(redirectTo target: (UInt16) -> String) async throws -> (first: [HTTPRequest], second: [HTTPRequest]) {
        let firstSeen = Seen(), secondSeen = Seen()
        let second = LoopbackHTTPListener(port: 0) { request in
            secondSeen.add(request)
            return .error(statusCode: 400, .invalidRequest("stub"))
        }
        try await second.start()
        defer { second.stop() }
        let secondPort = try #require(second.boundPort)
        let location = target(secondPort)
        let first = LoopbackHTTPListener(port: 0) { request in
            firstSeen.add(request)
            return .error(statusCode: 307, .invalidRequest("moved"), extraHeaders: ["Location": location])
        }
        try await first.start()
        defer { first.stop() }
        let firstPort = try #require(first.boundPort)

        let manager = MCPManager(configPath: FileManager.default.temporaryDirectory
                                    .appendingPathComponent("iris-1116-\(UUID().uuidString).json").path,
                                 fileSecrets: { ["TOK": Self.secret] }, remoteConnectTimeout: 5)
        await manager.setPluginConfigs(["p.srv": .remote(
            url: URL(string: "http://127.0.0.1:\(firstPort)/mcp")!,
            headers: ["X-Api-Key": "${keychain:TOK}", "Authorization": "Bearer ${keychain:TOK}"],
            allowedKeys: ["TOK"])])
        await manager.startServers()
        await manager.stopServers()
        return (firstSeen.all, secondSeen.all)
    }

    private func carriesSecret(_ request: HTTPRequest) -> Bool {
        request.headers.values.contains { $0.contains(Self.secret) }
    }

    @Test("a 307 to another host reaches that host without the plugin's secret headers")
    func crossHostRedirectDropsHeaders() async throws {
        let seen = try await run { "http://localhost:\($0)/mcp" }
        // The first host got the headers, so the second host's request is the one in question.
        #expect(seen.first.contains(where: carriesSecret), "the configured host never received the secret headers")
        #expect(!seen.second.contains(where: carriesSecret),
                "headers at the redirect target: \(seen.second.map(\.headers))")
    }

    @Test("control: the stub redirect is followed at all, so the test above is not vacuous")
    func redirectIsFollowed() async throws {
        let seen = try await run { "http://localhost:\($0)/mcp" }
        #expect(!seen.second.isEmpty, "the redirect target never received a request")
    }

    @Test("a redirect within the endpoint's origin keeps the headers, so a moved path still authenticates")
    func sameOriginRedirectKeepsHeaders() async throws {
        let moved = Seen()
        let listener = LoopbackHTTPListener(port: 0) { request in
            if request.path == "/mcp" { return .error(statusCode: 307, .invalidRequest("moved"), extraHeaders: ["Location": "/mcp2"]) }
            moved.add(request)
            return .error(statusCode: 400, .invalidRequest("stub"))
        }
        try await listener.start()
        defer { listener.stop() }
        let port = try #require(listener.boundPort)
        let manager = MCPManager(configPath: FileManager.default.temporaryDirectory
                                    .appendingPathComponent("iris-1116-\(UUID().uuidString).json").path,
                                 fileSecrets: { ["TOK": Self.secret] }, remoteConnectTimeout: 5)
        await manager.setPluginConfigs(["p.srv": .remote(url: URL(string: "http://127.0.0.1:\(port)/mcp")!,
                                                         headers: ["X-Api-Key": "${keychain:TOK}"], allowedKeys: ["TOK"])])
        await manager.startServers()
        await manager.stopServers()
        #expect(!moved.all.isEmpty, "the same-origin redirect was never followed")
        #expect(moved.all.allSatisfy(carriesSecret), "\(moved.all.map(\.headers))")
    }
}

@Suite("RemoteMCPRedirectPolicy: what leaves the endpoint's origin (#1116)")
struct RemoteMCPRedirectPolicyTests {
    private let policy = RemoteMCPRedirectPolicy(endpoint: URL(string: "https://mcp.example.com/mcp")!,
                                                 configuredHeaders: ["X-Api-Key"])

    private func headers(after target: String) -> [String: String] {
        var request = URLRequest(url: URL(string: target)!)
        for (name, value) in ["x-api-key": "k", "Authorization": "Bearer t", "Cookie": "c", "Mcp-Session-Id": "s",
                              "Accept": "application/json"] {
            request.setValue(value, forHTTPHeaderField: name)
        }
        return policy.redirect(request).allHTTPHeaderFields ?? [:]
    }

    @Test("same origin, any case or path or the default port spelled out: unchanged")
    func sameOrigin() {
        for target in ["https://mcp.example.com/other", "https://MCP.Example.com/mcp", "https://mcp.example.com:443/mcp"] {
            #expect(headers(after: target).count == 5, "\(target)")
        }
    }

    @Test("another host, another port, or https to http: the configured header (any case) and the credentials go; the rest stays",
          arguments: ["https://evil.example.net/mcp", "https://mcp.example.com:8443/mcp", "http://mcp.example.com/mcp",
                      "https://example.com/mcp"])
    func otherOrigin(_ target: String) {
        #expect(headers(after: target) == ["Accept": "application/json"], "\(target)")
    }
}
