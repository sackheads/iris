import Testing
import Foundation
@testable import IrisKit

/// #1001: the login-shell PATH capture must not pump the main run loop while it waits, or SwiftUI
/// re-enters a view body inside the still-initialising cache and libdispatch aborts the process.
@Suite("Login PATH capture (#1001)", .timeLimit(.minutes(1)))
struct LoginPathCaptureTests {
    private func script(_ body: String) throws -> String {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("iris-1001-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("shell.sh")
        try Data("#!/bin/sh\n\(body)\n".utf8).write(to: path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
        return path.path
    }

    @Test("a shell's PATH is split into entries")
    func splits() throws {
        let shell = try script("echo /a/bin:/b/bin::/c/bin")
        #expect(BinaryResolver.captureLoginPath(shell: shell) == ["/a/bin", "/b/bin", "/c/bin"])
    }

    @Test("a missing shell gives no entries")
    func missing() {
        #expect(BinaryResolver.captureLoginPath(shell: "/nonexistent/iris-1001-shell").isEmpty)
    }

    @Test("a shell that hangs is cut off at the timeout")
    func hangs() throws {
        let shell = try script("sleep 30")
        let start = TestClock.now()
        #expect(BinaryResolver.captureLoginPath(shell: shell, timeout: 0.5).isEmpty)
        #expect(TestClock.seconds(since: start) < 10)
    }

    @MainActor
    @Test("waiting on the shell does not run the main run loop")
    func doesNotPumpRunLoop() throws {
        let shell = try script("sleep 0.5; echo /a/bin")
        var fired = false
        // A timer in the default mode: `waitUntilExit()` services it while it waits, which is how a
        // SwiftUI body re-entered mid-initialisation. A semaphore wait does not.
        let timer = Timer(timeInterval: 0.05, repeats: false) { _ in fired = true }
        RunLoop.main.add(timer, forMode: .default)
        defer { timer.invalidate() }
        _ = BinaryResolver.captureLoginPath(shell: shell)
        #expect(!fired)
    }

    @Test("HomeMount.reason still takes an explicit login PATH, and the home folder is refused")
    func homeMountExplicitPath() {
        #expect(HomeMount.reason(for: NSHomeDirectory(), loginPath: []) != nil)
        #expect(HomeMount.reason(for: "/tmp/iris-1001-nothing", loginPath: []) == nil)
    }
}
