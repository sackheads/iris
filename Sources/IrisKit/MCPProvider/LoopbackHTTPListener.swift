import Foundation
import Network
import MCP

/// A minimal, hand-rolled HTTP/1.1 listener bound to loopback only, bridging raw socket bytes to
/// an injected handler (the MCP SDK's `StatelessHTTPServerTransport.handleRequest`, in production
/// — never referenced directly here so this type's own tests never need a real `MCP.Server`).
/// No chunked transfer-encoding, no keep-alive: a single local client's request/response round
/// trip, nothing more (#1067). This parser itself is method-agnostic — it does not reject GET or
/// any other verb — because the MCP Streamable HTTP transport's own 405 (a non-POST reaching
/// `StatelessHTTPServerTransport.handleRequest`) is what actually enforces "POST only" in
/// production; that rejection belongs to the SDK, not to this listener's framing layer.
final class LoopbackHTTPListener: @unchecked Sendable {
    static let maxRequestLineBytes = 8 * 1024
    static let maxHeaderBytes = 32 * 1024
    static let maxHeaderCount = 64
    /// A ceiling above Task 7's own 8 MiB object cap, since this listener also carries JSON-RPC
    /// envelope overhead.
    static let maxContentLength = 16 * 1024 * 1024
    /// Bounds the body read once headers are complete.
    static let readTimeout: Duration = .seconds(30)
    /// A separate, shorter bound on how long a connection may sit before its headers finish.
    static let headerCompletionDeadline: Duration = .seconds(5)
    static let maxConcurrentConnections = 16
    /// Bounds the injected `handle` closure itself. Without this, a handler that never returns
    /// (a hung downstream call, a deadlock) holds its connection's slot forever: neither
    /// `headerCompletionDeadline` nor `readTimeout` apply once the request has already been
    /// delivered to `handle`, so `maxConcurrentConnections` hung handlers would wedge the whole
    /// listener shut with no later connection ever able to free one.
    static let handleTimeout: Duration = .seconds(10)

    /// Every tunable, instance-level so tests can shrink a real-time bound (`readTimeout`,
    /// `headerCompletionDeadline`) or a byte cap without waiting out the production value.
    /// Defaults to this type's own named constants — production code never passes this.
    struct Limits: Sendable {
        var maxRequestLineBytes = LoopbackHTTPListener.maxRequestLineBytes
        var maxHeaderBytes = LoopbackHTTPListener.maxHeaderBytes
        var maxHeaderCount = LoopbackHTTPListener.maxHeaderCount
        var maxContentLength = LoopbackHTTPListener.maxContentLength
        var readTimeout = LoopbackHTTPListener.readTimeout
        var headerCompletionDeadline = LoopbackHTTPListener.headerCompletionDeadline
        var maxConcurrentConnections = LoopbackHTTPListener.maxConcurrentConnections
        var handleTimeout = LoopbackHTTPListener.handleTimeout
    }

    private let requestedPort: UInt16
    private let handle: @Sendable (HTTPRequest) async -> HTTPResponse
    private let preBodyCheck: (@Sendable (HTTPRequest) -> HTTPResponse?)?
    private let limits: Limits
    private let isLoopbackCheck: @Sendable (NWEndpoint) -> Bool

    private let lock = NSLock()
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: Connection] = [:]
    private let queue = DispatchQueue(label: "iris.mcpprovider.loopback-listener")

    /// The port actually bound, once `start()` returns — resolves a `0` (ephemeral) request to
    /// the real assigned port.
    private(set) var boundPort: UInt16?

    /// - preBodyCheck: called once headers are parsed, with a headers-only `HTTPRequest` (`body:
    ///   nil`) — before this connection ever reads a byte of its body. A non-nil return is sent
    ///   as the response immediately, with the body never read. This is Task 8's seam for
    ///   auth: the token resolves off `Authorization`, which is a header, so an unauthorized
    ///   request's body (up to `maxContentLength`) is never buffered at all. **Defaults to `nil`
    ///   only so this type's own tests (and any caller with nothing to check pre-body) don't have
    ///   to supply one — Task 8's production wiring must always pass a real check.** It runs
    ///   synchronously while this connection's own lock is held (it is called from inside
    ///   `tryParseHeaders`'s caller), so it must stay a cheap, synchronous lookup (a dictionary
    ///   read, not network or disk I/O) — never an `async` call.
    init(port: UInt16, limits: Limits = Limits(),
         isLoopbackCheck: @escaping @Sendable (NWEndpoint) -> Bool = LoopbackHTTPListener.isLoopback,
         preBodyCheck: (@Sendable (HTTPRequest) -> HTTPResponse?)? = nil,
         handle: @escaping @Sendable (HTTPRequest) async -> HTTPResponse) {
        self.requestedPort = port
        self.limits = limits
        self.isLoopbackCheck = isLoopbackCheck
        self.preBodyCheck = preBodyCheck
        self.handle = handle
    }

    /// Binds loopback at construction time via `NWParameters.requiredLocalEndpoint`, not just by
    /// filtering connections after the fact — layer 1 of two independent layers of defence.
    static func loopbackParameters(port: UInt16) -> NWParameters {
        let params = NWParameters.tcp
        let nwPort = port == 0 ? NWEndpoint.Port.any : (NWEndpoint.Port(rawValue: port) ?? .any)
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: nwPort)
        return params
    }

    /// Layer 2, defence in depth on top of the bind-time restriction: a connection whose remote
    /// endpoint is not loopback is refused even if the bind is ever misconfigured or bypassed.
    static func isLoopback(_ endpoint: NWEndpoint) -> Bool {
        switch endpoint {
        case .hostPort(let host, _):
            switch host {
            case .ipv4(let address): return address.isLoopback
            case .ipv6(let address): return address.isLoopback
            case .name(let name, _): return name == "localhost"
            @unknown default: return false
            }
        default: return false
        }
    }

    func start() async throws {
        let params = Self.loopbackParameters(port: requestedPort)
        // The port lives in `requiredLocalEndpoint` and nowhere else. Passing it to
        // `NWListener(using:on:)` as well throws POSIX 22 (EINVAL) for any fixed port, and worked
        // only for port 0, which is all the tests used, so the configured default ports (8787 and
        // 8788) never bound at all (#1086).
        let listener = try NWListener(using: params)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let resumer = StartResumer(continuation)
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    self?.boundPort = listener.port?.rawValue
                    resumer.resume()
                case .failed(let error):
                    resumer.resume(throwing: error)
                case .cancelled:
                    // stop() raced start(): resume rather than hang forever on a continuation
                    // nothing will ever fulfill.
                    resumer.resume(throwing: CancellationError())
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        let active = lock.withLock { let c = connections.values; connections.removeAll(); return c }
        for connection in active { connection.cancel() }
    }

    /// A refused connection is started and immediately cancelled, not just cancelled outright:
    /// an `NWConnection` handed to `newConnectionHandler` already has a kernel socket from the
    /// accept, but `cancel()` on one that was never `start()`ed leaves that socket sitting open
    /// instead of tearing it down — the remote end would see "connected" forever.
    private func refuse(_ nwConnection: NWConnection) {
        nwConnection.start(queue: queue)
        nwConnection.cancel()
    }

    private func accept(_ nwConnection: NWConnection) {
        guard isLoopbackCheck(nwConnection.endpoint) else {
            refuse(nwConnection)
            return
        }
        let shouldAccept: Bool = lock.withLock {
            guard connections.count < limits.maxConcurrentConnections else { return false }
            return true
        }
        guard shouldAccept else {
            refuse(nwConnection)
            return
        }
        let connection = Connection(nwConnection: nwConnection, queue: queue, limits: limits,
                                    preBodyCheck: preBodyCheck, handle: handle) { [weak self] finished in
            self?.remove(finished)
        }
        lock.withLock { connections[ObjectIdentifier(connection)] = connection }
        connection.start()
    }

    private func remove(_ connection: Connection) {
        lock.withLock { _ = connections.removeValue(forKey: ObjectIdentifier(connection)) }
    }
}

/// One accepted connection's parse-and-respond state machine. A class (not a struct) so the
/// listener can hold and cancel it by identity.
private final class Connection: @unchecked Sendable {
    private let nwConnection: NWConnection
    private let queue: DispatchQueue
    private let limits: LoopbackHTTPListener.Limits
    private let preBodyCheck: (@Sendable (HTTPRequest) -> HTTPResponse?)?
    private let handle: @Sendable (HTTPRequest) async -> HTTPResponse
    private let onFinished: (Connection) -> Void

    private let lock = NSLock()
    private var buffer = Data()
    private var headersComplete = false
    private var finished = false
    private var method = ""
    private var path: String?
    private var headers: [String: String] = [:]
    private var bodyStart = 0
    private var expectedBodyLength: Int?

    init(nwConnection: NWConnection, queue: DispatchQueue, limits: LoopbackHTTPListener.Limits,
         preBodyCheck: (@Sendable (HTTPRequest) -> HTTPResponse?)?,
         handle: @escaping @Sendable (HTTPRequest) async -> HTTPResponse,
         onFinished: @escaping (Connection) -> Void) {
        self.nwConnection = nwConnection
        self.queue = queue
        self.limits = limits
        self.preBodyCheck = preBodyCheck
        self.handle = handle
        self.onFinished = onFinished
    }

    func start() {
        nwConnection.start(queue: queue)
        scheduleHeaderDeadline()
        scheduleReadTimeout()
        receiveMore()
    }

    func cancel() {
        finish()
    }

    private func scheduleHeaderDeadline() {
        queue.asyncAfter(deadline: .now() + limits.headerCompletionDeadline.timeInterval) { [weak self] in
            guard let self else { return }
            let stillWaiting = self.lock.withLock { !self.headersComplete && !self.finished }
            if stillWaiting { self.finish() }
        }
    }

    private func scheduleReadTimeout() {
        queue.asyncAfter(deadline: .now() + limits.readTimeout.timeInterval) { [weak self] in
            guard let self else { return }
            let stillOpen = self.lock.withLock { !self.finished }
            if stillOpen { self.finish() }
        }
    }

    private func receiveMore() {
        nwConnection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                let shouldContinue = self.append(data)
                if !shouldContinue { return }
            }
            if error != nil {
                self.finish()
                return
            }
            if isComplete {
                self.finish()
                return
            }
            let alreadyFinished = self.lock.withLock { self.finished }
            if !alreadyFinished { self.receiveMore() }
        }
    }

    /// Appends newly-received bytes and advances the parse. Returns `false` once the request has
    /// been delivered (or the connection failed), so the receive loop stops early.
    private func append(_ data: Data) -> Bool {
        let outcome: ParseOutcome = lock.withLock {
            guard !finished else { return .stop }
            buffer.append(data)
            if !headersComplete {
                guard let result = tryParseHeaders() else {
                    if buffer.count > limits.maxRequestLineBytes + limits.maxHeaderBytes {
                        finished = true
                        return .fail
                    }
                    return .continueReceiving
                }
                switch result {
                case .ok:
                    headersComplete = true
                    // Before this connection ever reads a byte of its body: a headers-only
                    // request, so an unauthorized sender's body is never buffered at all.
                    let headersOnlyRequest = HTTPRequest(method: method, headers: headers, body: nil, path: path)
                    if let preBodyCheck, let response = preBodyCheck(headersOnlyRequest) {
                        finished = true
                        return .respondWithoutBody(response)
                    }
                case .tooLarge, .malformed:
                    finished = true
                    return .fail
                }
            }
            guard headersComplete else { return .continueReceiving }
            guard let expected = expectedBodyLength else { return .deliver }
            return (buffer.count - bodyStart) >= expected ? .deliver : .continueReceiving
        }
        switch outcome {
        case .continueReceiving:
            return true
        case .fail:
            nwConnection.cancel()
            onFinished(self)
            return false
        case .respondWithoutBody(let response):
            send(response)
            return false
        case .deliver:
            deliver()
            return false
        case .stop:
            return false
        }
    }

    private enum ParseOutcome { case continueReceiving, fail, deliver, stop, respondWithoutBody(HTTPResponse) }
    private enum HeaderParseResult { case ok, tooLarge, malformed }

    /// Called with `lock` held. Looks for the blank-line terminator; if found, parses the request
    /// line and headers, enforcing every cap (dev-2 Gap 7). Returns `nil` if the terminator hasn't
    /// arrived yet.
    private func tryParseHeaders() -> HeaderParseResult? {
        let terminator = Data("\r\n\r\n".utf8)
        guard let range = buffer.range(of: terminator) else { return nil }
        let headerBlock = buffer.subdata(in: 0..<range.lowerBound)
        guard headerBlock.count <= limits.maxRequestLineBytes + limits.maxHeaderBytes else {
            return .tooLarge
        }
        guard let text = String(data: headerBlock, encoding: .utf8) else { return .malformed }
        var lines = text.split(separator: "\r\n", omittingEmptySubsequences: false).map(String.init)
        guard !lines.isEmpty else { return .malformed }
        let requestLine = lines.removeFirst()
        guard requestLine.utf8.count <= limits.maxRequestLineBytes else { return .tooLarge }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return .malformed }
        method = String(parts[0])
        path = String(parts[1])

        guard lines.count <= limits.maxHeaderCount else { return .tooLarge }
        var headerBytes = 0
        var parsedHeaders: [String: (name: String, value: String)] = [:]
        for line in lines where !line.isEmpty {
            headerBytes += line.utf8.count
            guard headerBytes <= limits.maxHeaderBytes else { return .tooLarge }
            guard let colon = line.firstIndex(of: ":") else { return .malformed }
            let rawName = String(line[line.startIndex..<colon])
            // RFC 7230 §3.2.4: no whitespace is allowed between the field name and the colon.
            // Two parsers disagreeing on whether "Name : value" names "Name" or "Name " is
            // exactly the ambiguity request smuggling needs; reject rather than tolerate it.
            guard rawName == rawName.trimmingCharacters(in: .whitespaces) else { return .malformed }
            let name = rawName
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            let key = name.lowercased()
            // A duplicate header resolving order-dependently (whichever line wins the dictionary
            // write) is exactly the ambiguity request smuggling exploits; refuse outright rather
            // than pick a winner, except when every occurrence agrees.
            if let existing = parsedHeaders[key], existing.value != value { return .malformed }
            parsedHeaders[key] = (name: name, value: value)
        }
        // No chunked transfer-encoding (this parser's own stated scope) — refusing the header
        // entirely closes the Transfer-Encoding/Content-Length smuggling pair, since a request
        // naming it can never reach the Content-Length branch below believing it will be chunked.
        guard parsedHeaders["transfer-encoding"] == nil else { return .malformed }
        headers = Dictionary(uniqueKeysWithValues: parsedHeaders.values.map { ($0.name, $0.value) })
        bodyStart = range.upperBound

        if let contentLengthHeader = parsedHeaders["content-length"]?.value {
            // RFC 7230 §3.3.2: the field value is 1*DIGIT — no sign, no leading/trailing noise.
            // Int("+5") parses to 5 in Swift, which would silently accept what the spec forbids.
            guard !contentLengthHeader.isEmpty, contentLengthHeader.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let length = Int(contentLengthHeader) else { return .malformed }
            guard length <= limits.maxContentLength else { return .tooLarge }
            expectedBodyLength = length
        } else if method.uppercased() == "POST" {
            // A POST with no Content-Length is refused rather than read unbounded (dev-2 Gap 7).
            return .malformed
        } else {
            expectedBodyLength = nil
        }
        return .ok
    }

    private func deliver() {
        let (request, snapshotFinished): (HTTPRequest, Bool) = lock.withLock {
            let bodyLength = expectedBodyLength ?? 0
            let body = bodyLength > 0 ? buffer.subdata(in: bodyStart..<(bodyStart + bodyLength)) : nil
            let request = HTTPRequest(method: method, headers: headers, body: body, path: path)
            let wasFinished = finished
            finished = true
            return (request, wasFinished)
        }
        guard !snapshotFinished else { return }
        Task {
            let response: HTTPResponse
            do {
                response = try await withTimeout(seconds: self.limits.handleTimeout.timeInterval) {
                    await self.handle(request)
                }
            } catch {
                // The handler never returned within handleTimeout: answer with an error and free
                // this connection's slot rather than holding it open forever.
                response = .error(statusCode: 504, .internalError("handler timed out"))
            }
            self.send(response)
        }
    }

    private func send(_ response: HTTPResponse) {
        var text = "HTTP/1.1 \(response.statusCode) \(Self.reasonPhrase(for: response.statusCode))\r\n"
        let body = response.bodyData ?? Data()
        var headers = response.headers
        headers["Content-Length"] = String(body.count)
        // This listener never keeps a connection open past one response (Global Constraint: no
        // keep-alive) — say so, rather than let a keep-alive-capable client assume it can reuse
        // this connection for a second request that will never be answered.
        headers["Connection"] = "close"
        for (name, value) in headers {
            text += "\(name): \(value)\r\n"
        }
        text += "\r\n"
        var payload = Data(text.utf8)
        payload.append(body)
        nwConnection.send(content: payload, completion: .contentProcessed { [weak self] _ in
            self?.nwConnection.cancel()
            if let self { self.onFinished(self) }
        })
    }

    private static func reasonPhrase(for statusCode: Int) -> String {
        switch statusCode {
        case 200: return "OK"
        case 202: return "Accepted"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        default: return "Error"
        }
    }

    private func finish() {
        let wasFinished = lock.withLock {
            let already = finished
            finished = true
            return already
        }
        guard !wasFinished else { return }
        nwConnection.cancel()
        onFinished(self)
    }
}

extension Duration {
    var timeInterval: TimeInterval {
        let (seconds, attoseconds) = components
        return Double(seconds) + Double(attoseconds) / 1e18
    }
}

/// `NWListener.stateUpdateHandler` can fire `.ready` and then later `.failed`/`.cancelled` on the
/// very same continuation (a listener cancelled right after becoming ready, or `stop()` racing
/// `start()`); resuming a `CheckedContinuation` twice is a fatal error, and never resuming it at
/// all (no case for `.cancelled`) hangs `start()` forever. This fires at most once, whichever
/// state wins the race.
private final class StartResumer: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?

    init(_ continuation: CheckedContinuation<Void, Error>) { self.continuation = continuation }

    func resume() {
        lock.lock(); let c = continuation; continuation = nil; lock.unlock()
        c?.resume()
    }

    func resume(throwing error: Error) {
        lock.lock(); let c = continuation; continuation = nil; lock.unlock()
        c?.resume(throwing: error)
    }
}
