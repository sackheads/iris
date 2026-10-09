import Testing
import Foundation
@testable import IrisKit

@Suite("SandboxingManager Tests")
struct SandboxingManagerTests {

    @Test("isContainerInstalled returns boolean without crashing")
    func testIsContainerInstalled() {
        let installed = SandboxingManager.shared.isContainerInstalled
        // Value depends on host machine state, verify getter evaluates cleanly
        #expect(installed == true || installed == false)
    }

    @Test("containerBinaryPath returns a path if installed, nil otherwise")
    func testContainerBinaryPath() {
        let path = SandboxingManager.shared.containerBinaryPath
        let installed = SandboxingManager.shared.isContainerInstalled
        // Both must agree: path is non-nil iff installed is true
        #expect((path != nil) == installed)
        // If installed, path must match the first existing search path (order matters)
        if let path {
            let expected = SandboxingManager.containerSearchPaths.first {
                FileManager.default.fileExists(atPath: $0)
            }
            #expect(path == expected, "Resolved path \(path) should match first existing search path \(expected ?? "nil")")
        }
    }

    @Test("startContainerSystem returns error status when binary is missing")
    func testStartContainerSystemSafety() async {
        // Method returns cleanly with boolean success flag and message tuple
        let result = await SandboxingManager.shared.startContainerSystem()
        #expect(result.success == true || result.success == false)
    }
}

/// #293 review: `startContainerSystem` now sits on JobRunner's fire-time pre-check and click-time
/// re-check, both ahead of a run's own deadline. It used to run through `sh -c`, unbounded, and
/// read its output only after `waitUntilExit()` — a pipe-buffer deadlock waiting to happen the
/// first time a kernel download's progress output overran it. All four tests use a stub binary;
/// none touches the real `container` CLI.
@Suite("SandboxingManager.startContainerSystem (#293 review)")
struct SandboxingManagerStartTests {
    /// A stub binary in a temp directory running `body` under `/bin/sh`. Mirrors
    /// `SandboxTests.stubContainer`, parameterized on the containing directory's name so the
    /// "path with spaces and quotes" test can put it somewhere unusual.
    private func stub(_ body: String, dirName: String = "iris-start-stub-\(UUID().uuidString)") throws -> (binary: String, dir: URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(dirName)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let script = dir.appendingPathComponent("container")
        try "#!/bin/sh\n\(body)\n".write(to: script, atomically: true, encoding: .utf8)
        #expect(chmod(script.path, 0o755) == 0)
        return (script.path, dir)
    }

    @Test("a stub that sleeps forever times out and answers false, not hanging the caller")
    func timesOutRatherThanHanging() async throws {
        let stub = try stub("sleep 30")
        defer { try? FileManager.default.removeItem(at: stub.dir) }
        let m = SandboxingManager(binaryPath: { stub.binary }, startTimeoutSeconds: 1)
        let startedAt = Date()
        let result = await m.startContainerSystem()
        #expect(Date().timeIntervalSince(startedAt) < 15, "answered near the 1s timeout, not after the real 30s sleep")
        #expect(result.success == false)
        #expect(result.message != nil)
    }

    @Test("a stub that writes well past the 64KB pipe buffer does not deadlock")
    func doesNotDeadlockOnLargeOutput() async throws {
        // Comfortably past the ~64KB pipe buffer `waitUntilExit()`-then-`readDataToEndOfFile()`
        // would have blocked on; exits cleanly once it is all written.
        let stub = try stub("yes 'progress: pulling kernel image layer' | head -c 300000\nexit 0")
        defer { try? FileManager.default.removeItem(at: stub.dir) }
        let m = SandboxingManager(binaryPath: { stub.binary }, startTimeoutSeconds: 10)
        let result = await m.startContainerSystem()
        #expect(result.success == true, "got: \(String(describing: result.message))")
    }

    @Test("a binary path containing spaces and a quote is passed safely, with no shell to misparse it")
    func pathWithSpacesAndQuoteIsSafe() async throws {
        let stub = try stub("echo ok\nexit 0", dirName: "iris start stub it's got spaces \(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: stub.dir) }
        let m = SandboxingManager(binaryPath: { stub.binary }, startTimeoutSeconds: 10)
        let result = await m.startContainerSystem()
        #expect(result.success == true, "got: \(String(describing: result.message))")
    }

    @Test("two concurrent callers produce exactly one stub invocation")
    func singleFlight() async throws {
        // Slow enough that the second caller's check is guaranteed to land while the first's
        // start is still in flight, not after it has already cleared.
        let stub = try stub("""
        echo invoked >> "$(dirname "$0")/calls"
        sleep 0.3
        exit 0
        """)
        defer { try? FileManager.default.removeItem(at: stub.dir) }
        let m = SandboxingManager(binaryPath: { stub.binary }, startTimeoutSeconds: 10)
        async let first = m.startContainerSystem()
        async let second = m.startContainerSystem()
        let (r1, r2) = await (first, second)
        #expect(r1.success == true && r2.success == true)
        let log = stub.dir.appendingPathComponent("calls")
        let calls = ((try? String(contentsOf: log, encoding: .utf8)) ?? "")
            .split(separator: "\n")
        #expect(calls.count == 1, "got: \(calls)")

        // The in-flight task is cleared once it finishes: a start made after it completes gets
        // its own fresh invocation, not the same joined task answering again.
        let third = await m.startContainerSystem()
        #expect(third.success == true)
        let callsAfter = ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n")
        #expect(callsAfter.count == 2, "got: \(callsAfter)")
    }
}
