import Testing
import Foundation
import Darwin
@testable import IrisKit

/// `search_web` has no timeout (#431): the script's `urlopen` call had no `timeout=`, and the
/// Swift side blocked on `readDataToEndOfFile()` with no deadline, so a server that accepted the
/// connection and then stalled held the tool call — and a cooperative-pool thread — forever.
///
/// These run the *real* embedded script through a *real* `python3`, pointed at a local stub
/// server instead of the network, so the fix is exercised end-to-end rather than mocked away.
@Suite("search_web timeout (#431)", .timeLimit(.minutes(1)))
struct ToolExecutorSearchWebTimeoutTests {
    @Test("a stalled connection times out via the script's own network timeout")
    func scriptLevelTimeout() async throws {
        let server = try NeverRespondingServer()
        defer { server.close() }
        let irisDir = Self.scratchDir()
        defer { try? FileManager.default.removeItem(at: irisDir) }

        let start = Date()
        let result = await ToolExecutor.runSearchWeb(
            query: "test", targetURL: server.url,
            networkTimeoutSeconds: 1, processTimeoutSeconds: 10, irisDir: irisDir)
        let elapsed = Date().timeIntervalSince(start)

        #expect(elapsed < 8, "should fail on the script's own 1s network timeout, not the 10s process bound")
        #expect(result.lowercased().contains("timed out"), "got: \(result)")
    }

    @Test("a hung interpreter is still killed by the process-group bound")
    func processLevelTimeout() async throws {
        let server = try NeverRespondingServer()
        defer { server.close() }
        let irisDir = Self.scratchDir()
        defer { try? FileManager.default.removeItem(at: irisDir) }

        // The script's own network timeout is longer than the process bound, so this exercises
        // `ProcessGroupRunner.capture(timeoutSeconds:)` killing the group on schedule rather than
        // the script's own `except` firing first.
        let start = Date()
        let result = await ToolExecutor.runSearchWeb(
            query: "test", targetURL: server.url,
            networkTimeoutSeconds: 30, processTimeoutSeconds: 2, irisDir: irisDir)
        let elapsed = Date().timeIntervalSince(start)

        #expect(elapsed < 10, "the process bound (2s) plus the kill ladder's grace should end this well under 10s")
        #expect(result == ToolExecutor.searchWebTimedOutMessage(seconds: 2), "got: \(result)")
    }

    @Test("a server that responds promptly is unaffected by either bound")
    func promptResponseStillWorks() async throws {
        let server = try RespondingServer(body: "<html><body>no matches here</body></html>")
        defer { server.close() }
        let irisDir = Self.scratchDir()
        defer { try? FileManager.default.removeItem(at: irisDir) }

        let result = await ToolExecutor.runSearchWeb(
            query: "test", targetURL: server.url,
            networkTimeoutSeconds: 5, processTimeoutSeconds: 10, irisDir: irisDir)

        // No `result-link`/`result-snippet` markup in the stub body, so the parser finds nothing,
        // but it must still be the script's normal JSON-array output, not a timeout or error.
        #expect(result.contains("[") , "got: \(result)")
        #expect(!result.lowercased().contains("timed out"), "got: \(result)")
    }

    private static func scratchDir() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("iris-431-\(UUID().uuidString)")
    }
}

/// A TCP server on loopback that accepts a connection and then never reads, writes or closes it —
/// the shape of a stalled search backend. Each accepted connection is held open until `close()`.
final class NeverRespondingServer: @unchecked Sendable {
    let port: UInt16
    private let listenFD: Int32
    private let lock = NSLock()
    private var acceptedFDs: [Int32] = []
    private var stopped = false

    init() throws {
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
        guard listen(fd, 4) == 0 else { Darwin.close(fd); throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }

        self.listenFD = fd
        self.port = UInt16(bigEndian: actual.sin_port)
        startAccepting()
    }

    var url: String { "http://127.0.0.1:\(port)/" }

    func startAccepting() {
        let thread = Thread { [self] in
            while true {
                let client = accept(self.listenFD, nil, nil)
                if client < 0 { return }
                self.lock.lock()
                if self.stopped { self.lock.unlock(); Darwin.close(client); return }
                self.acceptedFDs.append(client)
                self.lock.unlock()
                // Never read, write or close `client`: it holds the other side's blocking read open.
            }
        }
        thread.name = "iris-test.never-responding-server"
        thread.start()
    }

    func close() {
        lock.lock()
        stopped = true
        let fds = acceptedFDs
        acceptedFDs = []
        lock.unlock()
        Darwin.close(listenFD)
        for fd in fds { Darwin.close(fd) }
    }
}

/// A TCP server on loopback that accepts a connection and immediately writes a fixed HTTP
/// response, then closes — the happy path `search_web` normally hits.
final class RespondingServer: @unchecked Sendable {
    let port: UInt16
    private let listenFD: Int32
    private let lock = NSLock()
    private var stopped = false

    init(body: String) throws {
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
        guard listen(fd, 4) == 0 else { Darwin.close(fd); throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }

        self.listenFD = fd
        self.port = UInt16(bigEndian: actual.sin_port)
        startAccepting(body: body)
    }

    var url: String { "http://127.0.0.1:\(port)/" }

    func startAccepting(body: String) {
        let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        let data = Array(response.utf8)
        let thread = Thread { [self] in
            while true {
                let client = accept(self.listenFD, nil, nil)
                if client < 0 { return }
                self.lock.lock()
                let stopped = self.stopped
                self.lock.unlock()
                if stopped { Darwin.close(client); return }
                // Drain whatever the client sent before replying, so its write doesn't block on us.
                var buf = [UInt8](repeating: 0, count: 4096)
                _ = recv(client, &buf, buf.count, 0)
                data.withUnsafeBufferPointer { ptr in
                    _ = write(client, ptr.baseAddress, ptr.count)
                }
                Darwin.close(client)
            }
        }
        thread.name = "iris-test.responding-server"
        thread.start()
    }

    func close() {
        lock.lock()
        stopped = true
        lock.unlock()
        Darwin.close(listenFD)
    }
}
