import Testing
import Foundation
import Network
@testable import IrisKit
import MCP

@Suite("LoopbackHTTPListener", .timeLimit(.minutes(1)))
struct LoopbackHTTPListenerTests {
    @Test("a POST to the listener's port reaches the injected handler and returns its response")
    func postRoundTrips() async throws {
        let listener = LoopbackHTTPListener(port: 0) { request in
            #expect(request.method == "POST")
            #expect(request.body == Data("{}".utf8))
            return .data(Data("{\"ok\":true}".utf8), headers: ["Content-Type": "application/json"])
        }
        try await listener.start()
        defer { listener.stop() }
        guard let port = listener.boundPort else { Issue.record("listener never reported a bound port"); return }

        let url = URL(string: "http://127.0.0.1:\(port)/")!
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.httpBody = Data("{}".utf8)
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        let http = response as? HTTPURLResponse
        #expect(http?.statusCode == 200)
        #expect(String(data: data, encoding: .utf8) == "{\"ok\":true}")
    }

    @Test("preBodyCheck answers from headers alone, never reading the body, and the main handler never runs")
    func preBodyCheckShortCircuitsBeforeTheBodyIsRead() async throws {
        let mainHandlerCalled = CallFlag()
        let listener = LoopbackHTTPListener(
            port: 0,
            preBodyCheck: { request in
                #expect(request.body == nil, "preBodyCheck must see a headers-only request")
                #expect(request.header("Authorization") == "Bearer nope")
                return .error(statusCode: 401, .invalidRequest("unauthorized"))
            },
            handle: { _ in
                mainHandlerCalled.set()
                return .ok()
            }
        )
        try await listener.start()
        defer { listener.stop() }
        guard let port = listener.boundPort else { Issue.record("no bound port"); return }

        // A huge Content-Length with NO body ever sent: if preBodyCheck ran only after the body
        // was buffered (dev-3's mutation), this would hang waiting for bytes that never arrive.
        // Answering within 2s proves it ran before any body read was even attempted.
        let connection = try await rawConnect(port: port)
        try await connection.send("POST / HTTP/1.1\r\nAuthorization: Bearer nope\r\nContent-Length: 1000000\r\n\r\n")
        let response = await connection.readSome(timeout: 2)
        #expect(response?.contains("401") == true)
        #expect(!mainHandlerCalled.value)
        connection.cancel()
    }

    @Test("with no preBodyCheck, every request reaches the main handler as before")
    func noPreBodyCheckMeansHandlerAlwaysRuns() async throws {
        let listener = LoopbackHTTPListener(port: 0) { _ in .ok() }
        try await listener.start()
        defer { listener.stop() }
        guard let port = listener.boundPort else { Issue.record("no bound port"); return }

        var urlRequest = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/")!)
        urlRequest.httpMethod = "POST"
        urlRequest.httpBody = Data()
        urlRequest.setValue("0", forHTTPHeaderField: "Content-Length")
        let (_, response) = try await URLSession.shared.data(for: urlRequest)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
    }

    @Test("a handler that never returns is bounded by handleTimeout, and the response frees the slot", .timeLimit(.minutes(1)))
    func handleTimeoutBoundsAHungHandler() async throws {
        var limits = LoopbackHTTPListener.Limits()
        limits.handleTimeout = .milliseconds(300)
        let listener = LoopbackHTTPListener(port: 0, limits: limits) { _ in
            try? await Task.sleep(for: .seconds(3600))  // never returns within the test's lifetime
            return .ok()
        }
        try await listener.start()
        defer { listener.stop() }
        guard let port = listener.boundPort else { Issue.record("no bound port"); return }

        var urlRequest = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/")!)
        urlRequest.httpMethod = "POST"
        urlRequest.httpBody = Data()
        urlRequest.setValue("0", forHTTPHeaderField: "Content-Length")
        let (_, response) = try await URLSession.shared.data(for: urlRequest)
        #expect((response as? HTTPURLResponse)?.statusCode == 504)
    }

    @Test("a FIXED port binds and serves: the configured default ports, not only port 0")
    func fixedPortBindsAndServes() async throws {
        // Every other test here asks for port 0. `requiredLocalEndpoint` with a port AND the same
        // port in `NWListener(using:on:)` throws POSIX 22 on macOS for any fixed port, so a listener
        // asked for 8787 or 8788 never started while all of those passed.
        let port = try freeLoopbackPort()
        let listener = LoopbackHTTPListener(port: port) { _ in .ok() }
        try await listener.start()
        defer { listener.stop() }
        #expect(listener.boundPort == port)

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/")!)
        request.httpMethod = "POST"
        request.httpBody = Data()
        request.setValue("0", forHTTPHeaderField: "Content-Length")
        let (_, response) = try await URLSession.shared.data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
    }

    @Test("a fixed port is still loopback-only: its LAN address is not served",
          .enabled(if: firstNonLoopbackIPv4Address() != nil, "needs a non-loopback interface that is up"))
    func fixedPortStillRefusesNonLoopbackAddress() async throws {
        guard let lanAddress = firstNonLoopbackIPv4Address() else { return }
        let port = try freeLoopbackPort()
        let listener = LoopbackHTTPListener(port: port) { _ in .ok() }
        try await listener.start()
        defer { listener.stop() }
        #expect(listener.boundPort == port)

        let connection = NWConnection(host: NWEndpoint.Host(lanAddress), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        let connected = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let resumer = OneShotResumer(continuation)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: resumer.resume(true)
                case .failed, .cancelled: resumer.resume(false)
                default: break
                }
            }
            connection.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) { resumer.resume(false) }
        }
        connection.cancel()
        #expect(!connected, "a connection to the LAN address must never succeed; the listener only bound 127.0.0.1")
    }

    @Test("start() binds via NWParameters.requiredLocalEndpoint to 127.0.0.1, not just any interface on the port")
    func bindsToLoopbackAtConstructionTime() throws {
        let params = LoopbackHTTPListener.loopbackParameters(port: 12345)
        guard case .hostPort(let host, let port) = params.requiredLocalEndpoint else {
            Issue.record("requiredLocalEndpoint was not set")
            return
        }
        #expect(host == .ipv4(.loopback))
        #expect(port.rawValue == 12345)
    }

    @Test("the isLoopback predicate distinguishes a loopback endpoint from a remote one")
    func isLoopbackPredicateDistinguishesLoopbackFromRemote() throws {
        let remote = NWEndpoint.hostPort(host: "93.184.216.34", port: 80)
        #expect(!LoopbackHTTPListener.isLoopback(remote))
        let loopback = NWEndpoint.hostPort(host: "127.0.0.1", port: 80)
        #expect(LoopbackHTTPListener.isLoopback(loopback))
    }

    @Test("start()'s real bind refuses a connection to the machine's own LAN address at the same port",
          .enabled(if: firstNonLoopbackIPv4Address() != nil, "needs a non-loopback interface that is up"))
    func realBindRefusesNonLoopbackAddress() async throws {
        guard let lanAddress = firstNonLoopbackIPv4Address() else {
            // No non-loopback interface is up (a sandboxed/offline CI runner) — the injected-
            // predicate test above still covers layer 2's behavior; nothing to assert here.
            return
        }
        let listener = LoopbackHTTPListener(port: 0) { _ in .ok() }
        try await listener.start()
        defer { listener.stop() }
        guard let port = listener.boundPort else { Issue.record("no bound port"); return }

        // The listener bound only 127.0.0.1:port — nothing is listening on the LAN address at
        // this same port, so a real TCP connect there must fail outright, proving the bind
        // itself (not just the per-connection check) restricts to loopback.
        let connection = NWConnection(host: NWEndpoint.Host(lanAddress), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        let outcome = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let resumer = OneShotResumer(continuation)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: resumer.resume(true)      // connected: the bind did NOT restrict — a failure
                case .failed, .cancelled: resumer.resume(false)
                default: break
                }
            }
            connection.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) { resumer.resume(false) }
        }
        connection.cancel()
        #expect(!outcome, "a connection to the LAN address must never succeed; the listener only bound 127.0.0.1")
    }

    @Test("a truncated request closes its connection without affecting a later well-formed one")
    func truncatedRequestDoesNotWedgeListener() async throws {
        let listener = LoopbackHTTPListener(port: 0) { _ in .ok() }
        try await listener.start()
        defer { listener.stop() }
        guard let port = listener.boundPort else { Issue.record("no bound port"); return }

        let partial = try await rawConnect(port: port)
        try await partial.send("GET / HTTP/1.1\r\n")
        partial.cancel()

        let url = URL(string: "http://127.0.0.1:\(port)/")!
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.httpBody = Data()
        urlRequest.setValue("0", forHTTPHeaderField: "Content-Length")
        let (_, response) = try await URLSession.shared.data(for: urlRequest)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
    }

    @Test("a Content-Length over the cap, or absent on a POST, is refused rather than read into memory")
    func contentLengthBoundsEnforced() async throws {
        let listener = LoopbackHTTPListener(port: 0) { _ in .ok() }
        try await listener.start()
        defer { listener.stop() }
        guard let port = listener.boundPort else { Issue.record("no bound port"); return }

        // Oversize Content-Length: the connection must actually close, not merely withhold a
        // 200 — "no response within N seconds" alone can't tell a refusal from a slow handler.
        let over = try await rawConnect(port: port)
        try await over.send("POST / HTTP/1.1\r\nContent-Length: \(LoopbackHTTPListener.maxContentLength + 1)\r\n\r\n")
        #expect(await over.isClosedByRemote(timeout: 2))
        over.cancel()

        // Missing Content-Length on a POST.
        let missing = try await rawConnect(port: port)
        try await missing.send("POST / HTTP/1.1\r\n\r\n")
        #expect(await missing.isClosedByRemote(timeout: 2))
        missing.cancel()
    }

    @Test("two Content-Length headers with conflicting values are refused; agreeing duplicates are not")
    func duplicateHeadersRejectedWhenConflicting() async throws {
        let listener = LoopbackHTTPListener(port: 0) { _ in .ok() }
        try await listener.start()
        defer { listener.stop() }
        guard let port = listener.boundPort else { Issue.record("no bound port"); return }

        let conflicting = try await rawConnect(port: port)
        try await conflicting.send("POST / HTTP/1.1\r\nContent-Length: 0\r\nContent-Length: 5\r\n\r\n")
        #expect(await conflicting.isClosedByRemote(timeout: 2), "conflicting duplicate headers must be refused, never resolved order-dependently")
        conflicting.cancel()

        let agreeing = try await rawConnect(port: port)
        try await agreeing.send("POST / HTTP/1.1\r\nContent-Length: 0\r\nContent-Length: 0\r\n\r\n")
        let response = await agreeing.readSome(timeout: 2)
        #expect(response?.contains("200") == true)
        agreeing.cancel()
    }

    @Test("a Transfer-Encoding header is refused outright: no chunked support, and it can't pair with Content-Length to smuggle a request")
    func transferEncodingRejected() async throws {
        let listener = LoopbackHTTPListener(port: 0) { _ in .ok() }
        try await listener.start()
        defer { listener.stop() }
        guard let port = listener.boundPort else { Issue.record("no bound port"); return }

        let connection = try await rawConnect(port: port)
        try await connection.send("POST / HTTP/1.1\r\nContent-Length: 0\r\nTransfer-Encoding: chunked\r\n\r\n")
        #expect(await connection.isClosedByRemote(timeout: 2))
        connection.cancel()
    }

    @Test("a request line over maxRequestLineBytes is refused")
    func requestLineCapEnforced() async throws {
        var limits = LoopbackHTTPListener.Limits()
        limits.maxRequestLineBytes = 32
        let listener = LoopbackHTTPListener(port: 0, limits: limits) { _ in .ok() }
        try await listener.start()
        defer { listener.stop() }
        guard let port = listener.boundPort else { Issue.record("no bound port"); return }

        let connection = try await rawConnect(port: port)
        let oversizePath = String(repeating: "a", count: 200)
        try await connection.send("GET /\(oversizePath) HTTP/1.1\r\n\r\n")
        #expect(await connection.isClosedByRemote(timeout: 2))
        connection.cancel()
    }

    @Test("more headers than maxHeaderCount is refused")
    func headerCountCapEnforced() async throws {
        var limits = LoopbackHTTPListener.Limits()
        limits.maxHeaderCount = 3
        let listener = LoopbackHTTPListener(port: 0, limits: limits) { _ in .ok() }
        try await listener.start()
        defer { listener.stop() }
        guard let port = listener.boundPort else { Issue.record("no bound port"); return }

        let connection = try await rawConnect(port: port)
        let extraHeaders = (0..<10).map { "X-Pad-\($0): v\r\n" }.joined()
        try await connection.send("POST / HTTP/1.1\r\nContent-Length: 0\r\n\(extraHeaders)\r\n")
        #expect(await connection.isClosedByRemote(timeout: 2))
        connection.cancel()
    }

    @Test("a connection idle past readTimeout, with headers complete but the body never arriving, is closed")
    func readTimeoutEnforced() async throws {
        var limits = LoopbackHTTPListener.Limits()
        limits.readTimeout = .milliseconds(200)
        let listener = LoopbackHTTPListener(port: 0, limits: limits) { _ in .ok() }
        try await listener.start()
        defer { listener.stop() }
        guard let port = listener.boundPort else { Issue.record("no bound port"); return }

        let connection = try await rawConnect(port: port)
        // Headers complete (Content-Length: 5) but the 5 body bytes never arrive.
        try await connection.send("POST / HTTP/1.1\r\nContent-Length: 5\r\n\r\n")
        #expect(await connection.isClosedByRemote(timeout: 2))
        connection.cancel()
    }

    @Test("a non-loopback remote is refused via the injected predicate, independent of the real bind")
    func injectedIsLoopbackCheckRefuses() async throws {
        let listener = LoopbackHTTPListener(port: 0, isLoopbackCheck: { _ in false }) { _ in .ok() }
        try await listener.start()
        defer { listener.stop() }
        guard let port = listener.boundPort else { Issue.record("no bound port"); return }

        // The real connection IS loopback; only the injected predicate says otherwise, isolating
        // accept()'s own refusal path from whatever the real bind restricts.
        let connection = try await rawConnect(port: port)
        try await connection.send("POST / HTTP/1.1\r\nContent-Length: 0\r\n\r\n")
        #expect(await connection.isClosedByRemote(timeout: 2))
        connection.cancel()
    }

    @Test("a connection that never finishes sending headers is closed after headerCompletionDeadline, freeing its slot",
          .timeLimit(.minutes(1)))
    func headerCompletionDeadlineEnforced() async throws {
        let listener = LoopbackHTTPListener(port: 0) { _ in .ok() }
        try await listener.start()
        defer { listener.stop() }
        guard let port = listener.boundPort else { Issue.record("no bound port"); return }

        // Fill every slot but one with idle connections, then stall the last slot with a request
        // whose headers never complete.
        var idle: [RawConnection] = []
        for _ in 0..<(LoopbackHTTPListener.maxConcurrentConnections - 1) {
            idle.append(try await rawConnect(port: port))
        }
        defer { for c in idle { c.cancel() } }
        let stalled = try await rawConnect(port: port)
        try await stalled.send("GET /never-terminated")
        defer { stalled.cancel() }

        // Past headerCompletionDeadline, the stalled connection's slot must be freed: a fresh
        // connection (which would otherwise be refused outright, over the cap) gets served.
        try await Task.sleep(for: .seconds(LoopbackHTTPListener.headerCompletionDeadline.timeInterval + 1))
        let fresh = try await rawConnect(port: port)
        try await fresh.send("POST / HTTP/1.1\r\nContent-Length: 0\r\n\r\n")
        let response = await fresh.readSome(timeout: 2)
        #expect(response?.contains("200") == true, "the stalled connection's slot should have been freed")
        fresh.cancel()
    }

    @Test("a connection past maxConcurrentConnections is refused outright, not queued")
    func concurrentConnectionCapEnforced() async throws {
        let listener = LoopbackHTTPListener(port: 0) { _ in .ok() }
        try await listener.start()
        defer { listener.stop() }
        guard let port = listener.boundPort else { Issue.record("no bound port"); return }

        var idle: [RawConnection] = []
        for _ in 0..<LoopbackHTTPListener.maxConcurrentConnections {
            idle.append(try await rawConnect(port: port))
        }
        // Give the listener's accept queue a moment to register all of them before testing the cap.
        try await Task.sleep(for: .milliseconds(200))
        defer { for c in idle { c.cancel() } }

        let extra = try await rawConnect(port: port)
        try await extra.send("POST / HTTP/1.1\r\nContent-Length: 0\r\n\r\n")
        let refusedResponse = await extra.readSome(timeout: 2)
        #expect(refusedResponse == nil || !refusedResponse!.contains("200"), "a connection past the cap must never be served")
        extra.cancel()

        // Freeing a slot lets a fresh connection through — proving the cap, not general brokenness.
        idle.removeLast().cancel()
        try await Task.sleep(for: .milliseconds(200))
        let afterFree = try await rawConnect(port: port)
        try await afterFree.send("POST / HTTP/1.1\r\nContent-Length: 0\r\n\r\n")
        let servedResponse = await afterFree.readSome(timeout: 2)
        #expect(servedResponse?.contains("200") == true)
        afterFree.cancel()
    }
}

private final class CallFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var wasCalled = false
    func set() { lock.withLock { wasCalled = true } }
    var value: Bool { lock.withLock { wasCalled } }
}

// MARK: - Raw TCP test helper

/// A continuation that resumes at most once, safe to call from any thread/closure — avoids
/// capturing a bare local mutable closure across `@Sendable` NWConnection callbacks.
private final class OneShotResumer<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Never>?

    init(_ continuation: CheckedContinuation<T, Never>) { self.continuation = continuation }

    func resume(_ value: T) {
        lock.lock()
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume(returning: value)
    }
}

private final class RawConnection: @unchecked Sendable {
    let connection: NWConnection
    init(_ connection: NWConnection) { self.connection = connection }

    func send(_ string: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: Data(string.utf8), completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }

    func readSome(timeout: TimeInterval) async -> String? {
        await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            let resumer = OneShotResumer(continuation)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, _, _ in
                resumer.resume(data.flatMap { String(data: $0, encoding: .utf8) })
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { resumer.resume(nil) }
        }
    }

    /// `stateUpdateHandler` tracks this connection's own lifecycle, not the remote's: a graceful
    /// remote close surfaces as EOF on `receive`, not a `.cancelled`/`.failed` state transition.
    /// So "was this refused" has to be answered by actually trying to read: EOF or an error means
    /// the remote closed without serving anything; real data means it wasn't refused.
    func isClosedByRemote(timeout: TimeInterval) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let resumer = OneShotResumer(continuation)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, isComplete, error in
                // A final read can carry both real data and isComplete at once (the last bytes,
                // then EOF); that is "served", not "closed without serving" — check data first.
                if let data, !data.isEmpty {
                    resumer.resume(false)
                } else if isComplete || error != nil {
                    resumer.resume(true)
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { resumer.resume(false) }
        }
    }

    func cancel() { connection.cancel() }
}

private final class OneShotThrowingResumer: @unchecked Sendable {
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

/// The machine's own first up, non-loopback IPv4 address (e.g. the Wi-Fi/Ethernet interface's
/// LAN address), or `nil` if none is up — a sandboxed or offline runner may have none.
private func firstNonLoopbackIPv4Address() -> String? {
    var addrList: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&addrList) == 0, let first = addrList else { return nil }
    defer { freeifaddrs(first) }

    var cursor: UnsafeMutablePointer<ifaddrs>? = first
    while let interface = cursor {
        defer { cursor = interface.pointee.ifa_next }
        let flags = Int32(interface.pointee.ifa_flags)
        guard (flags & IFF_UP) != 0, (flags & IFF_LOOPBACK) == 0,
              let addr = interface.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }
        var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let result = addr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
            getnameinfo(sockaddrPtr, socklen_t(sockaddrPtr.pointee.sa_len), &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST)
        }
        guard result == 0 else { continue }
        return buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    }
    return nil
}

private func rawConnect(port: UInt16) async throws -> RawConnection {
    let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
    let raw = RawConnection(connection)
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        let resumer = OneShotThrowingResumer(continuation)
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready: resumer.resume()
            case .failed(let error): resumer.resume(throwing: error)
            default: break
            }
        }
        connection.start(queue: .global())
    }
    return raw
}

/// A TCP port nothing is listening on right now: bound to port 0 on loopback by a BSD socket, read
/// back, closed. Another process could take it before the test does; that is a flake only on a
/// machine racing for the same ephemeral port in that instant.
private func freeLoopbackPort() throws -> UInt16 {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { throw POSIXError(.EMFILE) }
    defer { close(fd) }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    address.sin_port = 0
    let bound = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    guard bound == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EINVAL) }
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let named = withUnsafeMutablePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
    }
    guard named == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EINVAL) }
    return UInt16(bigEndian: address.sin_port)
}
