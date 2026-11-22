import Testing
import Foundation
@testable import IrisKit
import MCP

/// #1116 (from #1101): a remote MCP server's headers carry the plugin's secrets (`${keychain:KEY}`,
/// expanded by `MCPManager.resolveHeaders`). A 307 from the configured host to another must not take
/// them along. Two loopback listeners stand in for the hosts: `127.0.0.1` answers 307 to `localhost`.
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
}
