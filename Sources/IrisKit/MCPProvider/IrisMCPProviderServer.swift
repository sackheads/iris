import Foundation
import MCP

/// Wires Tasks 1-7 into one loopback MCP provider (#1067). Builds a **per-request** `MCP.Server`
/// + `StatelessHTTPServerTransport` pair inside the listener's `handle` closure, after that
/// request's bearer token has already been resolved to a client id — never one long-lived
/// `Server` (the pinned SDK revision's `Server` throws "already initialized" on a second
/// `initialize`, and two requests sharing one `StatelessHTTPServerTransport` can cross-deliver
/// their responses by colliding JSON-RPC ids). Auth is checked on the raw `HTTPRequest`, before
/// any SDK type exists, so `initialize`/`tools/list`/`ping` get no free pass.
final class IrisMCPProviderServer: Sendable {
    static let serverCapabilities = Server.Capabilities(
        resources: .init(subscribe: false, listChanged: false),
        tools: .init(listChanged: false)
    )

    private static let doorToolNamesByQuery: [SelfReportDoor.Query: String] = [
        .windowOwner: "iris_window_owner",
        .responderClass: "iris_responder_class",
        .composerState: "iris_composer_state",
        .turnState: "iris_turn_state",
        .activationState: "iris_activation_state",
        .eventRing: "iris_event_ring",
    ]
    static let doorToolNames: Set<String> = Set(doorToolNamesByQuery.values)
    static let mailboxToolNames: Set<String> = ["iris_send", "iris_poll", "iris_discover", "iris_status", "artifact_put"]
    static let allToolNames: Set<String> = doorToolNames.union(mailboxToolNames)

    private let tokenRegistry: ProviderTokenRegistry
    private let mailbox: ProviderMailbox
    private let artifactStore: ProviderArtifactStore
    private let door: SelfReportDoor
    private let doorGate: ProviderRequestGate
    private let mailboxGate: ProviderRequestGate
    private let port: UInt16
    private let requestDeadline: Duration
    /// Test-only seam: called with each per-request `Server` and `StatelessHTTPServerTransport`
    /// right after construction, before `start()`/`stop()`. An instance property, not a mutable
    /// static — a static hook is one process-global shared across every `IrisMCPProviderServer`
    /// instance in the test binary, and the parallel test runner mutating it from multiple tests
    /// at once raced (AGENTS.md Invariant 7). `nil` in production; zero cost there.
    private let serverConstructedHook: (@Sendable (Server, StatelessHTTPServerTransport) -> Void)?

    private final class ListenerBox: @unchecked Sendable {
        private let lock = NSLock()
        private var listener: LoopbackHTTPListener?
        var value: LoopbackHTTPListener? {
            get { lock.withLock { listener } }
            set { lock.withLock { listener = newValue } }
        }
    }
    private let listenerBox = ListenerBox()

    init(tokenRegistry: ProviderTokenRegistry, mailbox: ProviderMailbox, artifactStore: ProviderArtifactStore,
         door: SelfReportDoor, doorGate: ProviderRequestGate, mailboxGate: ProviderRequestGate,
         port: UInt16, requestDeadline: Duration = .seconds(10),
         serverConstructedHook: (@Sendable (Server, StatelessHTTPServerTransport) -> Void)? = nil) {
        self.tokenRegistry = tokenRegistry
        self.mailbox = mailbox
        self.artifactStore = artifactStore
        self.door = door
        self.doorGate = doorGate
        self.mailboxGate = mailboxGate
        self.port = port
        self.requestDeadline = requestDeadline
        self.serverConstructedHook = serverConstructedHook
    }

    func start() async throws {
        let listener = LoopbackHTTPListener(
            port: port,
            // `handleTimeout` must sit strictly above `requestDeadline`: `handleAuthenticated`
            // has its own 504-and-teardown deadline, and if the listener's own timeout could
            // fire at the same instant, whichever one wins is undefined and the loser's response
            // or teardown may never run. A fixed one-second margin, not a race between two
            // independently-defaulted ten-second constants (the two previously landed on the
            // same value by coincidence).
            limits: .init(handleTimeout: requestDeadline + .seconds(1)),
            preBodyCheck: { [weak self] request in self?.preBodyAuthCheck(request) },
            handle: { [weak self] request in
                guard let self else { return .error(statusCode: 500, .internalError("server stopped")) }
                return await self.handleAuthenticated(request)
            }
        )
        try await listener.start()
        listenerBox.value = listener
    }

    func stop() async {
        listenerBox.value?.stop()
        listenerBox.value = nil
    }

    /// `nil` until `start()`'s listener has bound a real port. Test-only consumer: the one
    /// real-socket end-to-end test needs it to address the loopback listener it just started.
    var boundPort: UInt16? { listenerBox.value?.boundPort }

    /// The one entry point that tears a client down completely. Whatever drives revocation (a
    /// future admin tool, a manual script — out of scope for Phase 1's own UI, per Task 1's
    /// onboarding note) must call this, never `tokenRegistry.revokeToken` directly.
    func revoke(clientId: String) async throws {
        // Every purge runs regardless of whether revokeToken itself throws (e.g. an already
        // unknown client id): a failed token revoke must not leave that id's mailbox messages,
        // artifact grants, or gate budget state behind for a later re-issue of the same id to
        // inherit. The token error, if any, is what the caller sees.
        //
        // Registry-first is still deliberate, not just the natural order: a request already
        // admitted before this call holds a resolved `clientId` in its own closure for up to
        // `requestDeadline`, and could still write a message or a grant under it after the
        // purges below have run but before `revokeToken` actually lands — nothing here closes
        // that window (dev-2 review, #1079), and it is not pinned by a deterministic test. The
        // mailbox/store's own re-check of `isRegistered` at the point of mutation (Task 6/7) is
        // what actually closes it, by rejecting the write once the registry update lands.
        let tokenError = Result { try tokenRegistry.revokeToken(forClientId: clientId) }
        await mailbox.purge(clientId: clientId)
        await artifactStore.purge(clientId: clientId)
        await doorGate.purge(clientId: clientId)
        await mailboxGate.purge(clientId: clientId)
        try tokenError.get()
    }

    /// Schedules the two store sweeps. Called from the app's own maintenance hook (the same place
    /// `AppState.sweepArtifacts` runs), not from a timer this type owns.
    func sweepExpired() async {
        await mailbox.sweepExpired()
        await artifactStore.sweepExpired()
    }

    private func resolveClientId(_ request: HTTPRequest) -> String? {
        guard let bearerToken = Self.bearerToken(from: request) else { return nil }
        return tokenRegistry.clientId(forToken: bearerToken)
    }

    private static func bearerToken(from request: HTTPRequest) -> String? {
        guard let authHeader = request.header("Authorization"), authHeader.hasPrefix("Bearer ") else { return nil }
        return String(authHeader.dropFirst("Bearer ".count))
    }

    /// Task 2's seam: answers from headers alone, before this connection ever reads its body — an
    /// unauthenticated connection never gets to spend CPU parsing a large JSON-RPC body.
    private func preBodyAuthCheck(_ request: HTTPRequest) -> HTTPResponse? {
        resolveClientId(request) == nil ? Self.unauthorizedResponse() : nil
    }

    private static func unauthorizedResponse() -> HTTPResponse {
        .error(statusCode: 401, .invalidRequest("unauthorized"))
    }

    private static func badRequestResponse(_ message: String) -> HTTPResponse {
        .error(statusCode: 400, .invalidRequest(message))
    }

    private static func methodNotFoundResponse(_ method: String) -> HTTPResponse {
        .error(statusCode: 400, .methodNotFound(method))
    }

    private static func admissionErrorResponse(_ admission: ProviderRequestGate.Admission) -> HTTPResponse {
        switch admission {
        case .unauthorized: return unauthorizedResponse()
        case .budgetExceeded: return .error(statusCode: 429, .serverError(code: -32000, message: "rate limit exceeded"))
        case .admitted: preconditionFailure("admissionErrorResponse called with .admitted")
        }
    }

    /// The listener's `handle` closure. Resolves and admits a request before any `MCP.Server`
    /// exists, dispatches against a default-deny allowlist, and only then builds the per-request
    /// `Server`+`transport` pair that actually answers it.
    func handleAuthenticated(_ request: HTTPRequest) async -> HTTPResponse {
        // 1. Resolve, don't admit, first — and never touch the body until this succeeds.
        guard let bearerToken = Self.bearerToken(from: request) else { return Self.unauthorizedResponse() }
        guard let clientId = tokenRegistry.clientId(forToken: bearerToken) else { return Self.unauthorizedResponse() }

        guard let body = request.body, !body.isEmpty else { return Self.badRequestResponse("missing body") }

        // 2. Reject a JSON-RPC batch (top-level array) outright — this parser has no batch support.
        guard let topLevel = try? JSONSerialization.jsonObject(with: body) else {
            return Self.badRequestResponse("invalid JSON")
        }
        guard let json = topLevel as? [String: Any] else {
            return Self.badRequestResponse("batch requests are not supported")
        }

        // Reject any duplicate key anywhere in the document — top level or nested under params —
        // before trusting any value `JSONSerialization` already silently picked for it.
        do {
            try StrictJSON.rejectDuplicateKeys(body)
        } catch {
            return Self.badRequestResponse("duplicate JSON key")
        }

        guard let method = json["method"] as? String else {
            return Self.badRequestResponse("missing method")
        }
        let isNotification = json["id"] == nil

        // 3. Dispatch by method against an explicit, default-deny allowlist.
        switch method {
        case "initialize", "notifications/initialized", "tools/list", "ping",
             "resources/list", "resources/templates/list":
            break  // free: resolved clientId required, no gate charge
        case "tools/call":
            guard let params = json["params"] as? [String: Any], let toolName = params["name"] as? String else {
                return Self.badRequestResponse("missing tool name")
            }
            let admission: ProviderRequestGate.Admission
            if Self.doorToolNames.contains(toolName) {
                admission = await doorGate.admit(bearerToken: bearerToken)
            } else if Self.mailboxToolNames.contains(toolName) {
                admission = await mailboxGate.admit(bearerToken: bearerToken)
            } else {
                return Self.methodNotFoundResponse("tools/call: \(toolName)")
            }
            guard case .admitted = admission else { return Self.admissionErrorResponse(admission) }
        case "resources/read":
            let admission = await mailboxGate.admit(bearerToken: bearerToken)
            guard case .admitted = admission else { return Self.admissionErrorResponse(admission) }
        default:
            // Any other notification (no id) is accepted and dropped, not refused; anything else
            // unlisted is a 400 with no gate call at all.
            if isNotification { return .accepted() }
            return Self.methodNotFoundResponse(method)
        }

        // 4-6. Build the per-request Server+transport, dispatch, and always tear it down.
        do {
            return try await withTimeout(seconds: Self.seconds(requestDeadline)) {
                await self.dispatch(clientId: clientId, request: request)
            }
        } catch {
            return .error(statusCode: 504, .internalError("request deadline exceeded"))
        }
    }

    /// Passes the caller's own `request` through to `transport.handleRequest`, unaltered —
    /// never a stand-in with fixed headers, or the SDK's own `StatelessHTTPServerTransport`
    /// validation pipeline (origin/host, `Accept`, `Content-Type`, method) never actually runs
    /// against real traffic.
    private func dispatch(clientId: String, request: HTTPRequest) async -> HTTPResponse {
        let server = Server(name: "iris", version: Constants.appVersion, capabilities: Self.serverCapabilities)
        await Self.registerHandlers(on: server, clientId: clientId, door: door, mailbox: mailbox, artifactStore: artifactStore)

        let transport = StatelessHTTPServerTransport()
        serverConstructedHook?(server, transport)

        return await withTaskCancellationHandler {
            do {
                try await server.start(transport: transport)
            } catch {
                await server.stop()
                return .error(statusCode: 500, .internalError("server start failed"))
            }
            let response = await transport.handleRequest(request)
            await server.stop()
            return response
        } onCancel: {
            // `withTimeout`'s deadline cancels this task but does not interrupt a plain `await`
            // mid-flight (Timeout.swift's own doc comment) — without this, a timed-out request's
            // Server/transport are torn down only once the abandoned operation eventually reaches
            // its own `server.stop()`, whenever that is. This tears them down at once instead;
            // `server.stop()` from the operation body afterward is a harmless second call.
            //
            // This frees the Server/transport promptly; it does not stop the request's own work.
            // `withTimeout` abandons the operation task rather than cancelling the SDK's own
            // internal handler task (the method handlers in `registerHandlers` run inside the
            // SDK's receive loop, which this cancellation handler has no reach into), so a 504
            // does not mean a tool call's side effect (a `mailbox.send`, an `artifactStore.put`)
            // did not happen — only that the caller stopped waiting for its result. In practice
            // every handler here is a fast actor call except `door.handle`, which races its own
            // 500ms deadline well under any reasonable `requestDeadline`, so this is a real
            // caveat, not a reachable one with the handlers this server actually registers today.
            Task { await server.stop() }
        }
    }

    private static func registerHandlers(on server: Server, clientId: String, door: SelfReportDoor,
                                         mailbox: ProviderMailbox, artifactStore: ProviderArtifactStore) async {
        await server.withMethodHandler(ListTools.self) { _ in
            ListTools.Result(tools: Self.allTools)
        }
        await server.withMethodHandler(ListResources.self) { _ in
            ListResources.Result(resources: [])
        }
        await server.withMethodHandler(ListResourceTemplates.self) { _ in
            ListResourceTemplates.Result(templates: [])
        }
        await server.withMethodHandler(ReadResource.self) { params in
            try await Self.handleReadResource(params, clientId: clientId, artifactStore: artifactStore)
        }
        await server.withMethodHandler(CallTool.self) { params in
            try await Self.handleCallTool(params, clientId: clientId, door: door, mailbox: mailbox, artifactStore: artifactStore)
        }
    }

    // MARK: - resources/read

    private static func handleReadResource(_ params: ReadResource.Parameters, clientId: String,
                                           artifactStore: ProviderArtifactStore) async throws -> ReadResource.Result {
        guard let sha256 = Self.sha256(fromArtifactURI: params.uri) else {
            throw MCPError.invalidParams("malformed iris-artifact:// URI")
        }
        let data: Data
        do {
            data = try await artifactStore.get(sha256: sha256, requestingClientId: clientId)
        } catch {
            throw MCPError.invalidRequest("not found or unauthorized")
        }
        return ReadResource.Result(contents: [.binary(data, uri: params.uri)])
    }

    private static let artifactURIScheme = "iris-artifact://"

    private static func sha256(fromArtifactURI uri: String) -> String? {
        guard uri.hasPrefix(artifactURIScheme) else { return nil }
        let candidate = String(uri.dropFirst(artifactURIScheme.count))
        return ProviderArtifactStore.isValidHash(candidate) ? candidate : nil
    }

    // MARK: - tools/call

    private static func handleCallTool(_ params: CallTool.Parameters, clientId: String, door: SelfReportDoor,
                                       mailbox: ProviderMailbox, artifactStore: ProviderArtifactStore) async throws -> CallTool.Result {
        if let query = doorToolNamesByQuery.first(where: { $0.value == params.name })?.key {
            return try await handleDoorCall(query: query, clientId: clientId, door: door)
        }
        switch params.name {
        case "iris_send":
            return try await handleSend(params, clientId: clientId, mailbox: mailbox, artifactStore: artifactStore)
        case "iris_poll":
            let since = params.arguments?["sinceSequence"]?.uint64Value
            let messages = await mailbox.poll(for: clientId, sinceSequence: since)
            return try CallTool.Result(structuredContent: messages)
        case "iris_discover":
            let identity = await mailbox.discover()
            return try CallTool.Result(structuredContent: identity)
        case "iris_status":
            let status = await mailbox.status(for: clientId)
            return try CallTool.Result(structuredContent: MailboxStatusDTO(pendingCount: status.pendingCount, lastMessageAt: status.lastMessageAt))
        case "artifact_put":
            return try await handleArtifactPut(params, clientId: clientId, artifactStore: artifactStore)
        default:
            throw MCPError.methodNotFound("unknown tool: \(params.name)")
        }
    }

    private static func handleDoorCall(query: SelfReportDoor.Query, clientId: String, door: SelfReportDoor) async throws -> CallTool.Result {
        switch await door.handle(query: query, clientId: clientId) {
        case .success(let snapshot):
            // Snapshot is Encodable only (by design — a wire-only outbound type, never decoded),
            // so the Codable-constrained CallTool.Result(structuredContent:) initializer doesn't
            // accept it; bridge through JSONEncoder/Decoder into a Value instead.
            return try CallTool.Result(content: [], structuredContent: Self.encodeAsValue(snapshot))
        case .failure(let error):
            return CallTool.Result(content: [.text(text: String(describing: error), annotations: nil, _meta: nil)], isError: true)
        }
    }

    private static func encodeAsValue(_ encodable: Encodable) throws -> Value {
        let data = try JSONEncoder().encode(encodable)
        return try JSONDecoder().decode(Value.self, from: data)
    }

    /// Not a bare `mailbox.send` + a loop of `authorize` calls: every `fileRefs` entry is
    /// preflighted (already-held by `clientId`) before `send` is ever called, so there is no
    /// partial message and no partial grant. If the atomic grant afterward fails anyway — a
    /// narrow window between preflight and grant where `sweepExpired`/`purge` could invalidate a
    /// ref that preflighted clean — the message is retracted rather than left half-delivered.
    private static func handleSend(_ params: CallTool.Parameters, clientId: String,
                                   mailbox: ProviderMailbox, artifactStore: ProviderArtifactStore) async throws -> CallTool.Result {
        // Reject a malformed shape outright rather than silently defaulting it into something
        // sendable: a missing/non-string `text` is not the same request as an explicit empty
        // string, and a non-array or mixed-type `fileRefs` is not the same as "no attachments" —
        // either would otherwise send a message the caller did not actually ask to send, with no
        // error telling them their attachment list was dropped.
        guard let text = params.arguments?["text"]?.stringValue else {
            return CallTool.Result(content: [.text(text: "text must be a string", annotations: nil, _meta: nil)], isError: true)
        }
        let fileRefs: [String]
        if let fileRefsValue = params.arguments?["fileRefs"] {
            guard let array = fileRefsValue.arrayValue, let strings = array.stringsIfAllStrings() else {
                return CallTool.Result(content: [.text(text: "fileRefs must be an array of strings", annotations: nil, _meta: nil)], isError: true)
            }
            fileRefs = strings
        } else {
            fileRefs = []
        }

        // Cheap, no I/O: reject an oversized list before spending one actor hop per entry on the
        // preflight below.
        guard fileRefs.count <= ProviderMailbox.maxFileRefsPerMessage else {
            return CallTool.Result(content: [.text(text: "too many fileRefs", annotations: nil, _meta: nil)], isError: true)
        }

        for ref in fileRefs {
            do {
                // adding: [] is a pure permission check: it throws unless clientId already holds
                // a read on ref, and mutates nothing (formUnion with an empty set is a no-op).
                try await artifactStore.authorize(sha256: ref, by: clientId, adding: [])
            } catch {
                return CallTool.Result(content: [.text(text: "not authorized to send file reference: \(ref)", annotations: nil, _meta: nil)], isError: true)
            }
        }

        let message: ProviderMailbox.Message
        do {
            message = try await mailbox.send(from: clientId, text: text, fileRefs: fileRefs)
        } catch {
            return CallTool.Result(content: [.text(text: String(describing: error), annotations: nil, _meta: nil)], isError: true)
        }

        if !fileRefs.isEmpty {
            do {
                try await artifactStore.authorizeAll(sha256s: fileRefs, by: clientId, adding: ProviderTokenRegistry.reservedClientId)
            } catch {
                await mailbox.retract(id: message.id)
                return CallTool.Result(content: [.text(text: "file reference grant failed; message not sent", annotations: nil, _meta: nil)], isError: true)
            }
        }
        return try CallTool.Result(structuredContent: message)
    }

    private static func handleArtifactPut(_ params: CallTool.Parameters, clientId: String,
                                          artifactStore: ProviderArtifactStore) async throws -> CallTool.Result {
        guard let base64 = params.arguments?["bytes"]?.stringValue, let bytes = Data(base64Encoded: base64) else {
            return CallTool.Result(content: [.text(text: "missing or malformed bytes", annotations: nil, _meta: nil)], isError: true)
        }
        do {
            let sha256 = try await artifactStore.put(bytes: bytes, from: clientId)
            return try CallTool.Result(structuredContent: ArtifactPutResultDTO(sha256: sha256))
        } catch {
            return CallTool.Result(content: [.text(text: String(describing: error), annotations: nil, _meta: nil)], isError: true)
        }
    }

    private struct MailboxStatusDTO: Codable {
        let pendingCount: Int
        let lastMessageAt: Date?
    }

    private struct ArtifactPutResultDTO: Codable {
        let sha256: String
    }

    // MARK: - tool declarations

    private static let emptySchema: Value = .object(["type": "object", "properties": .object([:])])

    static let allTools: [MCP.Tool] = {
        var tools: [MCP.Tool] = doorToolNamesByQuery.values.map { name in
            MCP.Tool(name: name, description: "Read-only diagnostic: \(name)", inputSchema: emptySchema)
        }
        tools.append(MCP.Tool(
            name: "iris_send",
            description: "Send a message to Iris. There is no recipient argument — every message addresses Iris.",
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "text": .object(["type": "string"]),
                    "fileRefs": .object(["type": "array", "items": .object(["type": "string"])]),
                ]),
                "required": .array(["text"]),
            ])
        ))
        tools.append(MCP.Tool(
            name: "iris_poll",
            description: "Poll for Iris's replies to this client.",
            inputSchema: .object([
                "type": "object",
                "properties": .object(["sinceSequence": .object(["type": "integer"])]),
            ])
        ))
        tools.append(MCP.Tool(name: "iris_discover", description: "Discover Iris's own peer identity.", inputSchema: emptySchema))
        tools.append(MCP.Tool(name: "iris_status", description: "This client's pending-reply status with Iris.", inputSchema: emptySchema))
        tools.append(MCP.Tool(
            name: "artifact_put",
            description: "Upload a file (inline base64 bytes) for later reference in a send.",
            inputSchema: .object([
                "type": "object",
                "properties": .object(["bytes": .object(["type": "string", "description": "base64-encoded bytes"])]),
                "required": .array(["bytes"]),
            ])
        ))
        return tools
    }()

    private static func seconds(_ duration: Duration) -> Double {
        let (seconds, attoseconds) = duration.components
        return Double(seconds) + Double(attoseconds) / 1e18
    }
}

private extension Value {
    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }
    var arrayValue: [Value]? {
        if case .array(let a) = self { return a }
        return nil
    }
    var uint64Value: UInt64? {
        if case .int(let i) = self, i >= 0 { return UInt64(i) }
        return nil
    }
}

private extension [Value] {
    /// `nil` if any element is not a `.string` — used where a mixed-type array must be refused
    /// outright rather than have `compactMap(\.stringValue)` silently drop the non-string entries.
    func stringsIfAllStrings() -> [String]? {
        var result: [String] = []
        result.reserveCapacity(count)
        for value in self {
            guard let string = value.stringValue else { return nil }
            result.append(string)
        }
        return result
    }
}
