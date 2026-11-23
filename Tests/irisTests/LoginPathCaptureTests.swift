import Testing
import Foundation
import os
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
        let shell = try script(#"PATH=/a/bin:/b/bin::/c/bin; eval "$2""#)
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
        let shell = try script(#"sleep 0.5; PATH=/a/bin; eval "$2""#)
        let fired = OSAllocatedUnfairLock(initialState: false)
        // A timer in the default mode: `waitUntilExit()` services it while it waits, which is how a
        // SwiftUI body re-entered mid-initialisation. A semaphore wait does not.
        let timer = Timer(timeInterval: 0.05, repeats: false) { _ in fired.withLock { $0 = true } }
        RunLoop.main.add(timer, forMode: .default)
        defer { timer.invalidate() }
        _ = BinaryResolver.captureLoginPath(shell: shell)
        #expect(!fired.withLock { $0 })
    }

    /// #1162: a process the login files start can keep nothing of ours open. Before, it inherited the stdout
    /// pipe and the read waited for it, at zero CPU, under the cache's lock.
    @Test("a process the login shell leaves running does not hold up the answer")
    func backgroundChildDoesNotBlock() async throws {
        let shell = try script(#"sleep 300 & PATH=/a:/b; eval "$2""#)
        let start = TestClock.now()
        let entries = try await value(of: Task.detached { BinaryResolver.captureLoginPath(shell: shell, timeout: 5) }, within: 15)
        #expect(entries == ["/a", "/b"])
        #expect(TestClock.seconds(since: start) < 10, "the answer came on the shell's exit, not the child's")
    }

    @Test("what isn't one line of absolute paths gives no entries", arguments: [
        "relative/bin:/usr/bin", "/usr/bin\n/opt/bin", "Welcome back! /usr/bin", "", "~/bin:/usr/bin",
    ])
    func malformedIsEmpty(_ value: String) {
        // A space is legal inside a path (`/Applications/My App/bin`), so only these shapes are refused.
        #expect(BinaryResolver.pathEntries(value).isEmpty, "\(value)")
    }

    @Test("a path with a space in it is kept")
    func spaceInPathKept() {
        #expect(BinaryResolver.pathEntries("/Applications/My App/bin:/usr/bin") == ["/Applications/My App/bin", "/usr/bin"])
    }

    @Test("the shell's PATH file is written in a private folder that is gone afterwards")
    func tempFolderIsRemoved() throws {
        let note = FileManager.default.temporaryDirectory.appendingPathComponent("iris-1162-note-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: note) }
        let shell = try script(#"echo "$IRIS_PATH_OUT" > '"# + note + #"'; PATH=/a; eval "$2""#)
        #expect(BinaryResolver.captureLoginPath(shell: shell) == ["/a"])
        let out = try String(contentsOfFile: note, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(!out.isEmpty && !FileManager.default.fileExists(atPath: (out as NSString).deletingLastPathComponent), "\(out)")
    }

    @Test("HomeMount.reason still takes an explicit login PATH, and the home folder is refused")
    func homeMountExplicitPath() {
        #expect(HomeMount.reason(for: NSHomeDirectory(), loginPath: []) != nil)
        #expect(HomeMount.reason(for: "/tmp/iris-1001-nothing", loginPath: []) == nil)
    }
}
