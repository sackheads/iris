import Foundation

/// A minimal SOCKS5 proxy for tests (#904): accepts the no-auth handshake, decodes a CONNECT
/// request (IPv4, IPv6 or domain ATYP), records the requested host:port, then replies success or
/// refused. It never actually relays bytes to the target — #904's own tests only need to know
/// *what was asked for*, which is exactly what makes a SOCKS5h proxy useful here: pointed at it,
/// a client that is leaving name resolution to the proxy hands over the hostname itself instead
/// of resolving it first, so the hostname a hostile page tried to look up shows up here even
/// though nothing on this host ever asked the real DNS resolver about it.
///
/// Modeled on `ConnectionCountingServer` in `ViewerZeroConnectionsTests.swift`: a raw BSD socket,
/// one accept-loop `Thread`, state behind an `NSLock`.
final class SOCKS5ProxyTestHelper: @unchecked Sendable {
    struct RequestedTarget: Equatable, CustomStringConvertible {
        let host: String
        let port: UInt16
        var description: String { "\(host):\(port)" }
    }

    enum Outcome {
        case succeed
        case refuse
    }

    let port: UInt16
    private let listenFD: Int32
    private let lock = NSLock()
    private var requests: [RequestedTarget] = []
    private var stopped = false
    private let outcome: Outcome
    private let holdOpen: Bool

    /// `holdOpen` keeps a successful connection open after the CONNECT reply instead of closing
    /// it, so a client's next write lands on a live socket rather than a closed pipe — closing
    /// right away makes `URLSession` treat the reset as transient and silently retry up to three
    /// times (inflating `recordedTargets`). A real `WKWebView` resource fetch is the opposite
    /// case: held open with no response, it never completes or fails, so the page's `load` event
    /// (and `didFinish`) never fires and a waiter blocks forever — pass `false` there so the
    /// fetch fails fast instead.
    init(outcome: Outcome = .succeed, holdOpen: Bool = true) throws {
        self.outcome = outcome
        self.holdOpen = holdOpen

        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else { Darwin.close(fd); throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }

        var actual = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &actual) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &len)
            }
        }
        guard listen(fd, 8) == 0 else { Darwin.close(fd); throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }

        self.listenFD = fd
        self.port = UInt16(bigEndian: actual.sin_port)
        startAccepting()
    }

    var recordedTargets: [RequestedTarget] { lock.withLock { requests } }

    func close() {
        lock.lock()
        stopped = true
        lock.unlock()
        Darwin.close(listenFD)
    }

    private func startAccepting() {
        let thread = Thread { [self] in
            while true {
                let client = accept(self.listenFD, nil, nil)
                if client < 0 { return }
                self.lock.lock()
                let isStopped = self.stopped
                self.lock.unlock()
                if isStopped { Darwin.close(client); return }
                let handler = Thread { [self] in self.handle(client) }
                handler.name = "iris-test.socks5-proxy.connection"
                handler.start()
            }
        }
        thread.name = "iris-test.socks5-proxy.accept"
        thread.start()
    }

    private func handle(_ client: Int32) {
        defer { Darwin.close(client) }

        // Greeting: VER(1)=5, NMETHODS(1), METHODS(NMETHODS). Reply VER=5, METHOD=0x00 (no auth).
        guard let greeting = readExactly(client, 2), greeting[0] == 5 else { return }
        let methodCount = Int(greeting[1])
        guard methodCount > 0, readExactly(client, methodCount) != nil else { return }
        guard writeAll(client, [0x05, 0x00]) else { return }

        // Request: VER(1)=5, CMD(1), RSV(1), ATYP(1), DST.ADDR, DST.PORT(2, big-endian).
        guard let header = readExactly(client, 4), header[0] == 5 else { return }
        let atyp = header[3]

        let host: String
        switch atyp {
        case 0x01: // IPv4
            guard let addr = readExactly(client, 4) else { return }
            host = addr.map { String($0) }.joined(separator: ".")
        case 0x03: // domain
            guard let lenByte = readExactly(client, 1), let nameBytes = readExactly(client, Int(lenByte[0])) else { return }
            host = String(decoding: nameBytes, as: UTF8.self)
        case 0x04: // IPv6
            guard let addr = readExactly(client, 16) else { return }
            host = Self.formatIPv6(addr)
        default:
            return
        }

        guard let portBytes = readExactly(client, 2) else { return }
        let targetPort = UInt16(portBytes[0]) << 8 | UInt16(portBytes[1])

        lock.lock()
        requests.append(RequestedTarget(host: host, port: targetPort))
        lock.unlock()

        let rep: UInt8 = outcome == .succeed ? 0x00 : 0x05
        // BND.ADDR/BND.PORT are unused by a caller that only reads the recorded target; 0.0.0.0:0.
        guard writeAll(client, [0x05, rep, 0x00, 0x01, 0, 0, 0, 0, 0, 0]) else { return }
        guard outcome == .succeed, holdOpen else { return }

        // Never relays to a real target and never answers: a caller only needs the recorded
        // target. Closing right here used to make the client's own HTTP write hit a closed pipe,
        // which URLSession treats as a transient reset and silently retries up to three times
        // (inflating recordedTargets 3x per logical request) rather than a clean timeout — so
        // this drains and discards until the client gives up or closes.
        var scratch = [UInt8](repeating: 0, count: 256)
        while true {
            let n = scratch.withUnsafeMutableBytes { read(client, $0.baseAddress, $0.count) }
            if n <= 0 { return }
        }
    }

    private static func formatIPv6(_ bytes: [UInt8]) -> String {
        stride(from: 0, to: 16, by: 2)
            .map { String(format: "%02x%02x", bytes[$0], bytes[$0 + 1]) }
            .joined(separator: ":")
    }

    private func readExactly(_ fd: Int32, _ count: Int) -> [UInt8]? {
        var buffer = [UInt8](repeating: 0, count: count)
        var received = 0
        while received < count {
            let n = buffer.withUnsafeMutableBytes { ptr -> Int in
                read(fd, ptr.baseAddress!.advanced(by: received), count - received)
            }
            if n <= 0 { return nil }
            received += n
        }
        return buffer
    }

    private func writeAll(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
        var sent = 0
        while sent < bytes.count {
            let n = bytes.withUnsafeBytes { ptr -> Int in
                write(fd, ptr.baseAddress!.advanced(by: sent), bytes.count - sent)
            }
            if n <= 0 { return false }
            sent += n
        }
        return true
    }
}
