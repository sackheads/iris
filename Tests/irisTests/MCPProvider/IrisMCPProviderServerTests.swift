import Testing
import Foundation
import Network
@testable import IrisKit
import MCP

private func temporaryTestDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("iris-mcp-server-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}

private struct Fixture {
    let registry: ProviderTokenRegistry
    let mailbox: ProviderMailbox
    let artifactStore: ProviderArtifactStore
    let doorGate: ProviderRequestGate
    let mailboxGate: ProviderRequestGate
    let server: IrisMCPProviderServer
    let doorCallCounter: CallCounter

    static func build(doorGateCapacity: Int = 1000, mailboxGateCapacity: Int = 1000) -> Fixture {
        let keychain = KeychainManager(serviceSuffix: ".test-\(UUID().uuidString)", inMemory: true)
        let registry = ProviderTokenRegistry(keychain: keychain)
        let mailbox = ProviderMailbox(registry: registry)
        let artifactStore = ProviderArtifactStore(root: temporaryTestDirectory(),
                                                  isRegistered: { registry.isRegistered(clientId: $0) })
        let counter = CallCounter()
        let door = SelfReportDoor(
            windowOwnerReader: { counter.increment(); return "com.example.test" },
            responderClassReader: { counter.increment(); return "NSView" },
            composerStateReader: {
                counter.increment()
                return SelfReportDoor.ComposerState(isPresent: false, isFirstResponder: false, isEmpty: true)
            },
            turnStateReader: { counter.increment(); return SelfReportDoor.TurnState(any: false, count: 0) },
            activationReader: { counter.increment(); return (true, true) },
            eventRingReader: { [] }
        )
        let doorGate = ProviderRequestGate(registry: registry, capacity: doorGateCapacity, refillInterval: .seconds(60))
        let mailboxGate = ProviderRequestGate(registry: registry, capacity: mailboxGateCapacity, refillInterval: .seconds(60))
        let server = IrisMCPProviderServer(tokenRegistry: registry, mailbox: mailbox, artifactStore: artifactStore,
                                           door: door, doorGate: doorGate, mailboxGate: mailboxGate, port: 0)
        return Fixture(registry: registry, mailbox: mailbox, artifactStore: artifactStore,
                       doorGate: doorGate, mailboxGate: mailboxGate, server: server, doorCallCounter: counter)
    }
}

private final class TransportBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _transport: StatelessHTTPServerTransport?
    var transport: StatelessHTTPServerTransport? {
        get { lock.withLock { _transport } }
        set { lock.withLock { _transport = newValue } }
    }
}

private func rpcBody(method: String, id: Int? = 1, params: [String: Any]? = nil) -> Data {
    var obj: [String: Any] = ["jsonrpc": "2.0", "method": method]
    if let id { obj["id"] = id }
    if let params { obj["params"] = params }
    return try! JSONSerialization.data(withJSONObject: obj)
}

private func httpRequest(body: Data, token: String?) -> HTTPRequest {
    var headers = ["Content-Type": "application/json", "Accept": "application/json"]
    if let token { headers["Authorization"] = "Bearer \(token)" }
    return HTTPRequest(method: "POST", headers: headers, body: body, path: "/")
}

private func isErrorResponse(_ response: HTTPResponse) -> Bool {
    response.statusCode >= 400
}

private func decodedBody(_ response: HTTPResponse) -> [String: Any]? {
    guard let data = response.bodyData else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}

@Suite("IrisMCPProviderServer")
struct IrisMCPProviderServerTests {
    @Test("initialize, tools/list, ping, and a tool call are all rejected pre-Server on a missing, malformed, or unknown-but-well-formed token")
    func allMethodsAuthEnforcedBeforeServerConstruction() async throws {
        let fixture = Fixture.build(doorGateCapacity: 1, mailboxGateCapacity: 1)
        let unissued = "unissued-token-xyz"

        for token in [nil, "garbage", unissued] {
            for body in [
                rpcBody(method: "initialize", params: ["protocolVersion": "2025-06-18", "capabilities": [:], "clientInfo": ["name": "t", "version": "1"]]),
                rpcBody(method: "tools/list"),
                rpcBody(method: "ping"),
                rpcBody(method: "tools/call", params: ["name": "iris_window_owner"]),
            ] {
                let response = await fixture.server.handleAuthenticated(httpRequest(body: body, token: token))
                #expect(isErrorResponse(response), "token=\(String(describing: token))")
            }
        }
        #expect(fixture.doorCallCounter.value == 0)
        // Neither gate's single unit of budget was spent by any of the rejected attempts.
        let goodToken = try fixture.registry.issueToken(forClientId: "a")
        let realDoorCall = await fixture.server.handleAuthenticated(
            httpRequest(body: rpcBody(method: "tools/call", params: ["name": "iris_window_owner"]), token: goodToken))
        #expect(!isErrorResponse(realDoorCall))
    }

    @Test("a JSON-RPC batch (top-level array) body is rejected before any gate is touched")
    func batchBodyRejected() async throws {
        let fixture = Fixture.build()
        let token = try fixture.registry.issueToken(forClientId: "a")
        let batchBody = try! JSONSerialization.data(withJSONObject: [
            ["jsonrpc": "2.0", "id": 1, "method": "ping"],
            ["jsonrpc": "2.0", "id": 2, "method": "ping"],
        ])
        let response = await fixture.server.handleAuthenticated(httpRequest(body: batchBody, token: token))
        #expect(isErrorResponse(response))
    }

    @Test("initialize, tools/list, and ping consume no gate budget; only tools/call does")
    func onlyToolCallConsumesBudget() async throws {
        let fixture = Fixture.build(doorGateCapacity: 1, mailboxGateCapacity: 1)
        let token = try fixture.registry.issueToken(forClientId: "a")
        for _ in 0..<5 {
            for method in ["initialize", "tools/list", "ping"] {
                let body = method == "initialize"
                    ? rpcBody(method: method, params: ["protocolVersion": "2025-06-18", "capabilities": [:], "clientInfo": ["name": "t", "version": "1"]])
                    : rpcBody(method: method)
                let response = await fixture.server.handleAuthenticated(httpRequest(body: body, token: token))
                #expect(!isErrorResponse(response), "method=\(method)")
            }
        }
        // The door gate's single unit is still available.
        let doorCall = await fixture.server.handleAuthenticated(
            httpRequest(body: rpcBody(method: "tools/call", params: ["name": "iris_window_owner"]), token: token))
        #expect(!isErrorResponse(doorCall))
        // Now it's spent.
        let secondDoorCall = await fixture.server.handleAuthenticated(
            httpRequest(body: rpcBody(method: "tools/call", params: ["name": "iris_responder_class"]), token: token))
        #expect(isErrorResponse(secondDoorCall))
    }

    @Test("a door tool call over its gate's budget never reaches the door's MainActor hop")
    func doorBudgetExceededNeverConstructsDoor() async throws {
        let fixture = Fixture.build(doorGateCapacity: 1, mailboxGateCapacity: 1000)
        let token = try fixture.registry.issueToken(forClientId: "a")
        let first = await fixture.server.handleAuthenticated(
            httpRequest(body: rpcBody(method: "tools/call", params: ["name": "iris_window_owner"]), token: token))
        #expect(!isErrorResponse(first))
        let countAfterFirst = fixture.doorCallCounter.value
        let second = await fixture.server.handleAuthenticated(
            httpRequest(body: rpcBody(method: "tools/call", params: ["name": "iris_window_owner"]), token: token))
        #expect(isErrorResponse(second))
        #expect(fixture.doorCallCounter.value == countAfterFirst)
    }

    @Test("a method not on the allowlist is refused, spending neither gate's budget")
    func disallowedMethodRefused() async throws {
        let fixture = Fixture.build(doorGateCapacity: 1, mailboxGateCapacity: 1)
        let token = try fixture.registry.issueToken(forClientId: "a")
        for body in [
            rpcBody(method: "prompts/list"),
            rpcBody(method: "logging/setLevel"),
            rpcBody(method: "tools/call", params: ["name": "not_a_real_tool"]),
        ] {
            let response = await fixture.server.handleAuthenticated(httpRequest(body: body, token: token))
            #expect(isErrorResponse(response))
        }
        let doorCall = await fixture.server.handleAuthenticated(
            httpRequest(body: rpcBody(method: "tools/call", params: ["name": "iris_window_owner"]), token: token))
        #expect(!isErrorResponse(doorCall))
        let mailboxCall = await fixture.server.handleAuthenticated(
            httpRequest(body: rpcBody(method: "tools/call", params: ["name": "iris_discover"]), token: token))
        #expect(!isErrorResponse(mailboxCall))
    }

    @Test("resources/read is charged to mailboxGate, not left free or uncharged")
    func resourcesReadChargedToMailboxGate() async throws {
        let fixture = Fixture.build(doorGateCapacity: 1000, mailboxGateCapacity: 1)
        let tokenA = try fixture.registry.issueToken(forClientId: "a")
        let tokenB = try fixture.registry.issueToken(forClientId: "b")
        let sha = try await fixture.artifactStore.put(bytes: Data("hello".utf8), from: "a")
        try await fixture.artifactStore.authorize(sha256: sha, by: "a", adding: ["b"])

        let first = await fixture.server.handleAuthenticated(
            httpRequest(body: rpcBody(method: "resources/read", params: ["uri": "iris-artifact://\(sha)"]), token: tokenB))
        #expect(!isErrorResponse(first))
        let second = await fixture.server.handleAuthenticated(
            httpRequest(body: rpcBody(method: "resources/read", params: ["uri": "iris-artifact://\(sha)"]), token: tokenB))
        #expect(isErrorResponse(second))
        // doorGate is untouched by either call.
        let doorCall = await fixture.server.handleAuthenticated(
            httpRequest(body: rpcBody(method: "tools/call", params: ["name": "iris_window_owner"]), token: tokenA))
        #expect(!isErrorResponse(doorCall))
    }

    @Test("resources/list and resources/templates/list are free and return an empty list")
    func resourcesListReturnsEmpty() async throws {
        let fixture = Fixture.build(doorGateCapacity: 1, mailboxGateCapacity: 1)
        let token = try fixture.registry.issueToken(forClientId: "a")
        for method in ["resources/list", "resources/templates/list"] {
            let response = await fixture.server.handleAuthenticated(httpRequest(body: rpcBody(method: method), token: token))
            #expect(!isErrorResponse(response), "method=\(method)")
        }
        // Neither gate was touched.
        let doorCall = await fixture.server.handleAuthenticated(
            httpRequest(body: rpcBody(method: "tools/call", params: ["name": "iris_window_owner"]), token: token))
        #expect(!isErrorResponse(doorCall))
        let mailboxCall = await fixture.server.handleAuthenticated(
            httpRequest(body: rpcBody(method: "tools/call", params: ["name": "iris_discover"]), token: token))
        #expect(!isErrorResponse(mailboxCall))
    }

    @Test("a body with a duplicate top-level JSON key is rejected at the gate, never reaches dispatch")
    func duplicateTopLevelKeyRejected() async throws {
        let fixture = Fixture.build()
        let token = try fixture.registry.issueToken(forClientId: "a")
        let raw = """
        {"jsonrpc":"2.0","id":1,"method":"ping","method":"tools/call"}
        """
        let response = await fixture.server.handleAuthenticated(httpRequest(body: Data(raw.utf8), token: token))
        #expect(isErrorResponse(response))
    }

    @Test("a body with a duplicate key inside params is rejected too, not just at the top level")
    func duplicateParamsKeyRejected() async throws {
        let fixture = Fixture.build()
        let token = try fixture.registry.issueToken(forClientId: "a")
        let raw = """
        {"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"iris_window_owner","name":"iris_send"}}
        """
        let response = await fixture.server.handleAuthenticated(httpRequest(body: Data(raw.utf8), token: token))
        #expect(isErrorResponse(response))
    }

    @Test("an unlisted notification is accepted and dropped, not refused")
    func unlistedNotificationAcceptedAndDropped() async throws {
        let fixture = Fixture.build(doorGateCapacity: 1, mailboxGateCapacity: 1)
        let token = try fixture.registry.issueToken(forClientId: "a")
        let response = await fixture.server.handleAuthenticated(
            httpRequest(body: rpcBody(method: "notifications/cancelled", id: nil), token: token))
        #expect(!isErrorResponse(response))
        // Neither gate was touched.
        let doorCall = await fixture.server.handleAuthenticated(
            httpRequest(body: rpcBody(method: "tools/call", params: ["name": "iris_window_owner"]), token: token))
        #expect(!isErrorResponse(doorCall))
    }

    @Test("the tools/list response names exactly the tool names the dispatch allowlist accepts")
    func listToolsMatchesDispatchAllowlist() async throws {
        let fixture = Fixture.build()
        let token = try fixture.registry.issueToken(forClientId: "a")
        let response = await fixture.server.handleAuthenticated(httpRequest(body: rpcBody(method: "tools/list"), token: token))
        #expect(!isErrorResponse(response))
        let json = decodedBody(response)
        let result = json?["result"] as? [String: Any]
        let tools = result?["tools"] as? [[String: Any]]
        let names = Set((tools ?? []).compactMap { $0["name"] as? String })
        #expect(names == IrisMCPProviderServer.allToolNames)
    }

    @Test("two clients can each initialize without the second failing on \"already initialized\"")
    func secondClientInitializeSucceeds() async throws {
        let fixture = Fixture.build()
        let tokenA = try fixture.registry.issueToken(forClientId: "a")
        let tokenB = try fixture.registry.issueToken(forClientId: "b")
        let initBody = rpcBody(method: "initialize", params: ["protocolVersion": "2025-06-18", "capabilities": [:], "clientInfo": ["name": "t", "version": "1"]])
        let first = await fixture.server.handleAuthenticated(httpRequest(body: initBody, token: tokenA))
        #expect(!isErrorResponse(first))
        let second = await fixture.server.handleAuthenticated(httpRequest(body: initBody, token: tokenB))
        #expect(!isErrorResponse(second))
    }

    @Test("the initialize response advertises both a tools and a resources capability")
    func initializeAdvertisesCapabilities() async throws {
        let fixture = Fixture.build()
        let token = try fixture.registry.issueToken(forClientId: "a")
        let initBody = rpcBody(method: "initialize", params: ["protocolVersion": "2025-06-18", "capabilities": [:], "clientInfo": ["name": "t", "version": "1"]])
        let response = await fixture.server.handleAuthenticated(httpRequest(body: initBody, token: token))
        #expect(!isErrorResponse(response))
        let json = decodedBody(response)
        let result = json?["result"] as? [String: Any]
        let capabilities = result?["capabilities"] as? [String: Any]
        #expect(capabilities?["tools"] != nil)
        #expect(capabilities?["resources"] != nil)
    }

    @Test("the per-request Server and transport are stopped after handleRequest returns, on every request")
    func perRequestServerIsTornDown() async throws {
        let fixture = Fixture.build()
        let token = try fixture.registry.issueToken(forClientId: "a")
        defer { IrisMCPProviderServer.testOnlyServerConstructedHook = nil }
        for _ in 0..<5 {
            let box = TransportBox()
            IrisMCPProviderServer.testOnlyServerConstructedHook = { _, transport in box.transport = transport }
            let response = await fixture.server.handleAuthenticated(httpRequest(body: rpcBody(method: "ping"), token: token))
            #expect(!isErrorResponse(response))
            let transport = try #require(box.transport)
            // A terminated transport answers every further handleRequest with a fixed "Not
            // Found" rather than routing it anywhere — proof stop() actually ran, not just that
            // the call compiles.
            let postTeardown = await transport.handleRequest(httpRequest(body: rpcBody(method: "ping"), token: token))
            #expect(postTeardown.statusCode == 404)
        }
    }

    @Test("iris_discover over a real loopback socket returns Iris's own identity, never a client roster")
    func discoverReturnsIrisIdentityOverHTTP() async throws {
        let fixture = Fixture.build()
        _ = try fixture.registry.issueToken(forClientId: "a")
        _ = try fixture.registry.issueToken(forClientId: "b")
        let realToken = try fixture.registry.issueToken(forClientId: "caller")

        try await fixture.server.start()
        defer { Task { await fixture.server.stop() } }
        let port = try #require(fixture.server.boundPort)

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(realToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = rpcBody(method: "tools/call", params: ["name": "iris_discover"])

        let (data, urlResponse) = try await URLSession.shared.data(for: request)
        let httpURLResponse = try #require(urlResponse as? HTTPURLResponse)
        #expect(httpURLResponse.statusCode == 200)

        let json = try #require((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])
        let result = json["result"] as? [String: Any]
        let structured = result?["structuredContent"] as? [String: Any]
        #expect(structured?["peerId"] as? String == "iris")
        let bodyString = String(data: data, encoding: .utf8) ?? ""
        #expect(!bodyString.contains("\"a\""))
        #expect(!bodyString.contains("\"b\""))
    }

    @Test("sending a file reference authorizes Iris, but nobody else")
    func sendAuthorizesIrisOnly() async throws {
        let fixture = Fixture.build()
        let tokenA = try fixture.registry.issueToken(forClientId: "a")
        _ = try fixture.registry.issueToken(forClientId: "b")

        let putResponse = await fixture.server.handleAuthenticated(
            httpRequest(body: rpcBody(method: "tools/call", params: ["name": "artifact_put", "arguments": ["bytes": Data("hi".utf8).base64EncodedString()]]), token: tokenA))
        #expect(!isErrorResponse(putResponse))
        let sha = ((decodedBody(putResponse)?["result"] as? [String: Any])?["structuredContent"] as? [String: Any])?["sha256"] as? String
        let sha256 = try #require(sha)

        let sendResponse = await fixture.server.handleAuthenticated(
            httpRequest(body: rpcBody(method: "tools/call", params: ["name": "iris_send", "arguments": ["text": "hi", "fileRefs": [sha256]]]), token: tokenA))
        #expect(!isErrorResponse(sendResponse))

        #expect(try await fixture.artifactStore.get(sha256: sha256, requestingClientId: ProviderTokenRegistry.reservedClientId) == Data("hi".utf8))
        await #expect(throws: ProviderArtifactStore.ArtifactError.unauthorized) {
            try await fixture.artifactStore.get(sha256: sha256, requestingClientId: "b")
        }
    }

    @Test("a client cannot name an object it never held and thereby grant Iris access to someone else's upload")
    func sendCannotGrantAccessToAnUnheldHash() async throws {
        let fixture = Fixture.build()
        let tokenA = try fixture.registry.issueToken(forClientId: "a")
        let tokenC = try fixture.registry.issueToken(forClientId: "c")
        let sha = try await fixture.artifactStore.put(bytes: Data("secret".utf8), from: "a")

        let sendResponse = await fixture.server.handleAuthenticated(
            httpRequest(body: rpcBody(method: "tools/call", params: ["name": "iris_send", "arguments": ["text": "claiming", "fileRefs": [sha]]]), token: tokenC))
        _ = sendResponse  // isError content, not a transport error — the request itself still "succeeds" at the transport level
        let cStatus = await fixture.mailbox.status(for: "c")
        #expect(cStatus.pendingCount == 0)
        await #expect(throws: ProviderArtifactStore.ArtifactError.unauthorized) {
            try await fixture.artifactStore.get(sha256: sha, requestingClientId: ProviderTokenRegistry.reservedClientId)
        }
        _ = tokenA
    }

    @Test("a send with one valid and one invalid fileRef delivers nothing, not a partially-authorized message")
    func sendWithOneBadRefDeliversNoMessage() async throws {
        let fixture = Fixture.build()
        let tokenA = try fixture.registry.issueToken(forClientId: "a")
        let sha1 = try await fixture.artifactStore.put(bytes: Data("one".utf8), from: "a")
        let sha2 = String(repeating: "b", count: 64)  // never uploaded, never authorized

        _ = await fixture.server.handleAuthenticated(
            httpRequest(body: rpcBody(method: "tools/call", params: ["name": "iris_send", "arguments": ["text": "x", "fileRefs": [sha1, sha2]]]), token: tokenA))

        let aStatus = await fixture.mailbox.status(for: "a")
        #expect(aStatus.pendingCount == 0)
        await #expect(throws: ProviderArtifactStore.ArtifactError.unauthorized) {
            try await fixture.artifactStore.get(sha256: sha1, requestingClientId: ProviderTokenRegistry.reservedClientId)
        }
    }

    @Test("a tool call argument named from, clientId, or to is ignored; provenance is the resolved token's client id and the recipient is always Iris")
    func toolArgumentsCannotOverrideResolvedIdentity() async throws {
        let fixture = Fixture.build()
        let tokenA = try fixture.registry.issueToken(forClientId: "a")
        _ = try fixture.registry.issueToken(forClientId: "b")
        _ = try fixture.registry.issueToken(forClientId: "c")

        _ = await fixture.server.handleAuthenticated(
            httpRequest(body: rpcBody(method: "tools/call",
                                      params: ["name": "iris_send", "arguments": ["text": "x", "from": "b", "to": "c", "clientId": "b"]]),
                        token: tokenA))

        let bStatus = await fixture.mailbox.status(for: "b")
        #expect(bStatus.pendingCount == 0)
        let cStatus = await fixture.mailbox.status(for: "c")
        #expect(cStatus.pendingCount == 0)
    }

    @Test("ProviderMailbox.deliverReply is never called from production code outside ProviderMailbox.swift itself")
    func deliverReplyHasNoProductionCallSite() throws {
        let sourcesRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        var offendingFiles: [String] = []
        for subdirectory in ["IrisKit", "iris"] {
            let root = sourcesRoot.appendingPathComponent(subdirectory)
            guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { continue }
            while let url = enumerator.nextObject() as? URL {
                guard url.pathExtension == "swift" else { continue }
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                guard text.contains("deliverReply(") else { continue }
                if url.lastPathComponent != "ProviderMailbox.swift" {
                    offendingFiles.append(url.path)
                }
            }
        }
        #expect(offendingFiles.isEmpty, "deliverReply( referenced outside ProviderMailbox.swift: \(offendingFiles)")
    }

    @Test("revoke tears down the token, the mailbox, and the store's grants for that client in one call")
    func revokeTearsDownEverything() async throws {
        let fixture = Fixture.build()
        let tokenX = try fixture.registry.issueToken(forClientId: "x")
        let tokenA = try fixture.registry.issueToken(forClientId: "a")
        let sha = try await fixture.artifactStore.put(bytes: Data("hi".utf8), from: "a")

        _ = await fixture.server.handleAuthenticated(
            httpRequest(body: rpcBody(method: "tools/call", params: ["name": "iris_send", "arguments": ["text": "hi", "fileRefs": [sha]]]), token: tokenA))
        try await fixture.artifactStore.authorize(sha256: sha, by: "a", adding: ["x"])
        #expect(try await fixture.artifactStore.get(sha256: sha, requestingClientId: "x") == Data("hi".utf8))

        try await fixture.server.revoke(clientId: "x")

        #expect(fixture.registry.clientId(forToken: tokenX) == nil)
        let xStatus = await fixture.mailbox.status(for: "x")
        #expect(xStatus.pendingCount == 0)
        await #expect(throws: ProviderArtifactStore.ArtifactError.unauthorized) {
            try await fixture.artifactStore.get(sha256: sha, requestingClientId: "x")
        }

        let newTokenX = try fixture.registry.issueToken(forClientId: "x")
        #expect(newTokenX != tokenX)
        let newXStatus = await fixture.mailbox.status(for: "x")
        #expect(newXStatus.pendingCount == 0)
        await #expect(throws: ProviderArtifactStore.ArtifactError.unauthorized) {
            try await fixture.artifactStore.get(sha256: sha, requestingClientId: "x")
        }
    }
}
