import Testing
import Foundation
@testable import IrisKit

/// #353, inside the VM: killing the `container exec` client on the host leaves the command running
/// in the container, so `exec` records the command's process group there and, on a timeout or a
/// cancel, kills it with a second `exec`. Since #377 that second `exec` is fired by the client's
/// kill ladder (`Launch`'s `onKill`), not by `exec` after the launch throws. Nothing here goes
/// near the `container` binary (invariant 7): the argv is recorded, and the two scripts are run
/// by the host's own bash.
@Suite("container exec kills its group in the VM", .timeLimit(.minutes(1)))
struct ContainerExecGroupKillTests {

    /// Records every launch and every fire. The first launch answers with `first`, after running
    /// its `onKill` when `ladderKills` — what `CLIProcessRunner` does when its ladder had to kill
    /// the client; the rest succeed.
    final class Launcher: @unchecked Sendable {
        private let lock = NSLock()
        private var calls: [[String]] = []
        private var fired: [(args: [String], timeout: Int)] = []
        private let first: Error?
        private let ladderKills: Bool
        init(first: Error?, ladderKills: Bool = true) { self.first = first; self.ladderKills = ladderKills }
        var launch: CLIContainerRuntime.Launch {
            { [self] args, _, onKill in
                let fail: Error? = lock.withLock { calls.append(args); return calls.count == 1 ? first : nil }
                if let fail {
                    if ladderKills { onKill?() }
                    throw fail
                }
                return ("", "", 0)
            }
        }
        var fire: CLIContainerRuntime.Fire {
            { [self] args, timeout in lock.withLock { fired.append((args, timeout)) } }
        }
        var argv: [[String]] { lock.withLock { calls } }
        var fires: [(args: [String], timeout: Int)] { lock.withLock { fired } }
        func runtime() -> CLIContainerRuntime { CLIContainerRuntime(launch: launch, fire: fire) }
    }

    private static func pidFile(in argv: [String]) -> String? {
        guard let script = argv.firstIndex(of: "-c").map({ argv[$0 + 1] }),
              let range = script.range(of: #"/tmp/\.iris-exec-[0-9A-F-]+\.pid"#, options: .regularExpression)
        else { return nil }
        return String(script[range])
    }

    @Test("the command runs under the recording wrapper, as its first argument")
    func execArgv() async throws {
        let launcher = Launcher(first: nil)
        _ = try await launcher.runtime().exec(name: "iris-a", workdir: "/ws", command: "echo hi", timeoutSeconds: 5)
        let argv = try #require(launcher.argv.first)
        let pidFile = try #require(Self.pidFile(in: argv))
        #expect(argv == ["exec", "-w", "/ws", "iris-a", "bash", "-c", CLIContainerRuntime.recordingWrapper(pidFile), "iris-exec", "echo hi"])
        // An ordinary exit kills nothing.
        #expect(launcher.argv.count == 1)
        #expect(launcher.fires.isEmpty)
    }

    @Test("a ladder kill on a timeout or a cancel fires the group killer for the same note", arguments: [true, false])
    func killerFollowsLadder(timedOut: Bool) async throws {
        let error: Error = timedOut ? ContainerRuntimeError.timedOut(elapsedSeconds: 1) : CancellationError()
        let launcher = Launcher(first: error)
        await #expect(throws: Error.self) {
            _ = try await launcher.runtime().exec(name: "iris-a", workdir: "/ws", command: "sleep 99", timeoutSeconds: 1)
        }
        // Fired by the ladder before the launch threw: nothing for a pool thread to start later.
        let fires = launcher.fires
        try #require(fires.count == 1, "no kill followed the \(timedOut ? "timeout" : "cancel")")
        let pidFile = try #require(Self.pidFile(in: launcher.argv[0]))
        #expect(fires[0].args == ["exec", "iris-a", "bash", "-c", CLIContainerRuntime.groupKiller(pidFile)])
        #expect(fires[0].timeout == CLIContainerRuntime.housekeepingTimeoutSeconds)
        // Fired, not launched: the killer is not awaited through the pool-bound path.
        #expect(launcher.argv.count == 1)
    }

    @Test("an error the ladder did not kill for fires no killer")
    func noKillerWithoutLadder() async throws {
        let launcher = Launcher(first: ContainerRuntimeError.timedOut(elapsedSeconds: 1), ladderKills: false)
        await #expect(throws: Error.self) {
            _ = try await launcher.runtime().exec(name: "iris-a", workdir: "/ws", command: "sleep 99", timeoutSeconds: 1)
        }
        #expect(launcher.fires.isEmpty)
        #expect(launcher.argv.count == 1)
    }

    @Test("housekeeping calls pass no kill hook")
    func housekeepingHasNoHook() async throws {
        final class Hooks: @unchecked Sendable {
            let lock = NSLock(); var seen: [Bool] = []
        }
        let hooks = Hooks()
        let rt = CLIContainerRuntime(launch: { _, _, onKill in
            hooks.lock.withLock { hooks.seen.append(onKill != nil) }
            return ("[]", "", 0)
        }, fire: { _, _ in })
        try await rt.createDetached(name: "iris-a", image: "img", mounts: [], workdir: "/")
        _ = await rt.list(prefix: "iris-")
        await rt.remove(name: "iris-a")
        _ = try await rt.exec(name: "iris-a", workdir: "/", command: "true", timeoutSeconds: 1)
        #expect(hooks.lock.withLock { hooks.seen } == [false, false, false, false, true])
    }

    /// The stub `container` for the ladder tests (see `twoKillsOneNote`). Every note path it sees,
    /// the command's and each killer's, goes to `log.notes`, so a test removes them however it ends.
    private static func writeStub(at stub: String, log: String, go: String, status: String, clientNap: String,
                                  late: Bool) throws {
        try """
        #!/bin/bash
        [ "$1" = exec ] || exit 0
        shift; [ "$1" = -w ] && shift 2; shift
        if [ "$4" = iris-exec ]; then
            # The wrapper's note lands in the host's /tmp too: list it for the test's cleanup even
            # when no killer ever runs (#577).
            printf '%s\\n' "$(printf %s "$3" | grep -o '/tmp/[.]iris-exec-[A-Za-z0-9-]*[.]pid' | head -1)" >> '\(log).notes'
            ( ( trap '' TERM; \(late ? "for i in $(seq 1 500); do [ -e '\(go)' ] && break; sleep 0.02; done; [ -e '\(go)' ] || exit 0; " : "")trap - TERM; set -m; "$@" & wait $!; echo $? > '\(status)' ) & ) </dev/null >/dev/null 2>&1
            sleep \(clientNap)
        else
            pf=$(printf %s "$3" | grep -o '/tmp/[.]iris-exec-[A-Za-z0-9-]*[.]pid' | head -1)
            echo "$pf" >> '\(log).notes'
            if [ -s "$pf" ]; then echo note >> '\(log)'; else echo none >> '\(log)'; fi
            "$@"; echo done >> '\(log).done'
        fi
        """.write(toFile: stub, atomically: true, encoding: .utf8)
    }

    /// Removes the host-side notes and cancel markers a stubbed run listed (#574 review, #577):
    /// the stub runs the wrapper and killer on the host, so they land in the host's /tmp.
    static func removeHostNotes(listedIn log: String) {
        let notes = (try? String(contentsOfFile: log + ".notes", encoding: .utf8)) ?? ""
        for note in Set(notes.split(separator: "\n").map(String.init)) where note.hasPrefix("/tmp/.iris-exec-") {
            try? FileManager.default.removeItem(atPath: note)
            try? FileManager.default.removeItem(atPath: CLIContainerRuntime.cancelMarker(note))
        }
    }

    /// One stubbed command cancelled with the kill path broken: `fire` spawns no killer, so the
    /// wrapper's note is never taken and the group is only ended by the test's `killAll`. Returns
    /// the note path, evaluated before this function's cleanup runs.
    private func runWithNoKiller() async throws -> String? {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("iris-577-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let nap = "30.\(Int.random(in: 100_000...999_999))"
        let clientNap = "30.\(Int.random(in: 100_000...999_999))"
        let stub = dir.appendingPathComponent("container").path
        let log = dir.appendingPathComponent("killers").path
        defer { Self.removeHostNotes(listedIn: log) }
        defer { RunCommandProcessGroupTests.killAll(nap); RunCommandProcessGroupTests.killAll(clientNap) }
        try Self.writeStub(at: stub, log: log, go: dir.appendingPathComponent("go").path,
                           status: dir.appendingPathComponent("wrapper-status").path, clientNap: clientNap, late: false)
        #expect(chmod(stub, 0o755) == 0)
        let rt = CLIContainerRuntime(
            launch: { args, timeout, onKill in
                try await CLIProcessRunner(executable: stub).run(args, timeoutSeconds: timeout, onKill: onKill)
            },
            fire: { _, _ in })
        let call = Task { try await rt.exec(name: "iris-a", workdir: "/", command: "sleep \(nap); true", timeoutSeconds: 60) }
        #expect(await RunCommandProcessGroupTests.appears("^sleep \(nap)", within: 5), "precondition: the group started")
        call.cancel()
        _ = try? await value(of: call)
        let note = ((try? String(contentsOfFile: log + ".notes", encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init).first { $0.hasPrefix("/tmp/.iris-exec-") }
        // The wrapper, not just its command, dies with no chance to remove its own note: the way
        // #577's 41 notes were left, by runs whose kill path was broken.
        if let note, let text = try? String(contentsOfFile: note, encoding: .utf8),
           let group = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            _ = kill(-group, SIGKILL)
        }
        try? await Task.sleep(nanoseconds: 200_000_000)
        #expect(note.map { FileManager.default.fileExists(atPath: $0) } == true,
                "precondition: the killed wrapper left its note for the cleanup to find")
        return note
    }

    @Test("a run whose kill never fires leaves no note behind in the host's /tmp (#577)", .timeLimit(.minutes(1)))
    func noKillerLeavesNoNote() async throws {
        let note = try #require(try await runWithNoKiller(), "the stub listed the command's note")
        #expect(!FileManager.default.fileExists(atPath: note))
        #expect(!FileManager.default.fileExists(atPath: CLIContainerRuntime.cancelMarker(note)))
    }

    /// The ladder fires the killer twice (#377). Not `late`: the group is recorded first, the first
    /// kill takes the note and ends it, and the second must find no note, so it signals nothing —
    /// the id may be reused by then. `late`: the wrapper starts only after the first kill has
    /// fired, so that kill finds no note, and its cancel marker stops the wrapper running the
    /// command at all (#572), however long after the last kill the wrapper starts.
    ///
    /// A stub `container` stands in for the CLI: for the command's `exec` it starts the wrapper
    /// detached from the client and as a group leader (`set -m`), the way the VM runs it apart from
    /// the client, and records its exit status; `late`, only once the test writes `go`, which it
    /// does after the first kill fired: an order, not a clock (#571). For the killer's `exec` it
    /// logs whether the note is there, then runs the killer on the host.
    @Test("each of the ladder's two kills signals the group only if it holds the note", .timeLimit(.minutes(1)),
          arguments: [true, false])
    func twoKillsOneNote(late: Bool) async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("iris-377-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let nap = "30.\(Int.random(in: 100_000...999_999))"
        let clientNap = "30.\(Int.random(in: 100_000...999_999))"
        defer { RunCommandProcessGroupTests.killAll(nap); RunCommandProcessGroupTests.killAll(clientNap) }
        let stub = dir.appendingPathComponent("container").path
        let log = dir.appendingPathComponent("killers").path
        // The stub runs the killer on the host, so the call's note and cancel marker land in the
        // host's /tmp: take them away with the test (#574 review).
        defer { Self.removeHostNotes(listedIn: log) }
        let go = dir.appendingPathComponent("go").path
        let status = dir.appendingPathComponent("wrapper-status").path
        let ran = dir.appendingPathComponent("ran").path
        try Self.writeStub(at: stub, log: log, go: go, status: status, clientNap: clientNap, late: late)
        #expect(chmod(stub, 0o755) == 0)

        final class Fires: @unchecked Sendable {
            let lock = NSLock(); var count = 0
        }
        let fires = Fires()
        let rt = CLIContainerRuntime(
            launch: { args, timeout, onKill in
                try await CLIProcessRunner(executable: stub).run(args, timeoutSeconds: timeout, onKill: onKill)
            },
            fire: { args, timeout in
                fires.lock.withLock { fires.count += 1 }
                BlockingSpawn.detached(stub, args, timeoutSeconds: Double(timeout))
            })
        let call = Task { try await rt.exec(name: "iris-a", workdir: "/", command: "touch '\(ran)'; sleep \(nap); true", timeoutSeconds: 60) }
        #expect(await RunCommandProcessGroupTests.appears("sleep \(clientNap)", within: 5))
        if !late { #expect(await RunCommandProcessGroupTests.appears("^sleep \(nap)", within: 5)) }
        call.cancel()
        _ = try? await value(of: call)
        func killers() -> [String] {
            ((try? String(contentsOfFile: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        }
        /// Both killers finished, so neither writes its marker after the cleanup above.
        func killersDone() async throws {
            let end = TestClock.deadline(CLIProcessRunner.killGraceSeconds * 2 + 5)
            func done() -> Int { ((try? String(contentsOfFile: log + ".done", encoding: .utf8)) ?? "").split(separator: "\n").count }
            while done() < 2, TestClock.now() < end { try await Task.sleep(nanoseconds: 50_000_000) }
        }
        if late {
            // The first killer finished, not merely fired: its marker is down before the wrapper
            // starts (`fire` returns as the killer process is spawned, before it has run).
            func done() -> Int { ((try? String(contentsOfFile: log + ".done", encoding: .utf8)) ?? "").split(separator: "\n").count }
            let fired = TestClock.deadline(10)
            while done() < 1, TestClock.now() < fired { try await Task.sleep(nanoseconds: 20_000_000) }
            #expect(done() >= 1, "precondition: the first kill ran")
            #expect(FileManager.default.createFile(atPath: go, contents: nil))
            let ended = TestClock.deadline(10)
            while !FileManager.default.fileExists(atPath: status), TestClock.now() < ended { try await Task.sleep(nanoseconds: 20_000_000) }
            let code = (try? String(contentsOfFile: status, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(code == "143", "the late wrapper found the marker and ran nothing")
            #expect(!FileManager.default.fileExists(atPath: ran), "not ran and then killed: never ran")
            #expect(!RunCommandProcessGroupTests.exists("^sleep \(nap)"))
            #expect(killers().first == "none", "the first kill came before any note")
            let both = TestClock.deadline(CLIProcessRunner.killGraceSeconds + 3)
            while fires.lock.withLock({ fires.count }) < 2, TestClock.now() < both { try await Task.sleep(nanoseconds: 50_000_000) }
            #expect(fires.lock.withLock { fires.count } == 2, "the ladder still fires twice")
            try await killersDone()
            return
        }
        let deadline = TestClock.deadline(CLIProcessRunner.killGraceSeconds * 2 + 3)
        while RunCommandProcessGroupTests.exists("^sleep \(nap)"), TestClock.now() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(!RunCommandProcessGroupTests.exists("^sleep \(nap)"), "the group outlived both kills")
        // The second fire comes a grace after the first, however soon the group died.
        let killersDeadline = TestClock.deadline(CLIProcessRunner.killGraceSeconds + 3)
        while killers().count < 2, TestClock.now() < killersDeadline { try await Task.sleep(nanoseconds: 50_000_000) }
        #expect(fires.lock.withLock { fires.count } == 2)
        #expect(killers() == ["note", "none"])
        try await killersDone()
    }

    /// The pgid-reuse half of #377, without the race of the two fires: a killer in its grace has
    /// already taken the note, so a second killer exits at once and signals nothing.
    @Test("a killer takes the note before its grace, so a second killer signals nothing")
    func killerTakesNote() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("iris-377-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let pidFile = dir.appendingPathComponent("g.pid").path
        let nap = "30.\(Int.random(in: 100_000...999_999))"
        defer { RunCommandProcessGroupTests.killAll(nap) }
        // Ignores SIGTERM, so the first killer is still in its grace when the second runs.
        let command = Task {
            await ProcessGroupRunner().run(
                executable: "/bin/bash",
                arguments: ["-c", CLIContainerRuntime.recordingWrapper(pidFile), "iris-exec", "trap '' TERM; sleep \(nap); true"],
                environment: nil, currentDirectory: nil)
        }
        #expect(await RunCommandProcessGroupTests.appears("^sleep \(nap)", within: 5))
        BlockingSpawn.detached("/bin/bash", ["-c", CLIContainerRuntime.groupKiller(pidFile)], timeoutSeconds: 30)
        let taken = TestClock.deadline(1)
        while FileManager.default.fileExists(atPath: pidFile), TestClock.now() < taken { try await Task.sleep(nanoseconds: 20_000_000) }
        #expect(!FileManager.default.fileExists(atPath: pidFile), "the note was still there during the grace")
        #expect(RunCommandProcessGroupTests.exists("^sleep \(nap)"), "the first killer's grace should not be over yet")
        let started = TestClock.now()
        #expect(BlockingSpawn.run("/bin/bash", ["-c", CLIContainerRuntime.groupKiller(pidFile)], timeoutSeconds: 10) == 0)
        #expect(TestClock.seconds(since: started) < 1, "the second killer waited out a grace: it signalled something")
        _ = try await value(of: command)
        #expect(!RunCommandProcessGroupTests.exists("^sleep \(nap)"))
    }

    @Test("the wrapper passes output and status through, and clears its note")
    func wrapperIsTransparent() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("iris-353-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let pidFile = dir.appendingPathComponent("g.pid").path
        let result = await ProcessGroupRunner().run(
            executable: "/bin/bash",
            arguments: ["-c", CLIContainerRuntime.recordingWrapper(pidFile), "iris-exec", "echo out; echo err >&2; exit 3"],
            environment: nil, currentDirectory: nil)
        let output = try result.get()
        #expect(String(data: output.stdout, encoding: .utf8) == "out\n")
        #expect(String(data: output.stderr, encoding: .utf8) == "err\n")
        #expect(output.status == 3)
        #expect(!FileManager.default.fileExists(atPath: pidFile))
    }

    @Test("the killer ends the whole recorded group, grandchildren included")
    func killerEndsGroup() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("iris-353-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let pidFile = dir.appendingPathComponent("g.pid").path
        let bg = "30.\(Int.random(in: 100_000...999_999))", fg = "30.\(Int.random(in: 100_000...999_999))"
        defer { RunCommandProcessGroupTests.killAll(bg); RunCommandProcessGroupTests.killAll(fg) }
        // Stands in for `container exec`, which makes the wrapper a group leader in the VM.
        let command = Task {
            await ProcessGroupRunner().run(
                executable: "/bin/bash",
                arguments: ["-c", CLIContainerRuntime.recordingWrapper(pidFile), "iris-exec", "(sleep \(bg) &); sleep \(fg); true"],
                environment: nil, currentDirectory: nil)
        }
        #expect(await RunCommandProcessGroupTests.appears("^sleep \(fg)", within: 5))
        let killer = await ProcessGroupRunner().run(executable: "/bin/bash", arguments: ["-c", CLIContainerRuntime.groupKiller(pidFile)],
                                                     environment: nil, currentDirectory: nil)
        #expect((try? killer.get().status) == 0)
        _ = try await value(of: command)
        #expect(!RunCommandProcessGroupTests.exists("sleep \(bg)"))
        #expect(!RunCommandProcessGroupTests.exists("sleep \(fg)"))
        #expect(!FileManager.default.fileExists(atPath: pidFile))
        #expect(!FileManager.default.fileExists(atPath: CLIContainerRuntime.cancelMarker(pidFile)),
                "the killer that took the note removed the marker too (#572)")
    }

    // MARK: The cancel marker (#572)

    /// `BlockingSpawn.run`, off the cooperative pool: the suite's tests run in parallel, and a pool
    /// thread parked on a blocking spawn can keep the wrapper's own task from starting (#574 review).
    private func spawnOffPool(_ path: String, _ arguments: [String], timeoutSeconds: Double) async -> Int32? {
        await withCheckedContinuation { done in
            DispatchQueue(label: "iris.test.spawn").async {
                done.resume(returning: BlockingSpawn.run(path, arguments, timeoutSeconds: timeoutSeconds))
            }
        }
    }

    private func scratch() throws -> (dir: URL, pidFile: String, ran: String) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("iris-572-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (dir, dir.appendingPathComponent("g.pid").path, dir.appendingPathComponent("ran").path)
    }

    @Test("a wrapper that starts after every kill fired finds the marker and runs nothing")
    func lateWrapperRunsNothing() async throws {
        let (dir, pidFile, ran) = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Every kill fired before the command's wrapper started: each found no note.
        #expect(await spawnOffPool("/bin/bash", ["-c", CLIContainerRuntime.groupKiller(pidFile)], timeoutSeconds: 10) == 0)
        #expect(FileManager.default.fileExists(atPath: CLIContainerRuntime.cancelMarker(pidFile)))
        let wrapper = await ProcessGroupRunner().run(
            executable: "/bin/bash",
            arguments: ["-c", CLIContainerRuntime.recordingWrapper(pidFile), "iris-exec", "touch '\(ran)'"],
            environment: nil, currentDirectory: nil)
        #expect((try? wrapper.get().status) == 143)
        #expect(!FileManager.default.fileExists(atPath: ran), "the command never ran")
        #expect(!FileManager.default.fileExists(atPath: pidFile))
        #expect(!FileManager.default.fileExists(atPath: CLIContainerRuntime.cancelMarker(pidFile)), "cleaned up")
    }

    /// The interleaving the order exists for: the wrapper is between noting its group and checking
    /// for a marker when a killer comes and goes. A FIFO as the note holds the wrapper inside its
    /// write until the test reads it, so the killer finds no note and leaves its marker; the
    /// wrapper, its note written, must then find the marker. A wrapper that checked first and noted
    /// after has already looked by then, and runs the command after the last kill.
    @Test("a wrapper caught between its note and its check by a killer that found no note still runs nothing")
    func wrapperBetweenNoteAndCheck() async throws {
        let (dir, pidFile, ran) = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(mkfifo(pidFile, 0o600) == 0)
        let wrapper = Task {
            await ProcessGroupRunner().run(
                executable: "/bin/bash",
                arguments: ["-c", CLIContainerRuntime.recordingWrapper(pidFile), "iris-exec", "touch '\(ran)'"],
                environment: nil, currentDirectory: nil)
        }
        // The wrapper is running (its argument names this test's own directory), then a moment for
        // bash to reach its first statement and block opening the FIFO. Starved past that, the
        // killer runs first and both orders pass: never a false red.
        #expect(await RunCommandProcessGroupTests.appears(dir.lastPathComponent, within: 10), "precondition: the wrapper started")
        try await Task.sleep(nanoseconds: 500_000_000)
        #expect(await spawnOffPool("/bin/bash", ["-c", CLIContainerRuntime.groupKiller(pidFile)], timeoutSeconds: 10) == 0,
                "the killer finds no note in a FIFO and leaves its marker")
        // Lets the note's write finish. Bounded: a wrapper that never reaches it would hold an
        // open(2) of the FIFO for good (#574 review).
        #expect(await spawnOffPool("/bin/cat", [pidFile], timeoutSeconds: 10) == 0)
        let result = try await value(of: wrapper)
        #expect((try? result.get().status) == 143)
        #expect(!FileManager.default.fileExists(atPath: ran), "the command never ran")
        #expect(!FileManager.default.fileExists(atPath: CLIContainerRuntime.cancelMarker(pidFile)), "cleaned up")
    }
}
