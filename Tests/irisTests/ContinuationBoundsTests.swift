import Testing
import Foundation
import Network
@testable import IrisKit

/// #1272 (follow-up to #1162, #428): four waits that parked on a callback or a child process with no way
/// out. Each is driven with the resumer never firing (a browser that never comes back, a `gcloud` that
/// never exits) and must end by cancel or by its deadline, inside a test bound: `value(of:within:)` fails
/// the test at its bound instead of hanging the run.
@Suite("Waits on a callback or a child end by cancel or deadline (#1272)", .serialized, .timeLimit(.minutes(2)))
struct ContinuationBoundsTests {
    // MARK: OAuth: the browser never returns

    private final class Ready: @unchecked Sendable {
        private let lock = NSLock()
        private var uri: String?
        func set(_ value: String) { lock.withLock { uri = value } }
        var value: String? { lock.withLock { uri } }
    }

    /// Whether something still accepts a TCP connection on this loopback port.
    private nonisolated func accepts(port: UInt16) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        return rc == 0
    }

    private func waitFor(_ seconds: Double = 10, _ condition: @Sendable () -> Bool) async -> Bool {
        let deadline = TestClock.deadline(seconds)
        while !condition() {
            if TestClock.seconds(since: deadline) > 0 { return false }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return true
    }

    @Test("a cancelled OAuth wait throws CancellationError and closes its listener")
    @MainActor
    func oauthCancelEndsTheWaitAndClosesTheListener() async throws {
        let ready = Ready()
        let task = Task { try await OAuthManager.shared.listenForCode(timeout: 120, ready: { uri, _ in ready.set(uri) }) }
        #expect(await waitFor { ready.value != nil }, "the listener came up")
        let port = try #require(ready.value.flatMap { URL(string: $0)?.port }.map { UInt16($0) })
        #expect(accepts(port: port), "control: the listener accepts while waiting")
        task.cancel()
        do {
            _ = try await value(of: task, within: 10)
            Issue.record("a cancelled wait returned a code")
        } catch is CancellationError {
        } catch {
            Issue.record("expected CancellationError, got \(error)")
        }
        #expect(await waitFor { !accepts(port: port) }, "the listener is closed after the cancel")
    }

    @Test("an OAuth wait already cancelled before it starts throws CancellationError and opens nothing")
    @MainActor
    func oauthPreCancelled() async throws {
        let ready = Ready()
        let task = Task {
            while !Task.isCancelled { await Task.yield() }
            return try await OAuthManager.shared.listenForCode(timeout: 120, ready: { uri, _ in ready.set(uri) })
        }
        task.cancel()
        do {
            _ = try await value(of: task, within: 10)
            Issue.record("a pre-cancelled wait returned a code")
        } catch is CancellationError {
        } catch {
            Issue.record("expected CancellationError, got \(error)")
        }
    }

    @Test("the OAuth wait's own deadline still ends it with the timeout error")
    @MainActor
    func oauthTimeout() async throws {
        let task = Task { try await OAuthManager.shared.listenForCode(timeout: 0.3, ready: { _, _ in }) }
        do {
            _ = try await value(of: task, within: 10)
            Issue.record("a wait nobody answered returned a code")
        } catch {
            #expect((error as NSError).code == 408, "\(error)")
        }
    }

    // MARK: gcloud: the child never exits

    private func script(_ body: String) throws -> (path: String, cleanup: () -> Void) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("iris-1272-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("gcloud")
        try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return (url.path, { try? FileManager.default.removeItem(at: dir) })
    }

    @Test("a gcloud that never exits is killed at the deadline: ADC read, helper read and enableAPI each end")
    func hungGcloudEndsAtTheDeadline() async throws {
        let (path, cleanup) = try script("sleep 60")
        defer { cleanup() }
        let adc = Task { try await ADCCredentialManager.shared.runGCloud(path: path, args: ["x"], timeoutSeconds: 0.5) }
        #expect(try await value(of: adc, within: 15) == nil)
        let read = Task { await GCloudHelper.runAsync(gcloudPath: path, timeoutSeconds: 0.5, "config", "get-value", "project") }
        #expect(try await value(of: read, within: 15) == nil)
        let enable = Task { await GCloudHelper.enableAPI("x.googleapis.com", gcloudPath: path, timeoutSeconds: 0.5) }
        #expect(try await value(of: enable, within: 15) == false)
    }

    /// Whether a process is still alive (signal 0 reaches it).
    private func alive(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 }

    private func pids(in file: URL) -> [pid_t] {
        ((try? String(contentsOf: file, encoding: .utf8)) ?? "").split(whereSeparator: \.isWhitespace).compactMap { pid_t($0) }
    }

    @Test("the deadline kills the gcloud process group, a grandchild included, at each of the three sites")
    func deadlineKillsTheGroup() async throws {
        for site in ["ADC", "read", "enable"] {
            let pidFile = FileManager.default.temporaryDirectory.appendingPathComponent("iris-1272-pids-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: pidFile) }
            // The leader and a background child both record their pids, then both sleep.
            let (path, cleanup) = try script("echo $$ >> '\(pidFile.path)'\nsleep 60 &\necho $! >> '\(pidFile.path)'\nwait")
            defer { cleanup() }
            switch site {
            case "ADC": _ = try await value(of: Task { try await ADCCredentialManager.shared.runGCloud(path: path, args: ["x"], timeoutSeconds: 0.5) }, within: 15)
            case "read": _ = try await value(of: Task { await GCloudHelper.runAsync(gcloudPath: path, timeoutSeconds: 0.5, "x") }, within: 15)
            default: _ = try await value(of: Task { await GCloudHelper.enableAPI("x.googleapis.com", gcloudPath: path, timeoutSeconds: 0.5) }, within: 15)
            }
            let recorded = pids(in: pidFile)
            #expect(recorded.count == 2, "\(site): the script recorded its leader and child: \(recorded)")
            #expect(await waitFor(10) { recorded.allSatisfy { !self.alive($0) } }, "\(site): the leader and its child are gone after the deadline: \(recorded)")
            for pid in recorded where alive(pid) { kill(pid, SIGKILL) }
        }
    }

    @Test("a cancelled gcloud call ends at once, not at its deadline")
    func cancelledGcloudEnds() async throws {
        let (path, cleanup) = try script("sleep 60")
        defer { cleanup() }
        let adc = Task { try await ADCCredentialManager.shared.runGCloud(path: path, args: ["x"], timeoutSeconds: 600) }
        let read = Task { await GCloudHelper.runAsync(gcloudPath: path, timeoutSeconds: 600, "x") }
        let enable = Task { await GCloudHelper.enableAPI("x.googleapis.com", gcloudPath: path, timeoutSeconds: 600) }
        try await Task.sleep(nanoseconds: 300_000_000)
        adc.cancel(); read.cancel(); enable.cancel()
        #expect(try await value(of: adc, within: 15) == nil)
        #expect(try await value(of: read, within: 15) == nil)
        #expect(try await value(of: enable, within: 15) == false)
    }

    @Test("control: a gcloud that answers gives its last line, its output and true; a missing binary throws for ADC")
    func answeringGcloudStillWorks() async throws {
        let (path, cleanup) = try script("echo first; echo token-123")
        defer { cleanup() }
        #expect(try await ADCCredentialManager.shared.runGCloud(path: path, args: ["x"]) == "token-123")
        #expect(await GCloudHelper.runAsync(gcloudPath: path, "x")?.hasSuffix("token-123") == true)
        #expect(await GCloudHelper.enableAPI("x.googleapis.com", gcloudPath: path) == true)
        let (failing, cleanupFailing) = try script("exit 3")
        defer { cleanupFailing() }
        #expect(try await ADCCredentialManager.shared.runGCloud(path: failing, args: ["x"]) == nil)
        #expect(await GCloudHelper.enableAPI("x.googleapis.com", gcloudPath: failing) == false)
        await #expect(throws: (any Error).self) {
            _ = try await ADCCredentialManager.shared.runGCloud(path: "/nonexistent/gcloud", args: ["x"])
        }
    }

    // MARK: the loopback listener's start

    @Test("a cancelled LoopbackHTTPListener.start ends: before it begins, with a listener that never reports, and with a real one")
    func loopbackStartCancel() async throws {
        for (name, early, neverStarts) in [("before it begins", true, true), ("before it begins, real listener", true, false), ("a listener stuck waiting", false, true), ("a real listener", false, false)] {
            let listener = LoopbackHTTPListener(port: 0) { _ in .error(statusCode: 404, .invalidRequest("none")) }
            defer { listener.stop() }
            let task = Task {
                if early { while !Task.isCancelled { await Task.yield() } }
                if neverStarts {
                    try await listener.start(startListener: { @Sendable _, _ in })
                } else {
                    try await listener.start()
                }
            }
            if early { task.cancel() } else {
                try await Task.sleep(nanoseconds: neverStarts ? 300_000_000 : 1_000_000)
                task.cancel()
            }
            do { _ = try await value(of: task, within: 10) } catch is CancellationError {} catch {
                Issue.record("\(name): unexpected \(error)")
            }
        }
    }
}
