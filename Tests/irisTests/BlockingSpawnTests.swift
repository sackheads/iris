import Testing
import Foundation
import Darwin
@testable import IrisKit

/// The one `posix_spawn` + `waitpid` helper the kill paths share (#377). Everything it spawns is a
/// base-system binary with a marker nothing else on the machine would carry.
@Suite("BlockingSpawn", .timeLimit(.minutes(1)))
struct BlockingSpawnTests {
    private static func marker() -> String { "30.\(Int.random(in: 100_000...999_999))" }

    @Test("returns the child's exit status")
    func exitStatus() {
        #expect(BlockingSpawn.run("/bin/sh", ["-c", "exit 0"]) == 0)
        #expect(BlockingSpawn.run("/bin/sh", ["-c", "exit 3"]) == 3)
        #expect(BlockingSpawn.run("/bin/sh", ["-c", "exit 3"], timeoutSeconds: 10) == 3)
    }

    @Test("a child killed by a signal reads as 128 + the signal")
    func signalStatus() {
        #expect(BlockingSpawn.run("/bin/sh", ["-c", "kill -TERM $$"]) == 128 + SIGTERM)
    }

    @Test("arguments reach the child verbatim, one argv element each")
    func argumentsVerbatim() {
        #expect(BlockingSpawn.run("/bin/sh", ["-c", "[ \"$1\" = 'a b' ] && [ \"$2\" = '$x;' ]", "sh", "a b", "$x;"]) == 0)
    }

    @Test("a binary that cannot be spawned returns nil")
    func spawnFailure() {
        #expect(BlockingSpawn.run("/nonexistent/iris-\(UUID().uuidString)", []) == nil)
    }

    @Test("it waits for the child to exit")
    func waitsForExit() {
        let started = Date()
        #expect(BlockingSpawn.run("/bin/sleep", ["0.3"]) == 0)
        #expect(Date().timeIntervalSince(started) >= 0.3)
    }

    @Test("stdin reads as empty, so a child that reads it does not block")
    func stdinIsNull() {
        // `read` fails at end-of-file at once; on an inherited stdin it would wait for the kill.
        #expect(BlockingSpawn.run("/bin/sh", ["-c", "read line"], timeoutSeconds: 5) == 1)
    }

    @Test("past its timeout the child is SIGKILLed and reaped")
    func timeoutKills() {
        let nap = Self.marker()
        defer { RunCommandProcessGroupTests.killAll(nap) }
        let started = Date()
        let status = BlockingSpawn.run("/bin/sleep", [nap], timeoutSeconds: 0.5)
        let wall = Date().timeIntervalSince(started)
        #expect(status == 128 + SIGKILL)
        #expect(wall >= 0.5)
        #expect(wall < 5)
        #expect(!RunCommandProcessGroupTests.exists("sleep \(nap)"))
    }

    @Test("detached returns at once and reports the status on a queue that is not the caller's")
    func detachedRuns() async {
        final class Box: @unchecked Sendable {
            let lock = NSLock(); var status: Int32?? = nil; var label = ""
        }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        let started = Date()
        BlockingSpawn.detached("/bin/sh", ["-c", "sleep 0.3; exit 4"], timeoutSeconds: 10) { status in
            let label = String(cString: __dispatch_queue_get_label(nil))
            box.lock.withLock { box.status = .some(status); box.label = label }
            done.signal()
        }
        #expect(Date().timeIntervalSince(started) < 0.3)
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            DispatchQueue(label: "iris.test.wait").async { done.wait(); c.resume() }
        }
        #expect(box.lock.withLock { box.status } == .some(4))
        #expect(box.lock.withLock { box.label } == "iris.blocking-spawn")
    }
}
