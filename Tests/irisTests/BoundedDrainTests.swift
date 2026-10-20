import Testing
import Foundation
@testable import IrisKit

/// #699: container exec output held to a byte limit on the host. A cap inside the VM can be
/// written past (`/proc/$PPID/fd/1` is the wrapper's own stdout), so the limit that counts is the
/// one on the pipe Iris reads. These run a child of the test's own through `CLIProcessRunner`,
/// which is the reader `container exec` goes through.
@Suite("Bounded drain for container exec output (#699)", .timeLimit(.minutes(1)))
struct BoundedDrainTests {
    private let sh = CLIProcessRunner(executable: "/bin/sh")

    @Test("past the limit a stream is drained and dropped, so the child runs to its end and the drop is counted")
    func drainsPastLimit() async throws {
        // 8 MB is far past any pipe buffer: a reader that stopped reading at the limit would leave
        // the child blocked on write until the deadline.
        let started = TestClock.now()
        let r = try await sh.run(["-c", "head -c 8388608 /dev/zero; echo done >&2"], timeoutSeconds: 30, outputLimit: 1000)
        #expect(TestClock.seconds(since: started) < 20, "the child was not left blocked on a full pipe")
        #expect(r.exitCode == 0)
        #expect(r.stdout.utf8.count == 1000)
        #expect(r.droppedStdout == 8_388_608 - 1000)
        #expect(r.stderr == "done\n" && r.droppedStderr == 0, "each stream has its own limit")
        #expect(r.truncated)
    }

    @Test("under the limit the output is exactly what the uncapped run returns")
    func underLimitUnchanged() async throws {
        let script = "printf 'one\\ntwo\\n'; printf 'warn' >&2; exit 3"
        let capped = try await sh.run(["-c", script], timeoutSeconds: 30, outputLimit: 1_000_000)
        let plain = try await sh.run(["-c", script], timeoutSeconds: 30)
        #expect(capped.tuple == plain)
        #expect(!capped.truncated)
    }

    @Test("a cut inside a multi-byte character keeps the text before it rather than losing the stream")
    func cutMidCharacter() async throws {
        // U+00E9 as its two UTF-8 bytes, spelled in octal so nothing normalises it on the way to
        // the shell; a limit of 5 ends inside the third.
        let r = try await sh.run(["-c", "printf '" + String(repeating: #"\303\251"#, count: 6) + "'"], timeoutSeconds: 30, outputLimit: 5)
        #expect(r.stdout == "\u{e9}\u{e9}", "\(r.stdout)")
        #expect(r.droppedStdout == 7)
    }

    @Test("the deadline still ends a capped command that writes forever")
    func deadlineStillKills() async throws {
        var thrown: Error?
        do { _ = try await sh.run(["-c", "yes"], timeoutSeconds: 1, outputLimit: 4096) } catch { thrown = error }
        guard case .timedOut? = thrown as? ContainerRuntimeError else {
            Issue.record("expected .timedOut, got \(String(describing: thrown))"); return
        }
    }

    @Test("CLIContainerRuntime's capped exec renders the same argv as exec, and a launcher a test injects is the one it uses")
    func cappedExecArgv() async throws {
        let launcher = RecordingLauncher(result: (String(repeating: "x", count: 50), "", 0))
        let rt = CLIContainerRuntime(launch: launcher.launch)
        let r = try await rt.exec(name: "iris-f", workdir: "/ws", command: "echo hi", timeoutSeconds: 45, outputLimit: 10)
        #expect(launcher.lastArgv.prefix(6) == ["exec", "-w", "/ws", "iris-f", "bash", "-c"])
        #expect(launcher.lastArgv.suffix(2) == ["iris-exec", "echo hi"])
        #expect(launcher.timeouts == [45])
        #expect(r.stdout == String(repeating: "x", count: 10) && r.droppedStdout == 40)
    }

    @Test("a gate script that prints past the limit is an error, never a verdict read from a cut stream")
    func gateOverLimitIsError() async throws {
        let runtime = GateRuntime()
        runtime.execResult = (String(repeating: "a", count: GateEvaluator.outputLimitBytes) + "\nCHANGED\n", "", 0)
        guard case .error(let detail) = await GateEvaluator.evaluate(
            .script(command: "check.sh", mounts: [], timeoutSeconds: 30),
            previous: nil, runtime: runtime, image: "ubuntu:latest") else {
            Issue.record("a cut stdout is an error"); return
        }
        #expect(detail == GateEvaluator.outputLimitMessage)

        runtime.execResult = (String(repeating: "a", count: 1000) + "\nCHANGED\n", String(repeating: "e", count: 2 * GateEvaluator.outputLimitBytes), 0)
        guard case .changed = await GateEvaluator.evaluate(
            .script(command: "check.sh", mounts: [], timeoutSeconds: 30),
            previous: nil, runtime: runtime, image: "ubuntu:latest") else {
            Issue.record("a long stderr doesn't touch the verdict, which is stdout's last line"); return
        }
    }
}
