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
        let started = TestClock.now()
        #expect(BlockingSpawn.run("/bin/sleep", ["0.3"]) == 0)
        #expect(TestClock.seconds(since: started) >= 0.3)
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
        let started = TestClock.now()
        let status = BlockingSpawn.run("/bin/sleep", [nap], timeoutSeconds: 0.5)
        let wall = TestClock.seconds(since: started)
        #expect(status == 128 + SIGKILL)
        #expect(wall >= 0.5)
        #expect(wall < 5)
        #expect(!RunCommandProcessGroupTests.exists("sleep \(nap)"))
    }

    @Test("#463: with newGroup, the timeout kills the child's whole group, not only the child")
    func timeoutKillsTheGroup() {
        let nap = Self.marker()
        defer { RunCommandProcessGroupTests.killAll(nap) }
        // The shell forks the sleep and waits on it: a pid-only kill ends the shell and orphans it.
        let status = BlockingSpawn.run("/bin/sh", ["-c", "sleep \(nap) & wait"], timeoutSeconds: 0.5,
                                       newGroup: true)
        #expect(status == 128 + SIGKILL)
        var gone = false
        for _ in 0..<100 {
            if !RunCommandProcessGroupTests.exists("sleep \(nap)") { gone = true; break }
            usleep(20_000)
        }
        #expect(gone, "the forked sleep died with its group")
    }

    /// #1359: the kill reaches a group one member at a time, so a shell whose `wait` saw its child die
    /// first can exit 0 before its own SIGKILL lands (a queue run read 0 here once). The seam stages
    /// that order on purpose: its "kill" ends only the sleep, and the shell exits 0 by itself.
    @Test("#1359: a call killed at its deadline reads as SIGKILLed, even when the shell raced out with 0",
          arguments: [true, false])
    func killedCallReadsAsKilled(newGroup: Bool) {
        let nap = Self.marker()
        defer { RunCommandProcessGroupTests.killAll(nap) }
        var sent = 0
        // `pkill -P`, not the marker: the shell's own argv carries `sleep <nap>` too, and must outlive its child.
        let status = BlockingSpawn.run("/bin/sh", ["-c", "sleep \(nap) & wait"], timeoutSeconds: 0.5,
                                       newGroup: newGroup, signal: { pid, _ in
            sent += 1
            BlockingSpawn.run("/usr/bin/pkill", ["-9", "-P", String(abs(pid))])
            return 0
        })
        #expect(sent == 1, "one kill, the group's or the pid's")
        #expect(status == 128 + SIGKILL)
    }

    @Test("#1359: an exit reaped before the deadline is the child's own, and nothing is signalled",
          arguments: [true, false])
    func exitBeforeDeadlinePassesThrough(newGroup: Bool) {
        var sent = 0
        let status = BlockingSpawn.run("/bin/sh", ["-c", "sleep 0.2; exit 0"], timeoutSeconds: 2,
                                       newGroup: newGroup, signal: { pid, sig in sent += 1; return kill(pid, sig) })
        #expect(status == 0)
        #expect(sent == 0)
    }

    @Test("detached returns at once and reports the status on a queue that is not the caller's")
    func detachedRuns() async {
        final class Box: @unchecked Sendable {
            let lock = NSLock(); var status: Int32?? = nil; var label = ""
        }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        let started = TestClock.now()
        BlockingSpawn.detached("/bin/sh", ["-c", "sleep 0.3; exit 4"], timeoutSeconds: 10) { status in
            let label = String(cString: __dispatch_queue_get_label(nil))
            box.lock.withLock { box.status = .some(status); box.label = label }
            done.signal()
        }
        #expect(TestClock.seconds(since: started) < 0.3)
        // hang-ok: [bounded] resumed after done.wait(), which BlockingSpawn.detached(timeoutSeconds: 10) signals
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            // hang-ok: [bounded] done is signalled by BlockingSpawn.detached(timeoutSeconds: 10) completion
            DispatchQueue(label: "iris.test.wait").async { done.wait(); c.resume() }
        }
        #expect(box.lock.withLock { box.status } == .some(4))
        #expect(box.lock.withLock { box.label } == "iris.blocking-spawn")
    }
}
